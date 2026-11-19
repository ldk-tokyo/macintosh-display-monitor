import AppKit
import CoreGraphics
import WebKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    var stableID: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }
    static var primary: NSScreen? { screens.first { $0.displayID == CGMainDisplayID() } }
    var eligible: Bool {
        let id = displayID
        return id != 0 && id != CGMainDisplayID() && CGDisplayIsOnline(id) != 0
            && CGDisplayIsActive(id) != 0 && CGDisplayIsInMirrorSet(id) == 0 && !stableID.isEmpty
    }
}

private final class OutputWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) { /* Display-only surface. */ }
}

final class Dashboard: NSObject, WKNavigationDelegate {
    let view: WKWebView
    private var ready = false
    private var pending: [String: Any]?
    private var sending = false
    private var loadGeneration = 0
    var failed: (() -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: .zero, configuration: config)
        super.init()
        view.navigationDelegate = self
        view.underPageBackgroundColor = .black
    }
    func load() throws {
        guard let url = Bundle.main.url(forResource: "Dashboard", withExtension: "html") else {
            throw SourceError("缺少显示页面资源")
        }
        loadGeneration += 1
        ready = false
        sending = false
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    func submit(_ payload: [String: Any]) { pending = payload; flush() }
    private func flush() {
        guard ready, !sending, let payload = pending else { return }
        let generation = loadGeneration
        pending = nil; sending = true
        view.callAsyncJavaScript("window.monitor.render(state); return true", arguments: ["state": payload], in: nil, in: .page) { [weak self] result in
            guard let self, self.loadGeneration == generation else { return }
            self.sending = false
            if case .failure = result { self.failed?(); return }
            self.flush()
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; flush() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed?() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed?() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed?() }
}

final class DedicatedDisplay {
    private(set) var id: CGDirectDisplayID?
    private(set) var screenUUID: String?
    private(set) var dashboard: Dashboard?
    private(set) var window: NSWindow?
    private var pointerTimer: Timer?
    private var lastAllowed: CGPoint?
    var failure: ((String) -> Void)?

    func start(on screen: NSScreen) throws {
        guard screen.eligible, NSScreen.screens.contains(where: { $0.displayID == screen.displayID && $0.eligible }) else {
            throw SourceError("请选择处于扩展模式的副屏")
        }
        if id == screen.displayID { return }
        stop()
        let target = screen.displayID
        guard CGShieldingWindowID(target) == 0 else { throw SourceError("副屏已被另一个应用独占") }
        let page = Dashboard()
        try page.load()
        guard CGDisplayCapture(target) == .success else { throw SourceError("macOS 未授予副屏独占显示") }
        id = target; screenUUID = screen.stableID
        guard CGShieldingWindowID(target) != 0 else {
            stop()
            throw SourceError("系统未建立副屏独占遮罩")
        }
        let w = OutputWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.isMovable = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        w.contentView = page.view
        w.setFrame(screen.frame, display: true)
        window = w; dashboard = page
        page.failed = { [weak self] in self?.failure?("显示页面加载失败，已退出专用显示") }
        w.orderFrontRegardless()
        lastAllowed = nil
        excludePointer()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.excludePointer() }
        RunLoop.main.add(timer, forMode: .common); pointerTimer = timer
    }
    private func excludePointer() {
        guard let id, let pointer = CGEvent(source: nil)?.location else { return }
        guard id != CGMainDisplayID() else { failure?("目标屏幕已成为主屏"); return }
        if !CGDisplayBounds(id).contains(pointer) { lastAllowed = pointer; return }
        let primary = CGDisplayBounds(CGMainDisplayID())
        let allowed = NSScreen.screens.filter { $0.displayID != id }.map { CGDisplayBounds($0.displayID) }
        if let last = lastAllowed, allowed.contains(where: { $0.contains(last) }) {
            CGWarpMouseCursorPosition(last)
        } else {
            CGWarpMouseCursorPosition(CGPoint(x: min(max(primary.minX + 2, pointer.x), primary.maxX - 2),
                                              y: min(max(primary.minY + 2, pointer.y), primary.maxY - 2)))
        }
    }
    func updateFrame(_ screen: NSScreen) {
        if window?.frame != screen.frame { window?.setFrame(screen.frame, display: true) }
    }
    func stop() {
        pointerTimer?.invalidate(); pointerTimer = nil
        dashboard?.failed = nil
        window?.orderOut(nil); window?.close(); window = nil; dashboard = nil
        if let id { CGDisplayRelease(id) }
        id = nil; screenUUID = nil; lastAllowed = nil
    }
    deinit { stop() }
}
