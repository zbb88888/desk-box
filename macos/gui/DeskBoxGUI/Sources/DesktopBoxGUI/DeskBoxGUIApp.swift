import SwiftUI
import UniformTypeIdentifiers

/// M22+ hotfix：显式 AppDelegate，保证 terminate 永不被挂起（即便 display VM 在跑）。
final class DeskBoxAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // M30：仅当设置了 DBX_GUI_SELFTEST 时启用（见 GUISelfTest）。
        GUISelfTest.shared?.start()
        // M31：Dock 菜单的 Quit、注销/关机、`NSRunningApplication.terminate()` 发来的都是 quit AppleEvent，
        // 默认处理是 `NSApp.terminate`——有 sheet 时同样无效（并且会卡住系统注销）。改由 AppQuit 处理。
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuitAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc func handleQuitAppleEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        // AppleEvent 处理器在主线程上被调用。
        MainActor.assumeIsolated { AppQuit.quit() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        GUISelfTest.shared?.noteTerminating(path: .terminate)
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
            // M31：Quit 必须经 AppQuit（先收起 sheet 再 terminate）。系统默认的 `terminate:` 菜单项在
            // 窗口挂着 sheet 时是个空操作——见 AppQuit 的说明。由 scripts/e2e-gui-app.sh 的 G2/G7/G8 守住。
            CommandGroup(replacing: .appTermination) {
                Button("Quit Desk Box") { AppQuit.quit() }
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
    /// M41：正在执行 exec 的沙箱（nil = 没有在途的 exec）；Cancel 按钮据此启用。
    @Published var execRunningSandboxId: String?
    /// M41：最近一次取消请求的结果说明。
    @Published var execCancelNote: String = ""

    let client: DaemonSocketClient

    init(client: DaemonSocketClient = DaemonSocketClient(sockPath: DaemonSocketClient.defaultSockPath())) {
        self.client = client
    }

    func refresh(completion: (@MainActor @Sendable () -> Void)? = nil) {
        self.busy = true
        let client = self.client
        DispatchQueue.global().async {
            do {
                let response = try client.send(DaemonRequest(kind: "ps"))
                DispatchQueue.main.async {
                    self.sandboxes = response.sandboxes ?? []
                    self.busy = false
                    self.errorText = nil
                    MainActor.assumeIsolated { completion?() }
                }
            } catch {
                let line = DaemonErrorPresenter.present(error).logLine
                DispatchQueue.main.async {
                    self.sandboxes = []
                    self.busy = false
                    self.errorText = line
                    MainActor.assumeIsolated { completion?() }
                }
            }
        }
    }

    // MARK: - M32：操作逻辑（此前散落在 DockerMainView 的私有方法里，无法测试也无法被自检驱动）

    /// 「Run New Sandbox」对应的请求。
    static func runRequest(manifestPath: String) -> DaemonRequest {
        var request = DaemonRequest(kind: "run")
        request.manifestPath = manifestPath
        return request
    }

    /// 各类请求的客户端读超时（秒）。
    /// `run` / `resume` / `restart` 要等 guest 引导（daemon 侧上限 90s）；此前一律 30s，
    /// 引导稍慢时界面先超时、报「没有有效响应」，而 daemon 其实随后成功了。
    static func timeoutSeconds(forKind kind: String) -> Int {
        switch kind {
        case "run", "resume", "restart": return 150
        case "exec", "wsSync": return 120
        default: return 30
        }
    }

    /// 提交一个会改变状态的请求（run / suspend / resume / restart / stop / rm）。
    /// 网络 I/O 在后台线程；结果在主线程回写（日志、输出区、列表刷新），然后调用 completion。
    /// - Parameter daemonManager: 只有「连不上」才把它标记为 stopped（被拒绝说明 daemon 活着）。
    func submit(_ request: DaemonRequest, label: String, daemonManager: DaemonProcessManager?,
                completion: (@MainActor @Sendable (Result<DaemonResponse, Error>) -> Void)? = nil) {
        let client = self.client
        let kind = request.kind
        let timeout = Self.timeoutSeconds(forKind: kind)
        DispatchQueue.global().async {
            let result: Result<DaemonResponse, Error>
            do { result = .success(try client.send(request, timeoutSec: timeout)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let response):
                        if let newId = response.sandboxId { LogStore.shared.append("\(kind): \(label) -> \(newId)") }
                        else { LogStore.shared.append("\(kind): \(label)") }
                    case .failure(let error):
                        let shown = DaemonErrorPresenter.present(error)
                        LogStore.shared.append("\(kind) \(shown.severity.rawValue): \(shown.logLine)")
                        self.execOutput = "\(shown.logLine)\n\(shown.detail)"
                        if (error as? DaemonClientError)?.indicatesDaemonUnreachable ?? false {
                            daemonManager?.status = .stopped
                        }
                    }
                    self.refresh { completion?(result) }
                }
            }
        }
    }

    /// 「Exec」：把输入框里的一行命令分词后执行，结果写入 `execOutput`。
    func exec(sandboxId: String, commandLine: String, daemonManager: DaemonProcessManager?,
              completion: (@MainActor @Sendable (Result<DaemonResponse, Error>) -> Void)? = nil) {
        let argv: [String]
        do { argv = try ExecCommandLine.argv(from: commandLine) }
        catch {
            execOutput = "命令行无法解析：\(error.localizedDescription)"
            MainActor.assumeIsolated { completion?(.failure(error)) }
            return
        }
        guard !argv.isEmpty else {
            execOutput = "argv empty"
            MainActor.assumeIsolated { completion?(.failure(DaemonClientError.weird("argv empty"))) }
            return
        }
        var building = DaemonRequest(kind: "exec")
        building.sandboxId = sandboxId
        building.argv = argv
        let request = building
        let client = self.client
        let timeout = Self.timeoutSeconds(forKind: "exec")
        execOutput = "running…"
        execRunningSandboxId = sandboxId
        execCancelNote = ""
        DispatchQueue.global().async {
            let result: Result<DaemonResponse, Error>
            do { result = .success(try client.send(request, timeoutSec: timeout)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.execRunningSandboxId = nil
                    switch result {
                    case .success(let resp):
                        self.execOutput = ExecOutputText.render(exitCode: resp.exitCode, stdout: resp.stdout,
                                                                stderr: resp.stderr, notices: resp.notices)
                    case .failure(let error):
                        let shown = DaemonErrorPresenter.present(error)
                        self.execOutput = "\(shown.logLine)\n\(shown.detail)"
                        if (error as? DaemonClientError)?.indicatesDaemonUnreachable ?? false {
                            daemonManager?.status = .stopped
                        }
                    }
                    completion?(result)
                }
            }
        }
    }

    /// M41：「Cancel」——取消正在运行的那条命令。结果写入 `execCancelNote`
    ///（成功时命令本身的结果会照常出现在 `execOutput` 里，带着取消之前的输出）。
    func cancelExec(completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard let sandboxId = execRunningSandboxId else {
            execCancelNote = "没有正在运行的命令"
            MainActor.assumeIsolated { completion?(false) }
            return
        }
        var building = DaemonRequest(kind: "execCancel")
        building.sandboxId = sandboxId
        let request = building
        let client = self.client
        execCancelNote = "正在取消…"
        DispatchQueue.global().async {
            let result: Result<DaemonResponse, Error>
            do { result = .success(try client.send(request, timeoutSec: 15)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let resp):
                        self.execCancelNote = resp.stdout ?? "exec cancelled"
                        completion?(true)
                    case .failure(let error):
                        let shown = DaemonErrorPresenter.present(error)
                        self.execCancelNote = "\(shown.logLine)\n\(shown.detail)"
                        completion?(false)
                    }
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
            Button("Quit") { AppQuit.quit() }
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
