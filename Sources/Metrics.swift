import Darwin
import Foundation
import IOKit

struct Metrics {
    var cpu: Double?
    var gpu: Double?
    var memory: Double?
    var usedGB: Double?
    var totalGB: Double?
    var download: Double?
    var upload: Double?

    var payload: [String: Any] {
        let values = ["cpu": cpu, "gpu": gpu, "memory": memory, "usedGB": usedGB,
                      "totalGB": totalGB, "download": download, "upload": upload]
        return values.compactMapValues { $0 }
    }
}

final class HardwareSampler {
    private var previousCPU: [UInt32]?
    private var previousNet = [String: (UInt64, UInt64)]()
    private var lastTime: TimeInterval?

    func sample() -> Metrics {
        var m = Metrics()
        var ticks = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: ticks) / 4)
        let ok = withUnsafeMutablePointer(to: &ticks) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if ok == KERN_SUCCESS {
            let t = ticks.cpu_ticks
            let now = [t.0, t.1, t.2, t.3]
            if let before = previousCPU {
                let delta = zip(now, before).map { Double($0 &- $1) }
                let total = delta.reduce(0, +)
                if total > 0 { m.cpu = 100 * (1 - delta[Int(CPU_STATE_IDLE)] / total) }
            }
            previousCPU = now
        }

        var vm = vm_statistics64_data_t()
        count = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / 4)
        let vmOK = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if vmOK == KERN_SUCCESS {
            let bytes = Double(ProcessInfo.processInfo.physicalMemory)
            let pages = Double(vm.internal_page_count) + Double(vm.wire_count)
                      + Double(vm.compressor_page_count) - Double(vm.purgeable_count)
            let used = min(bytes, max(0, pages * Double(vm_kernel_page_size)))
            m.memory = used / bytes * 100
            m.usedGB = used / 1_073_741_824
            m.totalGB = bytes / 1_073_741_824
        }
        m.gpu = gpuUsage()

        let now = ProcessInfo.processInfo.systemUptime
        if let counters = interfaceBytes() {
            if let lastTime, now > lastTime {
                var rx = 0.0, tx = 0.0
                var matched = false
                for (id, value) in counters {
                    guard let old = previousNet[id], value.0 >= old.0, value.1 >= old.1 else { continue }
                    rx += Double(value.0 - old.0)
                    tx += Double(value.1 - old.1)
                    matched = true
                }
                if matched || counters.isEmpty {
                    m.download = rx / (now - lastTime) / 1_000_000
                    m.upload = tx / (now - lastTime) / 1_000_000
                }
            }
            previousNet = counters
            lastTime = now
        }
        return m
    }

    private func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: Double?
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let value = stats["Device Utilization %"] as? NSNumber,
                  (0...100).contains(value.doubleValue) else { continue }
            result = max(result ?? 0, value.doubleValue)
        }
        return result
    }

    private func interfaceBytes() -> [String: (UInt64, UInt64)]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 8)
        defer { buffer.deallocate() }
        guard sysctl(&mib, 6, buffer, &length, nil, 0) == 0 else { return nil }
        var interfaces = [String: (UInt64, UInt64)]()
        var offset = 0
        while offset + 4 <= length {
            let ptr = buffer.advanced(by: offset)
            let size = Int(ptr.loadUnaligned(as: UInt16.self))
            guard size >= 4, size <= length - offset else { break }
            if ptr.load(fromByteOffset: 3, as: UInt8.self) == RTM_IFINFO2, size >= MemoryLayout<if_msghdr2>.size {
                let msg = ptr.loadUnaligned(as: if_msghdr2.self)
                var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                if msg.ifm_flags & IFF_UP != 0, if_indextoname(UInt32(msg.ifm_index), &name) != nil {
                    let key = String(cString: name)
                    if key.hasPrefix("en") {
                        interfaces[key] = (msg.ifm_data.ifi_ibytes, msg.ifm_data.ifi_obytes)
                    }
                }
            }
            offset += size
        }
        return interfaces
    }
}
