import SwiftUI
import AppKit

/// M13c：Workspace sync + Broker allowlist + 密钥/签名面版。
private struct BrokerPolicyConfig: Codable {
    let allowHosts: [String]?
    let maxResponseBytes: Int?
}
struct SettingsPanel: View {
    let client: DaemonSocketClient
    @State private var workspacePath: String = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("workspace").path
    }()
    @State private var syncSandboxId: String = ""
    @State private var syncResult: String = ""
    @State private var policyPath: String = {
        let cwd = FileManager.default.currentDirectoryPath
        return "\(cwd)/guest/broker-policy.json"
    }()
    @State private var policyStatus: String = ""
    @State private var policyHosts: [String] = []
    @State private var policyMaxBytes: String = "1048576"
    @State private var keyStatus: String = ""
    @State private var showLog: String = "…"
    let log: LogStore
    @State private var showLogText: String = "…"

    var body: some View {
        TabView {
            SettingsWorkspaceTab(path: $workspacePath, sandboxId: $syncSandboxId,
                                 status: $syncResult, client: client)
                .tabItem { Label("Workspace", systemImage: "folder") }
            WorkspaceDropView(client: client)
                .tabItem { Label("Drag & Drop", systemImage: "folder.fill.badge.plus") }
            LoginItemToggle()
                .tabItem { Label("Login Item", systemImage: "power.circle") }
            SettingsPolicyTab(policyPath: $policyPath, hosts: $policyHosts,
                              maxBytes: $policyMaxBytes, status: $policyStatus)
                .tabItem { Label("Broker Policy", systemImage: "network") }
            SettingsKeysTab(path: $policyPath, initialStatus: $keyStatus, log: showLog)
                .tabItem { Label("Keys & Release", systemImage: "key") }
            SettingsAboutTab(client: client)
                .tabItem { Label("About", systemImage: "info.circle") }
            Text(showLog)
                .font(.system(.caption2, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .tabItem { Label("Debug", systemImage: "ladybug") }
        }
        .frame(minWidth: 680, minHeight: 420)
        .onAppear {
            if policyHosts.isEmpty { reloadPolicy() }
        }
    }

    private func reloadPolicy() {
        guard FileManager.default.fileExists(atPath: policyPath) else {
            policyStatus = "no policy file at \(policyPath)"
            return
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: policyPath))
            let pol = try JSONDecoder().decode(BrokerPolicyConfig.self, from: data)
            policyHosts = pol.allowHosts ?? []
            policyMaxBytes = String(pol.maxResponseBytes ?? 1_048_576)
            policyStatus = "loaded \(policyHosts.count) hosts"
        } catch { policyStatus = "load fail: \(error.localizedDescription)" }
    }
}

struct SettingsWorkspaceTab: View {
    @Binding var path: String
    @Binding var sandboxId: String
    @Binding var status: String
    let client: DaemonSocketClient

    var body: some View {
        Form {
            LabeledContent("Workspace Path") {
                HStack {
                    TextField("", text: $path).textFieldStyle(.roundedBorder)
                    Button("Pick…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let u = panel.url { path = u.path }
                    }
                }
            }
            LabeledContent("Target Sandbox") {
                TextField("sandbox id", text: $sandboxId).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Sync to /workspace") {
                    var req = DaemonRequest(kind: "wsSync")
                    req.sandboxId = sandboxId
                    req.workspaceDir = path
                    do {
                        let resp = try client.send(req)
                        status = resp.stdout ?? "ok"
                    } catch { status = "sync fail: \(error.localizedDescription)" }
                }
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundColor(.secondary) }
        }
        .padding()
    }
}

struct SettingsPolicyTab: View {
    @Binding var policyPath: String
    @Binding var hosts: [String]
    @Binding var maxBytes: String
    @Binding var status: String
    @State private var newHost: String = ""

    var body: some View {
        Form {
            LabeledContent("Policy File") {
                Text(policyPath).font(.caption).foregroundColor(.secondary)
            }
            LabeledContent("Max Response Bytes") {
                TextField("", text: $maxBytes).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            Section("Allow Hosts") {
                ForEach(hosts, id: \.self) { host in
                    HStack { Text(host); Spacer(); Button("Remove") { hosts.removeAll { $0 == host } } }
                }
                HStack {
                    TextField("add host (e.g. api.example.com)", text: $newHost).textFieldStyle(.roundedBorder)
                    Button("Add") { guardsHostAndSave() }
                }
            }
            HStack {
                Spacer(); Button("Save Policy") { guardsHostAndSave() }
            }
            if !status.isEmpty { Text(status).font(.caption) }
        }
        .padding()
    }

    private func guardsHostAndSave() {
        if !newHost.isEmpty { hosts.append(newHost); newHost = "" }
        let payload: [String: Any] = [
            "allowHosts": hosts,
            "scheme": "https",
            "maxResponseBytes": Int(maxBytes) ?? 1_048_576
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: policyPath))
            status = "saved \(hosts.count) hosts"
        } catch { status = "save fail: \(error.localizedDescription)" }
    }
}

struct SettingsKeysTab: View {
    @Binding var path: String
    @State var status: String = ""
    @State var logText: String = ""
    let log: String

    init(path: Binding<String>, initialStatus: Binding<String>, log: String) {
        _path = path
        self._status = State(initialValue: initialStatus.wrappedValue)
        self.log = log
    }

