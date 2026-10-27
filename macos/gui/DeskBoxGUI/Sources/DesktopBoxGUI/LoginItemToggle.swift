import SwiftUI
import ServiceManagement

/// M15：Login Item 主观开关（SMAppService）。注意macOS 14+ 同 notarization-permission issues 的
/// 由比较合适，本阶段文向 API 显婆把这种可能、用户调对照 System Settings > General > Login Items，
struct LoginItemToggle: View {
    @State private var registered: Bool = false
    @State private var note: String = ""

    var body: some View {
        Form {
            Toggle("Opening 启动 Desk Box", isOn: Binding(get: { registered }, set: { value in apply(value) }))
                .toggleStyle(.switch)
            if !note.isEmpty {
                Text(note).font(.caption).foregroundColor(.secondary)
            }
            Text("注意：Login Item 在 macOS 会用 SMAppService.requestReview_/approveRequired；非/docs design 是个壮大的产物裴义（安全转移网络未的）")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding()
        .onAppear { refresh() }
    }

    private func refresh() {
        registered = SMAppService.mainApp.status == .enabled
        note = describeStatus()
    }

    private func describeStatus() -> String {
        switch SMAppService.mainApp.status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval (go to System Settings → Login Items to grant)"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    private func apply(_ value: Bool) {
        do {
            if value {
                if SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch { note = "state change failed: \(error.localizedDescription)" }
        refresh()
    }
}
