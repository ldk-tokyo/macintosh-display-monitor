import Foundation
import Darwin

struct SourceError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
struct QuotaRow {
    let provider: String
    let window: String
    let remaining: Double
    let reset: Double?
    var payload: [String: Any] {
        var row: [String: Any] = ["provider": provider, "window": window, "remaining": remaining]
        if let reset { row["reset"] = reset }
        return row
    }
}
struct QuotaResult {
    let provider: String
    let rows: [QuotaRow]
    let message: String
    let updated: Date?
    static func waiting(_ name: String) -> Self {
        Self(provider: name, rows: [], message: "等待读取", updated: nil)
    }
    static func read(_ name: String, using load: () throws -> [QuotaRow]) -> Self {
        do {
            let rows = try load()
            let now = Date()
            let time = DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .short)
            let status = rows.isEmpty ? "账户未返回额度窗口" : "已同步 " + time
            return Self(provider: name, rows: rows, message: status, updated: now)
        } catch {
            return Self(provider: name, rows: [], message: error.localizedDescription, updated: nil)
        }
    }
}

enum CodexQuota {
    static func load() throws -> [QuotaRow] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent(".local/bin/codex").path, "/opt/homebrew/bin/codex",
                     "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex",
                     "/Applications/ChatGPT.app/Contents/Resources/codex"]
        guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw SourceError("找不到 Codex CLI")
        }
        let task = Process(), input = Pipe(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["app-server"]
        task.currentDirectoryURL = home
        task.standardInput = input; task.standardOutput = output; task.standardError = FileHandle.nullDevice
        try task.run()
        defer {
            try? input.fileHandleForWriting.close()
            if task.isRunning { task.terminate() }
            try? output.fileHandleForReading.close()
        }
        func send(_ obj: [String: Any]) throws {
            var line = try JSONSerialization.data(withJSONObject: obj)
            line.append(10)
            try input.fileHandleForWriting.write(contentsOf: line)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        var pending = Data()
        func response(_ id: Int) throws -> [String: Any] {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            while ProcessInfo.processInfo.systemUptime < deadline {
                while let end = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: end)
                    let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                    pending.removeSubrange(...end)
                    if obj?["id"] as? Int != id { continue }
                    guard let value = obj?["result"] as? [String: Any] else {
                        throw SourceError("Codex 未返回额度，请检查 CLI 登录")
                    }
                    return value
                }
                let ready = poll(&descriptor, 1, 250)
                if ready < 0 && errno == EINTR { continue }
                guard ready >= 0 else { throw SourceError("Codex 通信中断") }
                if ready == 0 { continue }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let n = Darwin.read(descriptor.fd, &bytes, bytes.count)
                guard n > 0, pending.count < 2_000_000 else { throw SourceError("Codex 通信中断") }
                pending.append(contentsOf: bytes.prefix(n))
            }
            throw SourceError("Codex 响应超时")
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "mac_status_display", "version": "1.0"]]])
        _ = try response(1)
        try send(["method": "initialized"])
        try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
        let result = try response(2)
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        let limits = (byID?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any]) ?? [:]
        return ["primary", "secondary"].compactMap { key in
            guard let win = limits[key] as? [String: Any], let used = win["usedPercent"] as? Double,
                  used.isFinite else { return nil }
            let mins = win["windowDurationMins"] as? Int
            let label: String
            switch mins {
            case 300: label = "5 小时"
            case 10080: label = "每周"
            case let value?: label = value % 60 == 0 ? "\(value / 60) 小时" : "\(value) 分钟"
            default: label = "额度窗口"
            }
            return QuotaRow(provider: "Codex", window: label, remaining: min(100, max(0, 100-used)), reset: win["resetsAt"] as? Double)
        }
    }
}

