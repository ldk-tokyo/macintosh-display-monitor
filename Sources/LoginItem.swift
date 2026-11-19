import ServiceManagement
import SwiftUI

final class LoginItem: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published var errorMessage: String?

    var registered: Bool { status == .enabled || status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        refresh()
        guard registered != enabled else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { errorMessage = error.localizedDescription }
        refresh()
    }
}

struct LoginItemSetting: View {
    @ObservedObject var item: LoginItem

    var body: some View {
        HStack {
            Toggle("登录时自动启动", isOn: Binding(get: { item.registered }, set: item.setEnabled))
            Spacer()
            if item.status == .requiresApproval {
                Button("在系统设置中允许") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        .onAppear { item.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            item.refresh()
        }
        .alert("登录项设置失败", isPresented: Binding(get: { item.errorMessage != nil }, set: { if !$0 { item.errorMessage = nil } })) {
            Button("好") { item.errorMessage = nil }
        } message: {
            Text(item.errorMessage ?? "")
        }
    }
}
