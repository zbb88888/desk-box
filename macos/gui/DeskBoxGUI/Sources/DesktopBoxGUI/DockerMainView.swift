import SwiftUI

/// M16：Docker Desktop 型主界面：sidebar + 表格 + 动作面板。
struct DockerMainView: View {
    @ObservedObject var daemonManager: DaemonProcessManager
    @ObservedObject var viewModel: SandboxViewModel
    @StateObject private var displayModel = DisplaySandboxViewModel()

    @State private var selection: String? = "sandboxes"
    @AppStorage("manifestPath") private var manifestPath: String = ""
    @AppStorage("dbxPath") private var dbxPathOverride: String = ""
    @AppStorage("autostartDaemon") private var autostartDaemon: Bool = true

    /// M17 hotfix：宿主可定制的 dbx-poc 解析。 order:
    /// 1. 偏好 dbxPath 覆盖；2. 相对 app bundle (gui/dist/DeskBox.app → macos/.build/release/dbx-poc)；3. cwd/.build/release/dbx-poc
    private func resolvedDbxPath() -> String {
        if !dbxPathOverride.isEmpty { return dbxPathOverride }
        let bundleRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()  // dist/
            .deletingLastPathComponent()  // gui/
            .deletingLastPathComponent()  // macos/
        let viaBundle = bundleRoot.path + "/.build/release/dbx-poc"
        if FileManager.default.isExecutableFile(atPath: viaBundle) { return viaBundle }
        return FileManager.default.currentDirectoryPath + "/.build/release/dbx-poc"
    }