enum ClaudeQuota {
    static func executable() -> URL? {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        let conventional = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let found = conventional.first(where: fm.isExecutableFile(atPath:)) { return URL(fileURLWithPath: found) }
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for version in versions.sorted(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }) {
            let builds = (try? fm.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)) ?? []
            for build in builds {
                let cli = build.appendingPathComponent("claude.app/Contents/MacOS/claude")
                if fm.isExecutableFile(atPath: cli.path) { return cli }
            }
        }
        return nil
    }

    static func load() throws -> [QuotaRow] {
        guard let cli = executable() else { throw SourceError("找不到 Claude Code CLI") }
        let task = Process(), output = Pipe()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        task.executableURL = cli
        task.currentDirectoryURL = work
        task.arguments = ["-p", "/usage", "--max-turns", "0", "--tools", "", "--no-session-persistence", "--strict-mcp-config",
                          "--setting-sources", "", "--output-format", "json"]
        task.environment = ProcessInfo.processInfo.environment.merging(["TZ": "UTC", "LC_ALL": "en_US.UTF-8"]) { _, new in new }
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        try task.run()
        defer { if task.isRunning { task.terminate() }; try? output.fileHandleForReading.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + 22
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        var data = Data()
        var ended = false
        while ProcessInfo.processInfo.systemUptime < deadline && !ended {
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw SourceError("Claude Code 通信中断") }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let n = Darwin.read(descriptor.fd, &bytes, bytes.count)
            if n == 0 { ended = true; continue }
            guard n > 0, data.count < 2_000_000 else { throw SourceError("Claude Code 返回格式异常") }
            data.append(contentsOf: bytes.prefix(n))
        }
        guard ended else { throw SourceError("Claude Code 读取超时") }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["is_error"] as? Bool == false, obj["num_turns"] as? Int == 0,
              let report = obj["result"] as? String else { throw SourceError("请检查 Claude Code 的登录与 /usage 命令") }
        let rows = parse(report)
        guard !rows.isEmpty else { throw SourceError("Claude Code 未返回可识别的订阅额度") }
        return rows
    }

    static func parse(_ report: String, now: Date = Date()) -> [QuotaRow] {
        // /usage also reports contribution percentages. Only limit lines are quota.
        let pattern = #"^Current (session|week)(?: \(([^)]+)\))?:\s*([0-9]+(?:\.[0-9]+)?)% used(?:\s*[·•]\s*resets\s+(.+))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return report.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            func capture(_ i: Int) -> String? {
                Range(match.range(at: i), in: line).map { String(line[$0]) }
            }
            guard let used = capture(3).flatMap(Double.init), (0...100).contains(used) else { return nil }
            var window = capture(1)?.lowercased() == "session" ? "5 小时" : "每周"
            if let model = capture(2), model.lowercased() != "all models" { window += " · " + model }
            return QuotaRow(provider: "Claude Code", window: window, remaining: 100-used,
                            reset: capture(4).flatMap { resetDate($0, now: now) }?.timeIntervalSince1970)
        }
    }

    private static func resetDate(_ input: String, now: Date) -> Date? {
        var text = input.trimmingCharacters(in: .whitespaces)
        var zone = TimeZone(secondsFromGMT: 0)!
        if let open = text.lastIndex(of: "("), text.hasSuffix(")") {
            let label = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            guard let tz = TimeZone(identifier: label) ?? TimeZone(abbreviation: label) else { return nil }
            zone = tz
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = zone
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let components = text.components(separatedBy: " at ")
        let timeText = components.last ?? text
        let clocks = ["h:mma", "ha", "HH:mm"]
        var time: Date?
        for format in clocks {
            fmt.dateFormat = format
            if let parsed = fmt.date(from: timeText) { time = parsed; break }
        }
        guard let time else { return nil }
        var day = now
        if components.count == 2 {
            if components[0].lowercased() == "tomorrow" { day = cal.date(byAdding: .day, value: 1, to: now)! }
            else if components[0].lowercased() != "today" {
                fmt.dateFormat = "yyyy MMM d"
                let year = cal.component(.year, from: now)
                guard let parsed = fmt.date(from: "\(year) " + components[0]) else { return nil }
                day = parsed
                if cal.component(.month, from: now) == 12 && cal.component(.month, from: day) == 1 {
                    day = cal.date(byAdding: .year, value: 1, to: day)!
                }
            }
        }
        let timeParts = cal.dateComponents([.hour, .minute], from: time)
        var date = cal.date(bySettingHour: timeParts.hour!, minute: timeParts.minute!, second: 0, of: day)
        if components.count == 1, let d = date, d < now.addingTimeInterval(-60) {
            date = cal.date(byAdding: .day, value: 1, to: d)
        }
        return date
    }
}
