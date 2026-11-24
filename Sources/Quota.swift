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

/// Apps opened from Finder or as a login item inherit PATH=/usr/bin:/bin:/usr/sbin:/sbin.
/// A CLI installed through npm is a `#!/usr/bin/env node` script and exits at once there,
/// so child processes get the PATH of the user's login shell plus the usual install folders.
enum CLIEnvironment {
    static let searchPath: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = shellPath()
        dirs += [".local/bin", ".volta/bin", ".bun/bin", ".npm-global/bin", "Library/pnpm"].map { home + "/" + $0 }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return dirs.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }()

    static func find(_ name: String, fallbacks: [String] = []) -> URL? {
        let candidates = searchPath.map { $0 + "/" + name } + fallbacks
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    static func environment(for cli: URL, adding extra: [String: String] = [:]) -> [String: String] {
        // The interpreter usually sits beside the CLI or beside the file its symlink points to.
        let dirs = [cli.deletingLastPathComponent().path, cli.resolvingSymlinksInPath().deletingLastPathComponent().path] + searchPath
        var seen = Set<String>()
        var env = ProcessInfo.processInfo.environment.merging(extra) { _, new in new }
        env["PATH"] = dirs.filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    private static func shellPath() -> [String] {
        let configured = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        let known = ["zsh", "bash"].contains((configured as NSString).lastPathComponent)
            && FileManager.default.isExecutableFile(atPath: configured)
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: known ? configured : "/bin/zsh")
        task.arguments = ["-ilc", "printf '\\n<<PATH:%s>>\\n' \"$PATH\""]
        task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        timeout.cancel()
        guard let text = String(data: data, encoding: .utf8),
              let start = text.range(of: "<<PATH:", options: .backwards),
              let end = text.range(of: ">>", range: start.upperBound..<text.endIndex) else { return [] }
        return text[start.upperBound..<end.lowerBound].split(separator: ":").map(String.init)
    }
}

enum CodexQuota {
    static func load() throws -> [QuotaRow] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let cli = CLIEnvironment.find("codex", fallbacks: ["/Applications/Codex.app/Contents/Resources/codex",
                                                                 "/Applications/ChatGPT.app/Contents/Resources/codex"]) else {
            throw SourceError("找不到 Codex CLI")
        }
        let task = Process(), input = Pipe(), output = Pipe()
        task.executableURL = cli
        task.arguments = ["app-server"]
        task.environment = CLIEnvironment.environment(for: cli)
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
        if let found = CLIEnvironment.find("claude") { return found }
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
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let usage = try run(cli, in: work, arguments: ["-p", "/usage", "--max-turns", "0", "--tools", "", "--no-session-persistence",
                                                       "--strict-mcp-config", "--setting-sources", "", "--output-format", "json"])
        return try subscriptionRows(from: usage) {
            let status = try? run(cli, in: work, arguments: ["auth", "status", "--json"])
            return status?["loggedIn"] as? Bool
        }
    }

    static func subscriptionRows(from usage: [String: Any], loggedIn: () -> Bool?) throws -> [QuotaRow] {
        let report = usage["result"] as? String
        let valid = usage["is_error"] as? Bool == false && usage["num_turns"] as? Int == 0 && report != nil
        if valid, let report {
            let rows = parse(report)
            if !rows.isEmpty { return rows }
        }
        if loggedIn() == false { throw SourceError("Claude Code 未登录，请登录订阅账号后刷新") }
        throw SourceError(valid ? "Claude Code 未返回可识别的订阅额度" : "请检查 Claude Code 的登录与 /usage 命令")
    }

    private static func run(_ cli: URL, in work: URL, arguments: [String]) throws -> [String: Any] {
        let task = Process(), output = Pipe()
        task.executableURL = cli
        task.currentDirectoryURL = work
        task.arguments = arguments
        task.environment = CLIEnvironment.environment(for: cli, adding: ["TZ": "UTC", "LC_ALL": "en_US.UTF-8"])
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
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SourceError("Claude Code 返回格式异常")
        }
        return obj
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