    private func resolvedManifestPath() -> String {
        if !manifestPath.isEmpty { return manifestPath }
        let bundleRoot = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let viaBundle = bundleRoot.path + "/guest/manifest.json"
        if FileManager.default.fileExists(atPath: viaBundle) { return viaBundle }
        return FileManager.default.currentDirectoryPath + "/guest/manifest.json"
    }
    @State private var terminalSandboxId: String?
    @State private var consoleSandboxId: String?
    @State private var execSandboxId = ""
    @State private var execCommand = ""
    @State private var execOutput = ""
    @State private var settingsPresented = false
    @State private var displayPresented = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Sandboxes", systemImage: "shippingbox").tag("sandboxes")
                Label("Manifests", systemImage: "square.stack.3d.up").tag("manifests")
                Label("Settings", systemImage: "gear").tag("settings")
            }
            .navigationTitle("Desk Box")
        } detail: {
            switch selection ?? "sandboxes" {
            case "sandboxes":
                sandboxesPanel
            case "manifests":
                ManifestsPanel(manifestDir: manifestDir, isDaemonOn: daemonManager.status == .connected,
                               onRun: { path in run(manifestPath: path) })
            default:
                SettingsPanel(client: viewModel.client, log: LogStore.shared)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .onAppear {
            if manifestPath.isEmpty {
                manifestPath = resolvedManifestPath()
            }
            daemonManager.refresh()
            viewModel.refresh()
            if autostartDaemon && daemonManager.status != .connected {
                startDaemon()
            }
        }
        .onReceive(Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()) { _ in
            daemonManager.noteDiedIfNeeded()
            daemonManager.refresh()
            if daemonManager.status == .connected { viewModel.refresh() }
            else if autostartDaemon { startDaemon() }
        }
        .sheet(isPresented: Binding(get: { terminalSandboxId != nil },
                                    set: { if !$0 { terminalSandboxId = nil } })) {
            if let sid = terminalSandboxId {
                TerminalView(sandboxId: sid, client: viewModel.client)
                    .frame(minWidth: 640, minHeight: 420)
            }
        }
        .sheet(isPresented: Binding(get: { consoleSandboxId != nil },
                                    set: { if !$0 { consoleSandboxId = nil } })) {
            if let sid = consoleSandboxId {
                ConsoleLogView(sandboxId: sid, client: viewModel.client)
                    .frame(minWidth: 640, minHeight: 420)
            }
        }
        .sheet(isPresented: $displayPresented) {
            DisplaySessionView(model: displayModel)
                .frame(minWidth: 800, minHeight: 560)
        }
    }

    private var manifestDir: URL {
        let url = URL(fileURLWithPath: manifestPath).standardizedFileURL
        return url.deletingLastPathComponent()
    }

    private var sandboxesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Sandboxes", systemImage: "shippingbox").font(.title3)
                Spacer()
                Text(daemonManager.status == .connected ? "daemon ● connected" : "daemon ● stopped")
                    .font(.caption)
                    .foregroundColor(daemonManager.status == .connected ? .green : .orange)
                Text("running: \(viewModel.sandboxes.filter { $0.state == "running" }.count) / total \(viewModel.sandboxes.count)")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Start Daemon") { startDaemon() }.disabled(daemonManager.status == .connected)
                Button("Refresh") { viewModel.refresh() }.disabled(daemonManager.status != .connected)
                Button("Run New Sandbox") {
                    run(manifestPath: manifestPath)
                }
                .disabled(daemonManager.status != .connected)
                Button("Shutdown Daemon") { daemonManager.stopDaemon(); viewModel.refresh() }
                    .disabled(daemonManager.status != .connected)
                Button("Settings") { settingsPresented = true }
                Button("Open Display") {
                    openDisplay()
                    displayPresented = true
                }
                TextField("manifest", text: $manifestPath)
                    .textFieldStyle(.roundedBorder).frame(minWidth: 260)
            }
            .padding(.horizontal)
            .sheet(isPresented: $settingsPresented) {
                SettingsPanel(client: viewModel.client, log: LogStore.shared)
            }

            Table(viewModel.sandboxes) {
                TableColumn("Sandbox Id") { sb in Text(sb.sandboxId).font(.system(.body, design: .monospaced)) }
                    .width(min: 170)
                TableColumn("State") { sb in
                    HStack {
                        Circle().fill(sb.state == "running" ? Color.green : Color.orange).frame(width: 8, height: 8)
                        Text(sb.state)
                    }
                }
                .width(70)
                TableColumn("Uptime") { sb in
                    Text(uptimeString(sb.uptimeSeconds)).font(.system(.caption, design: .monospaced))
                }
                .width(80)
                TableColumn("Manifest") { sb in
                    Text(URL(fileURLWithPath: sb.manifestPath).lastPathComponent).font(.caption)
                }
                .width(min: 160)
                TableColumn("Actions") { sb in
                    HStack(spacing: 8) {
                        Button("Terminal") { terminalSandboxId = sb.sandboxId }
                        Button("Console") { consoleSandboxId = sb.sandboxId }
                        Button("Exec") { execSandboxId = sb.sandboxId }
                        Button("Restart") { restart(sb.sandboxId) }
                        Button("Stop") { stop(sb.sandboxId) }
                        Button("Rm") { rm(sb.sandboxId) }.foregroundColor(.red)
                    }
                }
            }
            .frame(minHeight: 240)

            Divider()
            HStack {
                TextField("sandbox id", text: $execSandboxId)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
                TextField("commandline, e.g. /bin/echo hello", text: $execCommand)
                    .textFieldStyle(.roundedBorder)
                Button("Exec") { exec() }.disabled(execSandboxId.isEmpty || execCommand.isEmpty)
            }
            .padding(.horizontal)
            if !execOutput.isEmpty {
                ScrollView {
                    Text(execOutput).font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(maxHeight: 120)
                .background(Color(NSColor.textBackgroundColor)).cornerRadius(4)
                .padding(.horizontal)
            }

            Text("Logs")
                .font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            DaemonLogView()
                .frame(maxHeight: 140)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .padding(.top, 8)
    }

    private func uptimeString(_ seconds: Int?) -> String {
        guard let s = seconds else { return "-" }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%dh%02dm", h, m) : String(format: "%dm%02ds", m, sec)
    }

    private func startDaemon() {
        let url = URL(fileURLWithPath: resolvedDbxPath()).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            LogStore.shared.append("dbx-poc not found at \(url.path). Build & sign first.")
            return
        }
        do { try daemonManager.startDaemon(dbxBinaryPath: url, sockPath: nil) }
        catch { LogStore.shared.append("startDaemon: \(error.localizedDescription)") }
    }

    private func run(manifestPath: String) {
        var req = DaemonRequest(kind: "run")
        req.manifestPath = manifestPath
        send(req, toast: "run started")
    }

    private func stop(_ id: String) {
        var req = DaemonRequest(kind: "stop"); req.sandboxId = id
        send(req, toast: "stopped \(id)")
    }

    private func rm(_ id: String) {
        var req = DaemonRequest(kind: "rm"); req.sandboxId = id; req.force = true
        send(req, toast: "removed \(id)")
    }

    private func restart(_ id: String) {
        var req = DaemonRequest(kind: "restart"); req.sandboxId = id
        send(req, toast: "restart ack")
    }

    private func exec() {
        var req = DaemonRequest(kind: "exec")
        req.sandboxId = execSandboxId
        req.argv = execCommand.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !(req.argv?.isEmpty ?? true) else { execOutput = "argv empty"; return }
        do {
            let resp = try viewModel.client.send(req)
            execOutput = "exit=\(resp.exitCode ?? 0)\n---stdout---\n\(resp.stdout ?? "")\n---stderr---\n\(resp.stderr ?? "")"
        } catch {
            execOutput = "daemon: \(error.localizedDescription)"
            daemonManager.status = .stopped
        }
    }

    private func openDisplay() {
        let kernel = manifestPath.replacingOccurrences(of: "manifest.json", with: "vmlinuz-virt-gpu")
        let initrd = manifestPath.replacingOccurrences(of: "manifest.json", with: "initrd-deskbox.img")
        let root = manifestPath.replacingOccurrences(of: "manifest.json", with: "root-disk.raw")
        displayModel.start(kernelPath: URL(fileURLWithPath: kernel),
                           initrdPath: URL(fileURLWithPath: initrd),
                           rootDiskPath: URL(fileURLWithPath: root),
                           cpu: 2, memMiB: 2048)
    }

    private func send(_ req: DaemonRequest, toast: String) {
        do {
            let resp = try viewModel.client.send(req)
            if let newId = resp.sandboxId { LogStore.shared.append("\(req.kind): \(toast) -> \(newId)") }
            else { LogStore.shared.append("\(req.kind): \(toast)") }
            viewModel.refresh()
        } catch {
            LogStore.shared.append("\(req.kind) fail: \(error.localizedDescription)")
            execOutput = "daemon: \(error.localizedDescription)"
            // M17 hotfix：发送失败也应立即表状态而不是仍是 connected
            daemonManager.status = .stopped
        }
    }
}

