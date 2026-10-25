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
            SettingsPolicyTab(policyPath: $policyPath, hosts: $policyHosts,
                              maxBytes: $policyMaxBytes, status: $policyStatus)
                .tabItem { Label("Broker Policy", systemImage: "network") }
            SettingsKeysTab(path: $policyPath, initialStatus: $keyStatus, log: showLog)
                .tabItem { Label("Keys & Release", systemImage: "key") }
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
        guard FileManager.default.isExecutableFile(atPath: dbxPath) else {
            status = "dbx-poc not found; build+sign first"; return
        }
        DispatchQueue.global().async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: dbxPath)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run(); } catch {
                DispatchQueue.main.async { status = "run fail: \(error.localizedDescription)" }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                logText = text
                status = process.terminationStatus == 0 ? "ok: \(args.first ?? "")" : "fail: exit=\(process.terminationStatus)"
            }
            process.waitUntilExit()
        }
    }
}