    var manifestPath: String { path.replacingOccurrences(of: "broker-policy.json", with: "manifest.json") }
    var signKeyPath: String { path.replacingOccurrences(of: "broker-policy.json", with: "dev-sign-key.local") }
    var dbxPath: String { FileManager.default.currentDirectoryPath + "/.build/release/dbx-poc" }

    var body: some View {
        Form {
            LabeledContent("manifest.json") { Text(manifestPath).font(.caption) }
            LabeledContent("sign key") { Text(signKeyPath).font(.caption) }
            HStack(spacing: 12) {
                Button("gen-guest-sign-key") { runCli(["gen-guest-sign-key", "--output-key", signKeyPath]) }
                Button("sign-manifest") { runCli(["sign-manifest", "--manifest", manifestPath + ".unsigned", "--key", signKeyPath, "--output", manifestPath]) }
                Button("validate-assets") { runCli(["validate-assets", manifestPath]) }
            }
            if !status.isEmpty { Text(status).font(.caption) }
            Divider()
            Text(logText).font(.system(.caption2, design: .monospaced))
        }
        .padding()
    }

    private func runCli(_ args: [String]) {
        let tool = dbxPath   // MainActor 隔离属性不能进 Sendable 闭包，先取局部值
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            status = "dbx-poc not found; build+sign first"; return
        }
        DispatchQueue.global().async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run(); } catch {
                let message = error.localizedDescription
                Task { @MainActor in status = "run fail: \(message)" }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            let code = process.terminationStatus
            let name = args.first ?? ""
            Task { @MainActor in
                logText = text
                status = code == 0 ? "ok: \(name)" : "fail: exit=\(code)"
            }
            process.waitUntilExit()
        }
    }
}

/// M22：关于面板 —— 版本信息 + 更新检查。
///
/// 只做「检查 + 告知」，不下载不替换（自动更新属 M22c）。
struct SettingsAboutTab: View {
    let client: DaemonSocketClient
    @State private var versionText: String = "…"
    @State private var updateText: String = ""
    @State private var checking = false
    @State private var revealLog = false

    private var dbxPath: String {
        BundlePaths.dbxPOC() ?? FileManager.default.currentDirectoryPath + "/.build/release/dbx-poc"
    }
    private var channelPath: String {
        BundlePaths.defaultChannelPath
            ?? FileManager.default.currentDirectoryPath + "/guest/channel.json"
    }

    var body: some View {
        Form {
            LabeledContent("Desk Box", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? versionText)
            LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
            LabeledContent("Git commit", value: Bundle.main.infoDictionary?["DeskBoxGitCommit"] as? String ?? "—")
            LabeledContent("Release channel", value: Bundle.main.infoDictionary?["DeskBoxReleaseChannel"] as? String ?? "—")
            LabeledContent("Guest asset version", value: String(describing: Bundle.main.infoDictionary?["DeskBoxGuestAssetVersion"] as? Int ?? 0))
            Divider()
            HStack(spacing: 12) {
                Button(checking ? "Checking…" : "Check for Updates") { checkUpdate() }
                    .disabled(checking)
                if revealLog { Button("Reveal helper log") { reveal() } }
            }
            if !updateText.isEmpty {
                Text(updateText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Divider()
            Text("更新检查只做验证与告知：channel.json 用 Ed25519 release key 签名，版本回滚一律拒绝。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { versionText = readHelperVersion() }
    }

    private func checkUpdate() {
        checking = true
        updateText = ""
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let tool = dbxPath   // MainActor 隔离属性不能进 Sendable 闭包
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            checking = false
            updateText = "dbx-poc helper 未找到（\(tool)）"
            return
        }
        guard FileManager.default.isReadableFile(atPath: channelPath) else {
            checking = false
            updateText = "channel.json 未找到（\(channelPath)）"
            return
        }
        let channel = channelPath
        DispatchQueue.global().async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["check-update", "--channel", channel,
                                 "--current-version", current, "--json"]
            process.standardOutput = pipe
            process.standardError = pipe
            var text: String
            var exitCode: Int32 = -1
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                exitCode = process.terminationStatus
                text = String(decoding: data, as: UTF8.self)
            } catch {
                text = "run fail: \(error.localizedDescription)"
            }
            if let data = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let decision = obj["decision"] as? String {
                switch decision {
                case "available":
                    text = "有可用更新：\(obj["currentVersion"] ?? "?") → \(obj["remoteVersion"] ?? "?")\n"
                        + "release=\(obj["releaseTag"] ?? "?")"
                case "up-to-date":
                    text = "已是最新版本（\(obj["currentVersion"] ?? "?")）"
                default:
                    text = "已拒绝：\(obj["reason"] ?? decision)"
                }
            }
            if exitCode != 0 && exitCode != 3 { text += "\nexit=\(exitCode)" }
            Task { @MainActor in
                updateText = text
                checking = false
            }
        }
    }

    private func readHelperVersion() -> String {
        guard FileManager.default.isExecutableFile(atPath: dbxPath) else { return "—" }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: dbxPath)
        process.arguments = ["version"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let v = obj["version"] as? String {
                return "\(v) (helper)"
            }
        } catch {}
        return "—"
    }

    private func reveal() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let log = home.appendingPathComponent("Library/Logs/DeskBox/daemon.log")
        NSWorkspace.shared.activateFileViewerSelecting([log])
    }
}