/// M16：manifests 面板（\u5bf9\u5e94 Docker Images）。
struct ManifestsPanel: View {
    let manifestDir: URL
    let isDaemonOn: Bool
    let onRun: (String) -> Void
    @State private var manifests: [ManifestRow] = []

    struct ManifestRow: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let sizeKB: Int
        let digestShort: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Manifests", systemImage: "square.stack.3d.up").font(.title3)
                Spacer()
                Text(manifestDir.path).font(.caption).foregroundColor(.secondary)
                Button("Rescan") { rescan() }
            }
            .padding(.horizontal)
            Table(manifests) {
                TableColumn("Name") { m in Text(m.name) }.width(min: 220)
                TableColumn("SizeKB") { m in Text("\(m.sizeKB)") }.width(70)
                TableColumn("Digest") { m in Text(m.digestShort).font(.system(.caption, design: .monospaced)) }.width(min: 140)
                TableColumn("Run") { m in
                    Button("Run") { onRun(m.path) }.disabled(!isDaemonOn)
                }.width(60)
            }
            .frame(minHeight: 240)
        }
        .padding(.top, 8)
        .onAppear { rescan() }
    }

    private func rescan() {
        var rows: [ManifestRow] = []
        if let items = try? FileManager.default.contentsOfDirectory(atPath: manifestDir.path) {
            for name in items where name.hasPrefix("manifest") && name.hasSuffix(".json") && !name.contains("unsigned") {
                let path = manifestDir.appendingPathComponent(name).path
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                var digest = "-"
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sig = obj["signature"] as? [String: Any],
                   let payload = sig["payloadDigest"] as? String ?? sig["payloadSha256"] as? String {
                    digest = String(payload.prefix(16))
                }
                rows.append(ManifestRow(name: name, path: path, sizeKB: size / 1024, digestShort: digest))
            }
        }
        manifests = rows.sorted { $0.name < $1.name }
    }
}

/// M16：Console log viewer（serial 尾部）。
struct ConsoleLogView: View {
    let sandboxId: String
    let client: DaemonSocketClient
    @State private var text = "…"
    var body: some View {
        VStack {
            Text("Console – \(sandboxId)").font(.headline).padding(.top, 8)
            ScrollViewReader { _ in
                ScrollView {
                    Text(text).font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            HStack { Spacer(); Button("Refresh") { load() } }
                .padding(8)
        }
        .onAppear { load() }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in load() }
    }
    private func load() {
        let client = self.client
        DispatchQueue.global().async {
            var req = DaemonRequest(kind: "consoleLog")
            req.sandboxId = self.sandboxId
            req.waitMillis = 16384
            if let resp = try? client.send(req, timeoutSec: 5), let hex = resp.outputHex {
                var bytes = Data()
                var i = hex.startIndex
                while i < hex.endIndex {
                    bytes.append(UInt8(hex[i..<hex.index(i, offsetBy: 2)], radix: 16) ?? 0)
                    i = hex.index(i, offsetBy: 2)
                }
                let t = String(data: bytes, encoding: .utf8) ?? "<binary \(bytes.count)B>"
                DispatchQueue.main.async { self.text = t.isEmpty ? "<no console output>" : t }
            }
        }
    }
}

struct DaemonLogView: View {
    @ObservedObject var logStore = LogStore.shared
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(logStore.lines.indices, id: \.self) { i in
                        Text(logStore.lines[i]).font(.system(.caption2, design: .monospaced)).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .background(Color(NSColor.textBackgroundColor)).cornerRadius(4)
            .onChange(of: logStore.lines.count) { _ in
                if let last = logStore.lines.indices.last { proxy.scrollTo(last) }
            }
        }
    }
}
