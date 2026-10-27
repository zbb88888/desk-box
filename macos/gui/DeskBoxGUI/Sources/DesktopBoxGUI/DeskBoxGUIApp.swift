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
            Text("Sandboxes: \(viewModel.sandboxes.count)")
            Divider()
            Button("Open Desk Box") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first { window.makeKeyAndOrderFront(nil) }
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
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

