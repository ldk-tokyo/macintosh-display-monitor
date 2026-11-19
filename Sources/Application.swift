import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let monitor = Monitor()
    private var settingsWindow: NSWindow?
    private var item: NSStatusItem?
    private var repositioning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let menu = NSMenu()
        append("主屏设置…", to: menu, action: #selector(openSettings), key: ",")
        append("退出专用显示", to: menu, action: #selector(stopDisplay))
        menu.addItem(.separator())
        append("退出副屏监视器", to: menu, action: #selector(quit), key: "q")
        appItem.submenu = menu; NSApp.mainMenu = mainMenu

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = monitorGaugeIcon
        item.button?.toolTip = "副屏监视器"
        item.menu = menu.copy() as? NSMenu
        self.item = item
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(woke), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchReason = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        if launchReason != OSType(keyAELaunchedAsLogInItem) { openSettings() }
        monitor.start()
    }
    private func append(_ title: String, to menu: NSMenu, action: Selector, key: String = "") {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self; menu.addItem(entry)
    }
    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = NSHostingView(rootView: SettingsView(monitor: monitor))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.contentView = view
            w.title = "副屏监视器 · 主屏设置"
            w.isReleasedWhenClosed = false
            w.delegate = self; settingsWindow = w
            positionSettings(center: true)
        }
        settingsWindow?.deminiaturize(nil)
        positionSettings()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func stopDisplay() { monitor.disable() }
    @objc private func quit() { NSApp.terminate(nil) }
    private var activeSession = true
    @objc private func sleeping() { activeSession = false; monitor.suspend() }
    @objc private func woke() {
        activeSession = true
        screensChanged()
        monitor.refreshQuotas()
    }
    @objc private func screensChanged() {
        if activeSession { monitor.screensChanged() }
        positionSettings()
    }
    private func positionSettings(center: Bool = false) {
        guard !repositioning, let w = settingsWindow, let bounds = NSScreen.primary?.visibleFrame else { return }
        let frame = w.frame
        guard center || !bounds.contains(frame) else { return }
        let x = center ? bounds.midX - frame.width / 2 : min(max(bounds.minX, frame.minX), bounds.maxX - frame.width)
        let y = center ? bounds.midY - frame.height / 2 : min(max(bounds.minY, frame.minY), bounds.maxY - frame.height)
        repositioning = true
        w.setFrameOrigin(NSPoint(x: x, y: y))
        repositioning = false
    }
    func windowDidMove(_ notification: Notification) { positionSettings() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(); return true
    }
    func applicationWillTerminate(_ notification: Notification) { monitor.shutdown() }
}

@main
enum EntryPoint {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.dropFirst().elementsEqual(["--enable-login-item"]) {
            let item = LoginItem()
            item.setEnabled(true)
            switch item.status {
            case .enabled: print("登录项已启用")
            case .requiresApproval:
                fputs("登录项等待系统批准\n", stderr)
                exit(2)
            default:
                fputs((item.errorMessage ?? "登录项未启用") + "\n", stderr)
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
