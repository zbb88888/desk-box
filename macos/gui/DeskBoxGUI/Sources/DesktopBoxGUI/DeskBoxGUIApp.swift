import SwiftUI
import UniformTypeIdentifiers

@main
struct DeskBoxGUIApp: App {
    @StateObject private var daemonManager = DaemonProcessManager()
    @StateObject private var viewModel = SandboxViewModel()

    var body: some Scene {
        WindowGroup("Desk Box") {
            DockerMainView(daemonManager: daemonManager, viewModel: viewModel)
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Quit Desk Box") { NSApplication.shared.terminate(nil) }
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
                    self.errorText = error.localizedDescription
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
