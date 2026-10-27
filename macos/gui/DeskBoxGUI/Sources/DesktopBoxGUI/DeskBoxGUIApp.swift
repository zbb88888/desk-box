import SwiftUI
import UniformTypeIdentifiers

@main
struct DeskBoxGUIApp: App {
    @StateObject private var daemonManager = DaemonProcessManager()
    @StateObject private var viewModel = SandboxViewModel()

    var body: some Scene {
        WindowGroup("Desk Box") {
            MainView(daemonManager: daemonManager, viewModel: viewModel)
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

struct MainView: View {
    @ObservedObject var daemonManager: DaemonProcessManager
    @ObservedObject var viewModel: SandboxViewModel
    @StateObject private var logStore = LogStore.shared
    @StateObject private var displayModel = DisplaySandboxViewModel()

    @State private var dbxPath: String = {
        FileManager.default.currentDirectoryPath + "/.build/release/dbx-poc"
    }()
    @State private var manifestPath: String = {
        FileManager.default.currentDirectoryPath + "/guest/manifest.json"
    }()
    @State private var execSandboxId = ""
    @State private var execCommand = ""
    @State private var execOutput = ""
    @State private var terminalSandboxId: String?
    @State private var settingsPresented = false
    @State private var displayPresented = false

    var body: some View {
        VStack(spacing: 12) {
            headerBar
            Divider()
            pathsGrid
            controlButtons
            sandboxList
            Divider()
            execRow
            Divider()
            daemonLogView
        }
        .padding(.vertical)
        .onAppear {
            refresh()
        }
        .onReceive(Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()) { _ in
            viewModel.refresh()
        }
        .sheet(isPresented: Binding(get: { terminalSandboxId != nil },
                                    set: { if !$0 { terminalSandboxId = nil } })) {
            terminalSheet
        }
        .sheet(isPresented: $settingsPresented) {
            SettingsPanel(client: viewModel.client, log: LogStore.shared)
        }
        .sheet(isPresented: $displayPresented) {
            DisplaySessionView(model: displayModel)
                .frame(minWidth: 800, minHeight: 560)
        }
    }

    private var headerBar: some View {
        HStack {
            Label("Desk Box", systemImage: "shippingbox").font(.title2)
            Spacer()
            statusBadge
        }
        .padding(.horizontal)
    }

    private var statusBadge: some View {
        HStack {
            Circle().fill(daemonManager.status == .connected ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text(daemonManager.status == .connected ? "daemon connected" : "daemon off")
                .font(.caption)
        }
    }

    private var pathsGrid: some View {
        GridLayout(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("dbx-poc path").gridColumnAlignment(.trailing)
                TextField("", text: $dbxPath).textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("manifest path").gridColumnAlignment(.trailing)
                TextField("", text: $manifestPath).textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("sock").gridColumnAlignment(.trailing)
                Text(daemonManager.clientPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .gridColumnAlignment(.leading)
            }
        }
        .padding(.horizontal)
    }

    private var controlButtons: some View {
        HStack(spacing: 12) {
            Button("Start Daemon") { startDaemon() }.disabled(daemonManager.status == .connected)
            Button("Refresh") { refresh() }
            Button("Run New Sandbox") { run() }.disabled(daemonManager.status != .connected)
            Button("Shutdown Daemon") { stopDaemon() }.disabled(daemonManager.status != .connected)
            Button("Settings") { settingsPresented = true }
            Button("Open Display") {
                openDisplay()
                displayPresented = true
            }
        }
        .padding(.horizontal)
    }

    private var sandboxList: some View {
        List {
            Section("Sandboxes (\(viewModel.sandboxes.count))") {
                ForEach(viewModel.sandboxes, id: \.sandboxId) { sb in
                    SandboxRow(info: sb,
                               onStop: { stop(id: sb.sandboxId) },
                               onRm: { rm(id: sb.sandboxId) },
                               onExecSelect: { execSandboxId = sb.sandboxId },
                               onTerminal: { terminalSandboxId = sb.sandboxId })
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .frame(minHeight: 160)
    }

    private var execRow: some View {
        HStack {
            TextField("sandbox id", text: $execSandboxId)
                .textFieldStyle(.roundedBorder).frame(width: 200)
            TextField("commandline, e.g. /bin/echo hello", text: $execCommand)
                .textFieldStyle(.roundedBorder)
            Button("Exec") { exec() }.disabled(execSandboxId.isEmpty || execCommand.isEmpty)
        }
        .padding(.horizontal)
    }

    private var execOutputView: some View {
        Group {
            if !execOutput.isEmpty {
                ScrollView {
                    Text(execOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 120)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)
                .padding(.horizontal)
            }
        }
    }

    private var daemonLogView: some View {
        VStack(spacing: 4) {
            Text("Daemon Log").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(logStore.lines.indices, id: \.self) { i in
                            Text(logStore.lines[i])
                                .font(.system(.caption2, design: .monospaced))
                                .id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(maxHeight: 140)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)
                .onChange(of: logStore.lines.count) { _ in
                    if let last = logStore.lines.indices.last { proxy.scrollTo(last) }
                }
            }
            if let error = viewModel.errorText, daemonManager.status == .stopped {
                Text(error).foregroundColor(.orange).font(.caption)
            }
        }
        .padding(.horizontal)
    }

    private var terminalSheet: some View {
        Group {
            if let sid = terminalSandboxId {
                TerminalView(sandboxId: sid, client: viewModel.client)
                    .frame(minWidth: 640, minHeight: 420)
            }
        }
    }

    private func startDaemon() {
        do {
            let url = URL(fileURLWithPath: dbxPath).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                LogStore.shared.append("dbx-poc not found at \(url.path). Build & sign first.")
                return
            }
            try daemonManager.startDaemon(dbxBinaryPath: url, sockPath: nil)
        } catch { LogStore.shared.append("startDaemon: \(error.localizedDescription)") }
    }

    private func refresh() { viewModel.refresh(); daemonManager.refresh() }
    private func stopDaemon() { daemonManager.stopDaemon(); refresh() }

    private func run() {
        var req = DaemonRequest(kind: "run")
        req.manifestPath = manifestPath
        send(req, toast: "run done")
    }

    private func stop(id: String) {
        var req = DaemonRequest(kind: "stop")
        req.sandboxId = id
        send(req, toast: "stopped \(id)")
    }

    private func rm(id: String) {
        var req = DaemonRequest(kind: "rm")
        req.sandboxId = id
        req.force = true
        send(req, toast: "removed \(id)")
    }

    private func exec() {
        var req = DaemonRequest(kind: "exec")
        req.sandboxId = execSandboxId
        req.argv = execCommand.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !(req.argv?.isEmpty ?? true) else {
            execOutput = "argv empty"
            return
        }
        do {
            let response = try viewModel.client.send(req)
            execOutput = "exit=\(response.exitCode ?? 0)\n---stdout---\n\(response.stdout ?? "")\n---stderr---\n\(response.stderr ?? "")"
        } catch { execOutput = "daemon: \(error.localizedDescription)" }
    }

    private func openDisplay() {
        let kernel = manifestPath.replacingOccurrences(of: "manifest.json", with: "vmlinuz-virt-gpu")
        let initrd = manifestPath.replacingOccurrences(of: "manifest.json", with: "initrd-deskbox.img")
        let root = manifestPath.replacingOccurrences(of: "manifest.json", with: "root-disk.raw")
        displayModel.start(
            kernelPath: URL(fileURLWithPath: kernel),
            initrdPath: URL(fileURLWithPath: initrd),
            rootDiskPath: URL(fileURLWithPath: root),
            cpu: 2, memMiB: 2048
        )
    }

    private func send(_ req: DaemonRequest, toast: String) {
        do {
            _ = try viewModel.client.send(req)
            LogStore.shared.append(toast)
            refresh()
        } catch {
            LogStore.shared.append("\(req.kind) fail: \(error.localizedDescription)")
            execOutput = "daemon: \(error.localizedDescription)"
        }
    }
}

struct SandboxRow: View {
    let info: SandboxInfo
    let onStop: () -> Void
    let onRm: () -> Void
    let onExecSelect: () -> Void
    let onTerminal: () -> Void
    var body: some View {
        HStack {
            Text(info.sandboxId).font(.system(.body, design: .monospaced))
            Text(info.state)
            Spacer()
            Text(info.bootedAtUtc).font(.caption).foregroundColor(.secondary)
            Button("Select Exec") { onExecSelect() }
            Button("Terminal") { onTerminal() }
            Button("Stop") { onStop() }
            Button("Rm") { onRm() }.foregroundColor(.red)
        }
    }
}
