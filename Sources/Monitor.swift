import AppKit
import SwiftUI

struct CanvasSize: Hashable {
    let width: Int
    let height: Int
    var label: String { "\(width) × \(height)" }

    init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }

    static let presets = [
        CanvasSize(800, 480), CanvasSize(1024, 600), CanvasSize(1024, 768),
        CanvasSize(1280, 720), CanvasSize(1280, 800), CanvasSize(1920, 1080),
        CanvasSize(1920, 1200), CanvasSize(2560, 1440), CanvasSize(3440, 1440),
        CanvasSize(3840, 2160), CanvasSize(720, 1280), CanvasSize(1080, 1920)
    ]
}

struct ScreenChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let size: CanvasSize
}

final class Monitor: ObservableObject {
    static let modules = [("cpu", "CPU"), ("gpu", "GPU"), ("memory", "内存"), ("network", "网络"),
                          ("Codex", "Codex"), ("Claude Code", "Claude Code")]
    private let defaults: UserDefaults
    let display = DedicatedDisplay()
    let loginItem = LoginItem()
    private let sampler = HardwareSampler()
    private let sampling = DispatchQueue(label: "monitor.metrics", qos: .utility)
    private var samplingNow = false
    private var sampleTimer: Timer?
    private var quotaTimer: Timer?
    private var restoreTimer: Timer?
    private var activeReads = Set<String>()
    private var results = ["Codex": QuotaResult.waiting("Codex"), "Claude Code": QuotaResult.waiting("Claude Code")]
    @Published private(set) var metrics = Metrics()
    @Published private(set) var choices: [ScreenChoice] = []
    @Published private(set) var displayStatus = "专用显示未启用"
    @Published private(set) var enabled: Bool
    @Published private(set) var status = [String: String]()
    @Published private(set) var reading = Set<String>()
    @Published var selected: String {
        didSet {
            defaults.set(selected, forKey: "screen")
            if oldValue != selected {
                canvasOverride = nil
                if enabled { reconcile() }
            }
        }
    }
    @Published var canvasOverride: CanvasSize? { didSet { publish() } }
    var selectedScreen: ScreenChoice? { choices.first { $0.id == selected } }
    @Published var dark: Bool { didSet { defaults.set(dark, forKey: "dark"); publish() } }
    @Published var safeMargin: Int {
        didSet { defaults.set(safeMargin, forKey: "safeMargin"); publish() }
    }
    @Published var textSize: Int {
        didSet { defaults.set(textSize, forKey: "textSize"); publish() }
    }
    @Published var seconds: Int { didSet { defaults.set(seconds, forKey: "seconds"); startSampling() } }
    @Published var minutes: Int { didSet { defaults.set(minutes, forKey: "minutes"); startQuotaTimer() } }
    @Published private(set) var modules: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = defaults.string(forKey: "screen") ?? ""
        dark = defaults.bool(forKey: "dark")
        safeMargin = min(10, max(0, defaults.integer(forKey: "safeMargin")))
        let size = defaults.integer(forKey: "textSize")
        switch size {
        case 100: textSize = 100
        case 145, 155: textSize = 155 // Retain the extra-large preset across the size increase.
        default: textSize = 125
        }
        enabled = defaults.bool(forKey: "enabled")
        let hardware = defaults.integer(forKey: "seconds")
        seconds = [1, 2, 5].contains(hardware) ? hardware : 2
        let interval = defaults.integer(forKey: "minutes")
        minutes = [5, 10, 15].contains(interval) ? interval : 5
        let known = Set(Self.modules.map { $0.0 })
        let stored = Set(defaults.stringArray(forKey: "modules") ?? Array(known)).intersection(known)
        modules = stored.isEmpty ? known : stored
        display.failure = { [weak self] msg in self?.disable(message: msg) }
    }
    func start() {
        screensChanged()
        startSampling()
        refreshQuotas()
        startQuotaTimer()
    }
    func shutdown() {
        sampleTimer?.invalidate(); quotaTimer?.invalidate()
        suspend()
    }
    func screensChanged() {
        choices = NSScreen.screens.filter(\.eligible).map {
            let size = CanvasSize(Int(($0.frame.width * $0.backingScaleFactor).rounded()),
                                  Int(($0.frame.height * $0.backingScaleFactor).rounded()))
            return ScreenChoice(id: $0.stableID, name: $0.localizedName, size: size)
        }
        if !enabled && selected.isEmpty && choices.count == 1 { selected = choices[0].id }
        reconcile()
    }
    private func reconcile(manual: Bool = false) {
        restoreTimer?.invalidate()
        restoreTimer = nil
        guard enabled else { return }
        guard let screen = NSScreen.screens.first(where: { $0.stableID == selected && $0.eligible }) else {
            display.stop()
            displayStatus = "等待所选副屏连接并进入扩展模式"
            return
        }
        if display.id == screen.displayID && display.screenUUID == screen.stableID {
            display.updateFrame(screen)
            publish()
            return
        }
        do {
            try display.start(on: screen)
            displayStatus = "\(screen.localizedName) 正在专用显示"
            publish()
        } catch {
            if manual {
                disable(message: error.localizedDescription)
            } else {
                // At login WindowServer can list a display before capture is ready.
                displayStatus = "等待恢复副屏 · " + error.localizedDescription
                restoreTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                    self?.screensChanged()
                }
            }
        }
    }
    func enable() {
        guard choices.contains(where: { $0.id == selected }) else {
            displayStatus = "请先选择可用副屏"; return
        }
        enabled = true
        defaults.set(true, forKey: "enabled")
        reconcile(manual: true)
    }
    func disable(message: String = "专用显示已关闭") {
        enabled = false; defaults.set(false, forKey: "enabled")
        suspend(); canvasOverride = nil; displayStatus = message
    }
    func suspend() {
        restoreTimer?.invalidate()
        restoreTimer = nil
        display.stop()
    }
    func setModule(_ key: String, on: Bool) {
        guard Self.modules.contains(where: { $0.0 == key }) else { return }
        if on { modules.insert(key) } else if modules.count > 1 { modules.remove(key) }
        defaults.set(Array(modules), forKey: "modules")
        if on && results[key] != nil { read(key) }
        publish()
    }
    private func startSampling() {
        sampleTimer?.invalidate()
        sample()
        let t = Timer(timeInterval: TimeInterval(seconds), repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common); sampleTimer = t
    }
    private func sample() {
        guard !samplingNow else { return }
        samplingNow = true
        sampling.async { [weak self] in
            guard let self else { return }
            let result = self.sampler.sample()
            DispatchQueue.main.async {
                self.samplingNow = false
                self.metrics = result
                self.publish()
            }
        }
    }
    private func startQuotaTimer() {
        quotaTimer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in self?.refreshQuotas() }
        RunLoop.main.add(timer, forMode: .common); quotaTimer = timer
    }
    func refreshQuotas() {
        for source in ["Codex", "Claude Code"] where modules.contains(source) { read(source) }
    }
    func read(_ provider: String) {
        guard activeReads.insert(provider).inserted else { return }
        reading = activeReads
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = QuotaResult.read(provider) {
                if provider == "Codex" { return try CodexQuota.load() }
                return try ClaudeQuota.load()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.results[provider] = result
                self.status[provider] = result.message
                self.activeReads.remove(provider)
                self.reading = self.activeReads
                self.publish()
            }
        }
    }
    private func publish() {
        let sources: [[String: Any]] = ["Codex", "Claude Code"].compactMap { name in
            guard let result = results[name] else { return nil }
            var item: [String: Any] = ["provider": name, "rows": result.rows.map(\.payload), "message": result.message]
            if let updated = result.updated { item["updated"] = updated.timeIntervalSince1970 }
            return item
        }
        var state: [String: Any] = ["dark": dark, "margin": safeMargin, "textSize": textSize, "metrics": metrics.payload,
                                    "modules": Array(modules), "sources": sources]
        if let size = canvasOverride ?? selectedScreen?.size {
            state["canvas"] = ["width": size.width, "height": size.height]
        }
        display.dashboard?.submit(state)
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(nsImage: monitorGaugeIcon)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                Text("副屏监视器").font(.title2.bold())
                Spacer()
                Text("主屏设置").foregroundStyle(.secondary)
            }
            GroupBox("专用显示") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("目标副屏", selection: $monitor.selected) {
                        if !monitor.choices.contains(where: { $0.id == monitor.selected }) {
                            Text(monitor.selected.isEmpty ? "请选择副屏" : "所选副屏未连接").tag(monitor.selected)
                        }
                        ForEach(monitor.choices) { Text("\($0.name) · \($0.size.label)").tag($0.id) }
                    }
                    Picker("画布分辨率", selection: $monitor.canvasOverride) {
                        Text(monitor.selectedScreen.map { "跟随副屏 · \($0.size.label)" } ?? "跟随副屏")
                            .tag(nil as CanvasSize?)
                        ForEach(CanvasSize.presets, id: \.self) { size in
                            Text(size.label).tag(Optional(size))
                        }
                    }
                    .disabled(monitor.selectedScreen == nil)
                    HStack {
                        Text(monitor.displayStatus).foregroundStyle(.secondary)
                        Spacer()
                        Button(monitor.enabled ? "退出专用显示" : "启用专用显示") {
                            if monitor.enabled { monitor.disable() } else { monitor.enable() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!monitor.enabled && !monitor.choices.contains(where: { $0.id == monitor.selected }))
                    }
                    Divider()
                    LoginItemSetting(item: monitor.loginItem)
                }.padding(6)
            }
            GroupBox("外观与采样") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Macintosh 外观", selection: $monitor.dark) {
                        Text("现有模式").tag(false); Text("深色模式").tag(true)
                    }.pickerStyle(.segmented)
                    Picker("副屏字号", selection: $monitor.textSize) {
                        Text("标准").tag(100); Text("大字").tag(125); Text("特大").tag(155)
                    }.pickerStyle(.segmented)
                    HStack {
                        Text("四边留白")
                        Slider(value: Binding(get: { Double(monitor.safeMargin) },
                                              set: { monitor.safeMargin = Int($0.rounded()) }), in: 0...10, step: 1)
                            .accessibilityLabel("副屏四边留白")
                        Text("\(monitor.safeMargin)%").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                    HStack {
                        Picker("硬件采样", selection: $monitor.seconds) {
                            ForEach([1, 2, 5], id: \.self) { Text("\($0) 秒").tag($0) }
                        }
                        Picker("额度刷新", selection: $monitor.minutes) {
                            ForEach([5, 10, 15], id: \.self) { Text("\($0) 分钟").tag($0) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("显示模块") {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(Monitor.modules, id: \.0) { key, label in
                        Toggle(label, isOn: Binding(get: { monitor.modules.contains(key) },
                                                    set: { monitor.setModule(key, on: $0) }))
                            .disabled(monitor.modules.count == 1 && monitor.modules.contains(key))
                    }
                }.padding(6)
            }
            GroupBox("额度来源") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(["Codex", "Claude Code"], id: \.self) { name in
                        HStack {
                            Text(name).fontWeight(.medium)
                            Spacer()
                            Text(monitor.reading.contains(name) ? "正在读取…" : (monitor.status[name] ?? "等待读取"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("使用本机已登录的 CLI 账户").foregroundStyle(.secondary)
                        Spacer()
                        Button("立即刷新") { monitor.refreshQuotas() }.disabled(!monitor.reading.isEmpty)
                    }
                }.padding(6)
            }
        }.padding(20).frame(width: 550)
    }
}
