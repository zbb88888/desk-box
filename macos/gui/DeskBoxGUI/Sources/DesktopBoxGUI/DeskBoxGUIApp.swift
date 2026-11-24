import SwiftUI
import UniformTypeIdentifiers

/// M22+ hotfix：显式 AppDelegate，保证 terminate 永不被挂起（即便 display VM 在跑）。
final class DeskBoxAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // M30：仅当设置了 DBX_GUI_SELFTEST 时启用（见 GUISelfTest）。
        GUISelfTest.shared?.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        GUISelfTest.shared?.noteTerminating()
        // 通知各持有者（display VM / 临时私盘）做同步清理；daemon 是独立进程，不随 GUI 退出。
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: sender)
        return .terminateNow
    }
}

@main
struct DeskBoxGUIApp: App {
    @NSApplicationDelegateAdaptor(DeskBoxAppDelegate.self) private var appDelegate
    @StateObject private var daemonManager = DaemonProcessManager()
    @StateObject private var viewModel = SandboxViewModel()

    var body: some Scene {
        WindowGroup("Desk Box") {
            DockerMainView(daemonManager: daemonManager, viewModel: viewModel)
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands {
            // Cmd+Q bug fix：之前把 Quit 塞在 .appSettings（⌘, 槽位）且无快捷键。
            // 改为显式替换 .appTermination 并绑定 ⌘Q，保证菜单项始终存在。
            CommandGroup(replacing: .appTermination) {
                Button("Quit Desk Box") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        MenuBarExtra("Desk Box", systemImage: "shippingbox") {
            MenuBarStatusView(viewModel: viewModel, daemonManager: daemonManager)
        }
        .menuBarExtraStyle(.window)
    }
}

final class SandboxViewModel: ObservableObject, @unchecked Sendable {
    @Published var sandboxes: [SandboxInfo] = []
    @Published var busy = false
    @Published var errorText: String? = nil
    /// 一次性 exec 的输出（移入 viewModel：exec 必须离主线程，@State 不便跨线程回写）。
    @Published var execOutput: String = ""

    let client = DaemonSocketClient(sockPath: DaemonSocketClient.defaultSockPath())

    func refresh() {
        self.busy = true
        DispatchQueue.global().async {
            do {
                let response = try self.client.send(DaemonRequest(kind: "ps"))
                DispatchQueue.main.async {
                    self.sandboxes = response.sandboxes ?? []
                    self.busy = false
                    self.errorText = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.sandboxes = []
                    self.busy = false
                    self.errorText = DaemonErrorPresenter.present(error).logLine
                }
            }
        }
    }
}



/// M17：菜单 bar 加活动列表动作。
struct MenuBarStatusView: View {
    @ObservedObject var viewModel: SandboxViewModel
    @ObservedObject var daemonManager: DaemonProcessManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Desk Box", systemImage: "shippingbox").font(.headline)
                Spacer()
                Circle().fill(daemonManager.status == .connected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(daemonManager.status == .connected ? "daemon on" : "daemon off").font(.caption)
            }
            Divider()
            Text("Sandboxes: \(viewModel.sandboxes.count)").font(.caption)
            if viewModel.sandboxes.isEmpty {
                Text("(none)").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(viewModel.sandboxes, id: \.sandboxId) { sb in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sb.sandboxId.prefix(13) + "…").font(.system(.caption2, design: .monospaced))
                        HStack(spacing: 8) {
                            Text(sb.state).font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Button("stop") { send("stop", id: sb.sandboxId) }.buttonStyle(.link)
                            Button("rm") { send("rm", id: sb.sandboxId) }.buttonStyle(.link)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Divider()
            Button("Open Desk Box") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first { window.makeKeyAndOrderFront(nil) }
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
        .onAppear { viewModel.refresh() }
    }

    private func send(_ kind: String, id: String) {
        // Swift 6 严格并发：MainActor 隔离的属性不能在 Sendable 闭包里直接捕获。
        // 先把 client 取到局部常量（DaemonSocketClient 自身是线程安全的），
        // 刷新再回主线程。
        let client = viewModel.client
        DispatchQueue.global().async {
            var req = DaemonRequest(kind: kind)
            req.sandboxId = id
            req.force = true
            _ = try? client.send(req, timeoutSec: 10)
            Task { @MainActor in viewModel.refresh() }
        }
    }
}
