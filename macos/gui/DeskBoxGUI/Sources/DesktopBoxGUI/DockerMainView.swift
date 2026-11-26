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
        BundlePaths.dbxPOC(override: dbxPathOverride)
            ?? FileManager.default.currentDirectoryPath + "/.build/release/dbx-poc"
    }

    private func resolvedManifestPath() -> String {
        if !manifestPath.isEmpty { return manifestPath }
        return BundlePaths.defaultManifestPath
    }
    @State private var terminalSandboxId: String?
    @State private var consoleSandboxId: String?
    @State private var execSandboxId = ""
    @State private var execCommand = ""
    @State private var settingsPresented = false
    @State private var displayPresented = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Sandboxes", systemImage: "shippingbox").tag("sandboxes")
                Label("Manifests", systemImage: "square.stack.3d.up").tag("manifests")
                Label("Stats", systemImage: "chart.bar").tag("stats")
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
            case "stats":
                StatsPanel(client: viewModel.client, viewModel: viewModel)
            default:
                SettingsPanel(client: viewModel.client, log: LogStore.shared)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        // M53：不可撤销的操作先确认。
        .alert(viewModel.pendingConfirmation?.title ?? "",
               isPresented: Binding(get: { viewModel.pendingConfirmation != nil },
                                    set: { if !$0 { viewModel.cancelPending() } }),
               presenting: viewModel.pendingConfirmation) { prompt in
            Button(prompt.confirmLabel, role: .destructive) { viewModel.confirmPending(daemonManager: daemonManager) }
            Button("取消", role: .cancel) { viewModel.cancelPending() }
        } message: { prompt in
            Text(prompt.message)
        }
        .onAppear {
            if manifestPath.isEmpty {
                manifestPath = resolvedManifestPath()
            }
            GUISelfTest.shared?.attach(viewModel: viewModel, daemonManager: daemonManager)
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
        // M31：退出前由 AppQuit 请求收起所有 sheet（有 sheet 时 AppKit 拒绝终止）。
        .onReceive(NotificationCenter.default.publisher(for: AppQuit.dismissSheetsRequest)) { _ in
            terminalSandboxId = nil
            consoleSandboxId = nil
            displayPresented = false
            settingsPresented = false
        }
        // M31：自检场景请求打开 Settings sheet（与点击「Settings」等价）。仅自检模式下会收到。
        .onReceive(NotificationCenter.default.publisher(for: GUISelfTest.openSettingsRequest)) { _ in
            selection = "sandboxes"
            settingsPresented = true
        }
        // M31：自检场景请求打开 Display（与点击「Open Display」走同一段代码）。仅自检模式下会收到。
        .onReceive(NotificationCenter.default.publisher(for: GUISelfTest.openDisplayRequest)) { _ in
            openDisplay()
            displayPresented = true
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
            // M51：daemon 比这个 App 旧（或新）时，在最上面说出来。
            if let skew = viewModel.daemonSkewNote {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(skew).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12)).cornerRadius(6)
                .padding(.horizontal)
            }
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
                Button("Shutdown Daemon") { viewModel.requestShutdown(daemonManager: daemonManager) }
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
                        Circle().fill(sb.state == "running" ? Color.green : (sb.state == "failed" ? Color.red : Color.orange))
                            .frame(width: 8, height: 8)
                        Text(sb.state)
                    }
                    // M45：failed 的原因与出路，悬停可见。
                    .help(SandboxRowActions.stateNote(state: sb.state, detail: sb.stateDetail) ?? sb.state)
                }
                .width(70)
                TableColumn("Uptime") { sb in
                    Text(uptimeString(sb.uptimeSeconds)).font(.system(.caption, design: .monospaced))
                }
                .width(80)
                TableColumn("Domain") { sb in
                    Text(sb.domain ?? "—")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(90)
                TableColumn("Manifest") { sb in
                    Text(URL(fileURLWithPath: sb.manifestPath).lastPathComponent).font(.caption)
                }
                .width(min: 160)
                TableColumn("Actions") { sb in
                    // M30：按生命周期状态启用（SandboxRowActions）；新增 Suspend / Resume。
                    HStack(spacing: 8) {
                        ForEach(SandboxRowActions.available(forState: sb.state)) { action in
                            Button(action.label) { perform(action, on: sb.sandboxId) }
                                .foregroundColor(action.isDestructive ? .red : nil)
                                // M53：Rm 与其它按钮隔开一点，少一些点错的机会。
                                .padding(.leading, action.isDestructive ? 10 : 0)
                        }
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
                Button("Exec") { exec() }
                    .disabled(execSandboxId.isEmpty || execCommand.isEmpty || viewModel.execRunningSandboxId != nil)
                Button("Cancel") { viewModel.cancelExec() }
                    .disabled(viewModel.execRunningSandboxId == nil)
                    .help("取消正在运行的命令（需要较新的 guest 资产）")
            }
            .padding(.horizontal)
            if !viewModel.execCancelNote.isEmpty {
                Text(viewModel.execCancelNote).font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            }
            if !viewModel.execOutput.isEmpty {
                ScrollView {
                    Text(viewModel.execOutput).font(.system(.caption, design: .monospaced))
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
        send(SandboxViewModel.runRequest(manifestPath: manifestPath), toast: "run started")
    }

    /// M30：行内操作统一入口。界面动作在此处理，其余转成 daemon 请求。
    private func perform(_ action: SandboxAction, on id: String) {
        switch action {
        case .terminal: terminalSandboxId = id
        case .console: consoleSandboxId = id
        case .exec: execSandboxId = id
        default:
            // M53：Rm / Restart / Stop 先确认（viewModel.request 只登记，由上面的 alert 执行）。
            viewModel.request(action, sandboxId: id, daemonManager: daemonManager)
        }
    }

    private func exec() {
        // M32：分词（支持引号）与执行都在视图模型里。
        viewModel.exec(sandboxId: execSandboxId, commandLine: execCommand, daemonManager: daemonManager)
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
        // M32：逻辑在 SandboxViewModel.submit（后台线程 I/O、主线程回写）。
        viewModel.submit(req, label: toast, daemonManager: daemonManager)
    }
}

/// M16：manifests 面板（\u5bf9\u5e94 Docker Images）。
struct ManifestsPanel: View {
    let manifestDir: URL
    let isDaemonOn: Bool
    let onRun: (String) -> Void
    @State private var manifests: [ManifestCatalogRow] = []

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
                TableColumn("Name") { m in Text(m.name) }.width(min: 200)
                TableColumn("Kernel") { m in Text(m.kernel ?? "-").font(.caption) }.width(min: 110)
                TableColumn("SizeKB") { m in Text("\(m.sizeBytes / 1024)") }.width(60)
                // M50：签名密钥的 keyID（此前这一列读的是不存在的字段，永远是 "-"）。
                TableColumn("Key") { m in Text(m.signatureText).font(.system(.caption, design: .monospaced)) }.width(min: 130)
                TableColumn("Status") { m in
                    Text(m.statusText).font(.caption)
                        .foregroundColor(m.status == .ready ? .secondary : .orange)
                        .help(m.statusText)
                }.width(min: 120)
                TableColumn("Run") { m in
                    Button("Run") { onRun(m.path) }.disabled(!isDaemonOn || !m.isRunnable)
                }.width(60)
            }
            .frame(minHeight: 240)
        }
        .padding(.top, 8)
        .onAppear { rescan() }
    }

    private func rescan() {
        // M50：逻辑在 ManifestCatalog（可单元测试）。
        manifests = ManifestCatalog.scan(directory: manifestDir)
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
            let shown: String
            do {
                let resp = try client.send(req, timeoutSec: 5)
                // M33：统一的安全解码 + 净化（畸形 hex 不再崩溃；serial 里的转义序列不直接上屏）。
                if let text = ConsoleLog.text(fromHex: resp.outputHex ?? "") {
                    shown = text.isEmpty ? "<no console output>" : text
                } else {
                    shown = "<daemon 返回了无法解码的 console 数据>"
                }
            } catch {
                // 此前失败被静默忽略，面板永远停在「…」或上一次的内容。
                shown = "<\(DaemonErrorPresenter.present(error).logLine)>"
            }
            DispatchQueue.main.async { self.text = shown }
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
