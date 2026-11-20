import AppKit
import Foundation

@main
enum Smoke {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SourceError(message) }
    }
    static func wait(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func checkCanvas() throws {
        let dashboard = Dashboard()
        dashboard.view.frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        try dashboard.load()
        func evaluate(_ script: String) throws -> String {
            var result: String?
            dashboard.view.evaluateJavaScript(script) { value, error in
                result = value as? String ?? error?.localizedDescription ?? "缺少结果"
            }
            let deadline = Date().addingTimeInterval(5)
            while result == nil && Date() < deadline { wait(0.03) }
            guard let result else { throw SourceError("WebKit 超时") }
            return result
        }
        let deadline = Date().addingTimeInterval(5)
        while try evaluate("typeof window.monitor") != "object" && Date() < deadline { wait(0.05) }
        for size in CanvasSize.presets {
            let result = try evaluate("""
                (() => {
                  const canvas={width:\(size.width),height:\(size.height)};
                  const rows=Array.from({length:12},(_,i)=>({provider:'Codex',window:'每周',remaining:50,reset:Date.now()/1000+600+i}));
                  for(const margin of [0,10]) {
                    monitor.render({canvas, margin, textSize:155, modules:['cpu','gpu','memory','network','Codex'],
                      metrics:{cpu:35,gpu:88,memory:60,usedGB:18,totalGB:32,download:20,upload:30},sources:[{provider:'Codex',rows}]});
                    const main=document.querySelector('main').getBoundingClientRect();
                    const fit=Math.min(innerWidth/canvas.width,innerHeight/canvas.height), extent=1-margin/50;
                    if(Math.abs(main.width-canvas.width*fit*extent)>1 || Math.abs(main.height-canvas.height*fit*extent)>1 ||
                       Math.abs(main.left+main.right-innerWidth)>1 || Math.abs(main.top+main.bottom-innerHeight)>1) return '画布未居中适配';
                    const body=document.querySelector('tbody');
                    if(!body.rows.length || body.getBoundingClientRect().bottom>document.querySelector('.ledger-space').getBoundingClientRect().bottom+1) return '额度分页溢出';
                    if(!document.querySelector('.time-zone').textContent || document.body.textContent.includes('副屏专用显示')) return '页脚内容错误';
                  }
                  return 'PASS';
                })()
                """)
            try expect(result == "PASS", "\(size.label) · \(result)")
        }
        let domain = "monitor.test.canvas." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let monitor = Monitor(defaults: defaults)
        monitor.screensChanged()
        try expect(monitor.canvasOverride == nil, "初始画布应跟随所选副屏")
        monitor.canvasOverride = CanvasSize(1024, 768)
        monitor.selected = "another-display"
        try expect(monitor.canvasOverride == nil, "更换目标应跟随新副屏")
        monitor.canvasOverride = CanvasSize(1280, 800)
        monitor.disable()
        try expect(monitor.canvasOverride == nil, "再次开启应跟随副屏")
        print("Canvas fit, pagination, footer and default selection: PASS")
    }
    static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        try checkCanvas()
        if CommandLine.arguments.contains("--login-item") {
            try expect(Bundle.main.bundleIdentifier == "local.dingkun.MacintoshMonitor.smoke", "需要独立测试应用")
            let item = LoginItem()
            try expect(!item.registered, "测试登录项已存在")
            defer { item.setEnabled(false) }
            item.setEnabled(true)
            try expect(item.errorMessage == nil && item.status == .enabled, "测试登录项未获启用："
                       + (item.errorMessage ?? String(item.status.rawValue)))
            item.setEnabled(false)
            try expect(item.errorMessage == nil && !item.registered, "测试登录项未能注销")
            print("macOS login item register, read back and unregister: PASS")
        }
        let sampler = HardwareSampler()
        _ = sampler.sample(); wait(1.2)
        let m = sampler.sample()
        print("Hardware:", m.payload)
        try expect(m.cpu != nil && m.memory != nil && m.download != nil, "硬件样本缺失")
        let mock = ClaudeQuota.parse("Current session: 62% used · resets 4:15pm (Asia/Tokyo)\nCurrent week (all models): 36% used · resets Nov 24 at 10am (Asia/Tokyo)\n  95%  unrelated text")
        try expect(mock.count == 2 && mock[0].remaining == 38 && mock.allSatisfy { $0.reset != nil }, "Claude 窗口解析失败")
        let costOnly: [String: Any] = ["is_error": false, "num_turns": 0, "result": "Estimated cost: $0.0000"]
        for loggedIn in [false, true, nil] as [Bool?] {
            let result = QuotaResult.read("Claude Code") {
                try ClaudeQuota.subscriptionRows(from: costOnly) { loggedIn }
            }
            try expect(result.rows.isEmpty && result.message.contains("未登录") == (loggedIn == false),
                       "Claude 成本报告未按登录状态显示提示")
        }
        for source in ["Codex", "Claude Code"] {
            let r = QuotaResult.read(source) {
                if source == "Codex" { return try CodexQuota.load() }
                return try ClaudeQuota.load()
            }
            print("\(source): \(r.message), windows:", r.rows.map { ($0.window, $0.remaining, $0.reset != nil) })
        }

        let output = DedicatedDisplay()
        defer { output.stop() }
        guard let primary = NSScreen.primary else { throw SourceError("缺少主屏") }
        do {
            try output.start(on: primary)
            throw SourceError("主屏保护失效")
        } catch {
            try expect(output.id == nil && error.localizedDescription.contains("副屏"), "未拒绝主屏")
        }
        print("Main display exclusion: PASS")
        guard CommandLine.arguments.contains("--display") else { return }
        // Only run on an explicitly named external display.
        guard let i = CommandLine.arguments.firstIndex(of: "--display"), i+1 < CommandLine.arguments.count,
              let screen = NSScreen.screens.first(where: { $0.eligible && $0.localizedName == CommandLine.arguments[i+1] }) else {
            throw SourceError("未找到指定的副屏")
        }
        let id = screen.displayID
        try output.start(on: screen)
        try expect(CGShieldingWindowID(id) != 0 && CGShieldingWindowID(primary.displayID) == 0, "遮罩位置错误")
        try expect(output.window?.screen?.displayID == id && output.window?.frame == screen.frame, "窗口未覆盖副屏")
        try expect(output.window?.canBecomeKey == false, "副屏可以接收焦点")
        if let original = CGEvent(source: nil)?.location {
            defer { CGWarpMouseCursorPosition(original) }
            let external = CGDisplayBounds(id)
            CGWarpMouseCursorPosition(CGPoint(x: external.midX, y: external.midY))
            wait(0.15)
            let current = CGEvent(source: nil)!.location
            try expect(!external.contains(current), "鼠标仍停留在专用显示区域")
        }
        let now = Date().timeIntervalSince1970
        let sources: [[String: Any]] = [
            ["provider":"Codex", "message":"已同步", "updated":now, "rows":[["provider":"Codex","window":"每周","remaining":86,"reset":now+300000]]],
            ["provider":"Claude Code","message":"已同步","updated":now,"rows":[["provider":"Claude Code","window":"5 小时","remaining":38,"reset":now+5000]]]
        ]
        for dark in [false,true] {
            let modules: [String] = dark ? ["gpu","memory","Claude Code"] : Monitor.modules.map { $0.0 }
            output.dashboard?.submit(["modules": modules, "metrics": m.payload, "sources": sources, "dark": dark])
            guard let view = output.dashboard?.view else { throw SourceError("缺少页面") }
            var ok = false
            let deadline = Date().addingTimeInterval(5)
            repeat {
                wait(0.1)
                var returned = false
                let script = """
                  !!window.monitor && document.documentElement.dataset.mode === '\(dark ? "dark":"classic")' &&
                  document.querySelectorAll('tbody tr').length === \(dark ? 1:2) &&
                  document.querySelector('tbody tr .service')?.textContent === 'Claude Code' &&
                  document.querySelector('.dial').hidden === \(dark) &&
                  document.querySelectorAll('.number')[1].textContent.trim() === '\(m.gpu.map { String(Int($0.rounded())) } ?? "—")%' &&
                  document.querySelector('footer').getBoundingClientRect().bottom <= innerHeight+1
                  """
                view.evaluateJavaScript(script) { value, _ in ok = (value as? Bool) == true; returned = true }
                while !returned && Date() < deadline { wait(0.03) }
            } while !ok && Date() < deadline
            try expect(ok, "副屏 WebKit 渲染或排序不正确")
        }
        if let view = output.dashboard?.view {
            var layoutResult: String?
            let script = """
            (() => {
              const realDate=Date, base=Date.now(), unit=Math.min(innerWidth/1280,innerHeight/720);
              let offset=0;
              window.Date=class extends realDate {
                constructor(...args) { super(...(args.length?args:[base+offset])); }
              };
              try {
                const rows=Array.from({length:8},(_,i)=>({provider:'Claude Code',window:'每周 · Fable',
                  remaining:100-i,reset:base/1000+86400*(i+1)}));
                for(const dark of [false,true]) for(const margin of [0,5,10]) for(const textSize of [100,125,155]) {
                  const seen=new Set();
                  const state={dark,margin,textSize,modules:['cpu','gpu','memory','network','Claude Code'],
                    metrics:{cpu:100,gpu:100,memory:100,usedGB:31.9,totalGB:32,download:1250,upload:112.5},
                    sources:[{provider:'Claude Code',rows,message:'已同步',updated:base/1000}]};
                  for(let page=0;page<8;page++) {
                    offset=page*12000;
                    window.monitor.render(state);
                    const main=document.querySelector('main').getBoundingClientRect();
                    if(main.left<innerWidth*margin/100-1 || main.right>innerWidth*(1-margin/100)+1 ||
                       main.top<innerHeight*margin/100-1 || main.bottom>innerHeight*(1-margin/100)+1) return '安全边距不符';
                    const ledger=document.querySelector('.ledger-space').getBoundingClientRect();
                    for(const tr of document.querySelectorAll('tbody tr')) {
                      if(tr.getBoundingClientRect().bottom>ledger.bottom+1) return '末行超出可用高度';
                      seen.add(tr.querySelector('.balance strong').textContent);
                    }
                    const walk=document.createTreeWalker(document.querySelector('main'),NodeFilter.SHOW_TEXT);
                    while(walk.nextNode()) {
                      if(!walk.currentNode.textContent.trim()) continue;
                      const range=document.createRange();range.selectNodeContents(walk.currentNode);
                      const r=range.getBoundingClientRect();
                      if(r.width && (r.left<main.left-1 || r.right>main.right+1 || r.top<main.top-1 || r.bottom>main.bottom+1))
                        return '文字超出边框 '+walk.currentNode.textContent;
                    }
                    if(textSize===125 && parseFloat(getComputedStyle(document.querySelector('.number')).fontSize)<50*unit) return '默认字号过小';
                  }
                  if(seen.size!==8) return '翻页有遗漏';
                }
                return 'PASS';
              } finally {window.Date=realDate;}
            })()
            """
            view.evaluateJavaScript(script) { result, error in layoutResult = result as? String ?? error?.localizedDescription }
            let limit=Date().addingTimeInterval(8)
            while layoutResult == nil && Date() < limit { wait(0.05) }
            try expect(layoutResult == "PASS", "留白、字号与分页回归：" + (layoutResult ?? "超时"))
            print("Safe area, text bounds and all eight rows: PASS")
        }
        output.stop(); wait(0.25)
        try expect(CGShieldingWindowID(id) == 0 && output.id == nil, "独占显示未释放")
        let domain = "local.dingkun.MacintoshMonitor.smoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("missing-test-display", forKey: "screen")
        defaults.set(true, forKey: "enabled")
        let waiting = Monitor(defaults: defaults)
        waiting.screensChanged()
        try expect(waiting.enabled && waiting.display.id == nil && waiting.selected == "missing-test-display",
                   "副屏未接入时应等待上次的目标")
        waiting.disable()
        let off = Monitor(defaults: defaults)
        off.selected = screen.stableID
        off.screensChanged()
        try expect(!off.enabled && off.display.id == nil, "启动时错误启用了上次已关闭的副屏")
        let first = Monitor(defaults: defaults)
        try expect(first.safeMargin == 0, "默认留白应为 0%")
        defaults.set(145, forKey: "textSize")
        try expect(Monitor(defaults: defaults).textSize == 155, "原特大字号未升级")
        first.selected = screen.stableID
        first.dark = true
        first.screensChanged()
        first.enable() // Exercise the same controller as the main-screen button.
        try expect(first.enabled && first.display.id == id, "设置未启用副屏")
        let physicalSize = CanvasSize(Int((screen.frame.width * screen.backingScaleFactor).rounded()),
                                      Int((screen.frame.height * screen.backingScaleFactor).rounded()))
        try expect(first.selectedScreen?.size == physicalSize && first.canvasOverride == nil, "画布默认分辨率不符")
        let initialMode = CGDisplayCopyDisplayMode(id)?.ioDisplayModeID
        for selection in [CanvasSize(1024, 768), nil] {
            first.canvasOverride = selection
            let expectedWidth = (selection ?? physicalSize).width
            var matches = false
            let deadline = Date().addingTimeInterval(5)
            while !matches && Date() < deadline {
                first.display.dashboard?.view.evaluateJavaScript("document.querySelector('.canvas')?.offsetWidth") { value, _ in
                    matches = value as? Int == expectedWidth
                }
                wait(0.1)
            }
            try expect(matches && CGDisplayCopyDisplayMode(id)?.ioDisplayModeID == initialMode, "切换画布或保持原输出模式失败")
        }
        print("\(screen.localizedName) canvas auto \(physicalSize.label), manual switch and system mode: PASS")
        first.shutdown()
        let restored = Monitor(defaults: defaults)
        defer { restored.disable(); restored.shutdown() }
        restored.start()
        try expect(restored.enabled && restored.dark && restored.display.id == id, "已保存显示器或外观未恢复")
        let limit = Date().addingTimeInterval(25)
        while (!restored.reading.isEmpty || restored.metrics.cpu == nil) && Date() < limit { wait(0.1) }
        for name in ["Codex", "Claude Code"] { print("App refresh:", name, restored.status[name] ?? "未返回") }
        wait(0.3)
        if let target = ProcessInfo.processInfo.environment["MONITOR_TEST_SNAPSHOT"], let view = restored.display.dashboard?.view {
            var finished = false
            view.takeSnapshot(with: nil) { image, _ in
                if let data = image?.tiffRepresentation,
                   let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: target))
                }
                finished = true
            }
            let bound = Date().addingTimeInterval(3)
            while !finished && Date() < bound { wait(0.03) }
        }
        restored.disable()
        try expect(!restored.enabled && CGShieldingWindowID(id) == 0, "主屏设置未能释放副屏")
        print("External capture, shielding, pointer exclusion, two themes, window sorting, filters, persistence and release: PASS")
    }
}
