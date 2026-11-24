import AppKit
import DeskBoxVZ
import Foundation
import Virtualization

/// M30：应用内自检（仅当设置了环境变量 `DBX_GUI_SELFTEST=<报告路径>` 时启用）。
///
/// 目的：让「⌘Q 能退出」这类界面行为可以被自动化验证，而不需要辅助功能权限、
/// 也不需要用 System Events 去操作用户的桌面。
///
/// 它做三件事：
/// 1. **主线程卡顿采样**：后台线程每 50ms 往主队列投一个探针，记录「投递 → 执行」的最大延迟。
///    主线程被同步 socket 调用卡住时（最初 ⌘Q 无法退出的根因），这个数会到秒级。
/// 2. **主菜单快照**：递归导出 `NSApp.mainMenu`（标题 / 快捷键 / 修饰键 / action）。
/// 3. **合成 ⌘Q**：`DBX_GUI_SELFTEST_QUIT_AFTER=<秒>` 到点后，构造一个 ⌘Q keyDown 事件交给
///    `NSApp.mainMenu.performKeyEquivalent`——与真实按键在「没有视图截获」时走的是同一条
///    AppKit 路径（菜单项 → action → terminate → applicationShouldTerminate）。
///
/// 不设置环境变量时本文件没有任何效果。它不接受外部输入、不开端口，只写一个报告文件。
final class GUISelfTest: @unchecked Sendable {
    static let shared: GUISelfTest? = {
        guard let path = ProcessInfo.processInfo.environment["DBX_GUI_SELFTEST"], path.hasPrefix("/") else { return nil }
        return GUISelfTest(reportPath: path)
    }()

    private let reportPath: String
    private let lock = NSLock()
    private var maxLagMs: Double = 0
    private var samples = 0
    private var stopSampling = false

    private init(reportPath: String) { self.reportPath = reportPath }

    var terminatedMarkerPath: String { reportPath + ".terminated" }

    /// M31：`DBX_GUI_SELFTEST_SCENARIO=display` 时，自检请求主界面打开 Display。
    static let openDisplayRequest = Notification.Name("deskbox.selftest.open-display")
    /// `DBX_GUI_SELFTEST_SCENARIO=sheet`：打开一个不依赖 VM 的 sheet（Settings）。
    static let openSettingsRequest = Notification.Name("deskbox.selftest.open-settings")
    /// `DBX_GUI_SELFTEST_QUIT_VIA=appleevent`：不发 ⌘Q，而是给自己发 quit AppleEvent
    ///（Dock 的 Quit / 注销 / NSRunningApplication.terminate 走的那条路）。
    private var quitVia: String { ProcessInfo.processInfo.environment["DBX_GUI_SELFTEST_QUIT_VIA"] ?? "cmd-q" }
    private var scenario: String { ProcessInfo.processInfo.environment["DBX_GUI_SELFTEST_SCENARIO"] ?? "" }
    private var displayFacts: [String: Any] = [:]
    private var lateFacts: [String: Any] = [:]

    // M32：`DBX_GUI_SELFTEST_SCENARIO=flow` 用视图模型驱动真实 daemon / VM（与按钮走同一段代码）。
    private weak var viewModel: SandboxViewModel?
    private weak var daemonManager: DaemonProcessManager?
    private var flowStarted = false
    private var flowSteps: [[String: Any]] = []
    private var quitFired = false

    /// 主界面出现时调用（DockerMainView.onAppear）。
    @MainActor
    func attach(viewModel: SandboxViewModel, daemonManager: DaemonProcessManager) {
        self.viewModel = viewModel
        self.daemonManager = daemonManager
        guard scenario == "flow", !flowStarted else { return }
        flowStarted = true
        Task { @MainActor in
            await self.runFlow()
            self.fireCommandQ()
        }
    }

    func start() {
        startLagSampler()
        let raw = ProcessInfo.processInfo.environment["DBX_GUI_SELFTEST_QUIT_AFTER"] ?? ""
        guard let seconds = Double(raw), seconds > 0, seconds <= 120 else { return }
        if scenario == "modal" {
            // 应用级模态（等价于 Settings 里「Pick…」弹出的文件选择面板）。runModal 会在这里嵌套运行
            // runloop 直到面板关闭；主队列上的定时任务在模态 runloop 里照常执行。
            // 必须用 runloop 定时器触发，而不是主 dispatch 队列的 block：主队列是串行的，
            // 若 runModal 卡在某个主队列 block 里，其它主队列任务（包括到点发退出请求的那个）永远排不上。
            // 真实的按钮点击来自事件回调，同样不是 dispatch block。
            let timer = Timer(timeInterval: 1.5, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    _ = panel.runModal()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        if scenario == "display" || scenario == "sheet" {
            // 等主窗口就绪后打开对应的 sheet；到点再发退出请求。
            let name = scenario == "display" ? Self.openDisplayRequest : Self.openSettingsRequest
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NotificationCenter.default.post(name: name, object: nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            MainActor.assumeIsolated { self.fireCommandQ() }
        }
    }

    @MainActor
    private func fireCommandQ() {
        guard !quitFired else { return }
        quitFired = true
        var target: NSWindow? = nil
        if scenario == "display" { target = focusDisplayView() }
        if scenario == "sheet" { target = NSApp.windows.first { $0.sheetParent != nil } }
        let sheetOpen = AppQuit.anySheetAttached
        writeReport(extra: ["phase": "before-cmd-q", "sheetAttachedBeforeQuit": sheetOpen, "quitVia": quitVia,
                            "appModalBeforeQuit": NSApp.modalWindow != nil])
        if quitVia == "appleevent" {
            let quit = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
                targetDescriptor: NSAppleEventDescriptor.currentProcess(),
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            _ = try? quit.sendEvent(options: [.noReply], timeout: 5)
            // 发给自己的事件在本轮 runloop 之后处理；若 3s 后还活着，记下来。
            lateFacts = ["phase": "after-quit-event", "stillRunningAfterQuitEvent": true,
                         "sheetAttachedBeforeQuit": sheetOpen, "quitVia": quitVia]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                MainActor.assumeIsolated { self.writeReport(extra: self.lateFacts) }
            }
            return
        }
        let outcome = sendSyntheticCommandQ(to: target)
        // 走到这里说明 ⌘Q 没有让 App 退出。
        // 诊断事实：⌘Q 为什么没有生效。
        func quitItem(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.keyEquivalent.lowercased() == "q", item.keyEquivalentModifierMask == [.command] { return item }
                if let hit = quitItem(item.submenu) { return hit }
            }
            return nil
        }
        let item = quitItem(NSApp.mainMenu)
        item?.menu?.update()
        var facts: [String: Any] = [
            "stillRunningAfterCmdQ": true,
            "cmdQConsumedByWindow": outcome.consumedByWindow,
            "cmdQHandledByMenu": outcome.handledByMenu,
            "quitItemEnabledAfterValidation": item?.isEnabled ?? false,
            "quitItemAction": item?.action.map(NSStringFromSelector) ?? "",
            "appModalWindowPresent": NSApp.modalWindow != nil,
            "anyWindowHasSheet": NSApp.windows.contains { $0.attachedSheet != nil },
            "appIsActive": NSApp.isActive,
            "keyWindowPresent": NSApp.keyWindow != nil,
        ]
        facts["sheetAttachedBeforeQuit"] = sheetOpen
        facts["quitVia"] = quitVia
        // AppQuit 需要几轮 runloop 收起 sheet；3s 后还活着才算「没退出」。
        facts["phase"] = "quit-in-progress"
        writeReport(extra: facts)
        // 不把 [String: Any] 捕获进 @Sendable 闭包（旧一些的 Swift 6 编译器会拒绝）：存到实例上。
        lateFacts = facts
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            MainActor.assumeIsolated {
                var late = self.lateFacts
                late["phase"] = "after-cmd-q"
                self.writeReport(extra: late)
            }
        }
    }

    // MARK: - M32 flow

    @MainActor
    private func step(_ name: String, _ ok: Bool, _ detail: String = "") {
        flowSteps.append(["name": name, "ok": ok, "detail": String(detail.prefix(400))])
        writeReport(extra: ["phase": "flow"])
    }

    @MainActor
    private func waitUntil(_ timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @MainActor
    private func submit(_ request: DaemonRequest, label: String) async -> Result<DaemonResponse, Error> {
        guard let viewModel else { return .failure(DaemonClientError.weird("view model gone")) }
        return await withCheckedContinuation { continuation in
            viewModel.submit(request, label: label, daemonManager: daemonManager) { result in
                continuation.resume(returning: result)
            }
        }
    }

    @MainActor
    private func exec(_ sandboxId: String, _ line: String) async -> Result<DaemonResponse, Error> {
        guard let viewModel else { return .failure(DaemonClientError.weird("view model gone")) }
        return await withCheckedContinuation { continuation in
            viewModel.exec(sandboxId: sandboxId, commandLine: line, daemonManager: daemonManager) { result in
                continuation.resume(returning: result)
            }
        }
    }

    @MainActor
    private func fetchConsole(_ sandboxId: String) async -> String? {
        guard let client = viewModel?.client else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var request = DaemonRequest(kind: "consoleLog")
                request.sandboxId = sandboxId
                request.waitMillis = 16384
                let text = (try? client.send(request, timeoutSec: 5)).flatMap { ConsoleLog.text(fromHex: $0.outputHex ?? "") }
                continuation.resume(returning: text)
            }
        }
    }

    @MainActor
    private func sample(_ model: StatsModel) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            model.sample { continuation.resume() }
        }
    }

    @MainActor
    private func state(of id: String) -> String {
        viewModel?.sandboxes.first { $0.sandboxId == id }?.state ?? "(absent)"
    }

    /// Run → Exec → Suspend → Resume → Rm，每一步都经由视图模型里按钮所用的同一入口。
    /// 任何一步失败即停止（后续步骤不执行，报告里看不到它们 = 未通过）。
    @MainActor
    private func runFlow() async {
        guard let viewModel, let daemonManager else { return step("attach", false, "no view model") }

        // 1) GUI 自动拉起的 daemon 就绪
        guard await waitUntil(20, { daemonManager.status == .connected }) else {
            return step("daemon-connected", false, "status=\(daemonManager.status.rawValue)")
        }
        step("daemon-connected", true)

        // 2) Run New Sandbox
        let manifest = UserDefaults.standard.string(forKey: "manifestPath") ?? ""
        let run = await submit(SandboxViewModel.runRequest(manifestPath: manifest), label: "run started")
        guard case .success(let created) = run, let id = created.sandboxId else {
            return step("run", false, "\(run)")
        }
        step("run", true, id)
        guard await waitUntil(5, { self.state(of: id) == "running" }) else {
            return step("listed-running", false, "state=\(state(of: id))")
        }
        step("listed-running", true, SandboxRowActions.available(forState: "running").map(\.rawValue).joined(separator: ","))

        // 2b) Workspace 同步——必须在任何 exec / pty **之前**：对旧 guest，workload 运行之后的
        //     再次同步会被宿主拒绝（M37）。「先同步、再运行」也是正常的使用顺序。
        let workspaceDirectory: String? = {
            let value = ProcessInfo.processInfo.environment["DBX_GUI_SELFTEST_WORKSPACE"] ?? ""
            return value.isEmpty ? nil : value
        }()
        if let workspace = workspaceDirectory {
            let synced: (String, Bool) = await withCheckedContinuation { continuation in
                WorkspaceSync.sync(client: viewModel.client, sandboxId: id, path: workspace) { text, ok in
                    continuation.resume(returning: (text, ok))
                }
            }
            guard synced.1 else { return step("workspace-sync", false, synced.0) }
            step("workspace-sync", true, synced.0)
        }

        // 3) Exec：带引号的命令行（旧的按空格拆分做不到）
        _ = await exec(id, "/bin/sh -c 'echo flow-ok; id -u'")
        let out = viewModel.execOutput
        guard out.contains("exit=0"), out.contains("flow-ok"), out.contains("65534") else {
            return step("exec-quoted", false, out)
        }
        step("exec-quoted", true)

        // 3b) 非法命令行在本地被拒，不发给 daemon
        _ = await exec(id, "/bin/echo 'unterminated")
        guard viewModel.execOutput.contains("命令行无法解析") else {
            return step("exec-bad-quoting-rejected", false, viewModel.execOutput)
        }
        step("exec-bad-quoting-rejected", true)

        // 3b2) Cancel：命令在途时 Cancel 可用；按下之后的结果取决于 guest——
        //      新 guest → 命令被取消（输出里有取消之前的内容）；旧 guest → 界面给出可读原因，命令照常跑完。
        //      两者都是正确行为；空闲时 Cancel 不可用。
        guard viewModel.execRunningSandboxId == nil else { return step("exec-cancel", false, "空闲时 execRunningSandboxId 非空") }
        async let longRunning = exec(id, "/bin/sh -c 'echo cancel-me; sleep 4; echo ran-to-end'")
        var waited = 0
        while viewModel.execRunningSandboxId == nil, waited < 40 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        guard viewModel.execRunningSandboxId == id else { _ = await longRunning; return step("exec-cancel", false, "命令在途时 Cancel 未启用") }
        try? await Task.sleep(nanoseconds: 800_000_000)
        let cancelAccepted: Bool = await withCheckedContinuation { continuation in
            viewModel.cancelExec { ok in continuation.resume(returning: ok) }
        }
        _ = await longRunning
        let afterCancel = viewModel.execOutput
        if cancelAccepted {
            guard viewModel.execCancelNote == "exec cancelled", afterCancel.contains("cancel-me"),
                  afterCancel.contains("exec cancelled"), !afterCancel.contains("ran-to-end") else {
                return step("exec-cancel", false, "note=\(viewModel.execCancelNote) out=\(afterCancel)")
            }
            step("exec-cancel", true, "cancelled")
        } else {
            guard viewModel.execCancelNote.contains("无法取消"), afterCancel.contains("exit=0"),
                  afterCancel.contains("ran-to-end"), daemonManager.status == .connected else {
                return step("exec-cancel", false, "note=\(viewModel.execCancelNote) out=\(afterCancel)")
            }
            step("exec-cancel", true, "unsupported: \(viewModel.execCancelNote.prefix(60))")
        }
        guard viewModel.execRunningSandboxId == nil else { return step("exec-cancel-idle", false, "结束后 Cancel 仍然启用") }
        step("exec-cancel-idle", true)

        // 3c) daemon 拒绝的请求：界面显示可读原因，且**不**把 daemon 标成 stopped
        _ = await exec(id, "/usr/bin/not-allowed")
        guard viewModel.execOutput.contains("请求被 daemon 拒绝") || viewModel.execOutput.contains("["),
              daemonManager.status == .connected else {
            return step("rejection-keeps-daemon-connected", false,
                        "status=\(daemonManager.status.rawValue) out=\(viewModel.execOutput)")
        }
        step("rejection-keeps-daemon-connected", true, viewModel.execOutput)

        // 3d) Terminal（PTY）：打开 → 输入 → 看到输出 → 关闭 → **再次打开**（关掉终端再开是最基本的用法）
        for (round, expression, expected) in [(1, "pty-$((6*7))", "pty-42"), (2, "again-$((20+3))", "again-23")] {
            let pty = PtySessionModel(sandboxId: id, client: viewModel.client)
            pty.open()
            guard await waitUntil(10, { pty.running }) else {
                return step("pty-open-\(round)", false, pty.error ?? "not running")
            }
            pty.sendInput("echo \(expression)")
            guard await waitUntil(10, { pty.output.contains(expected) }) else {
                return step("pty-roundtrip-\(round)", false, "error=\(pty.error ?? "nil") output=\(pty.output.suffix(200))")
            }
            let clean = !pty.output.unicodeScalars.contains { $0.value == 0x1B || ($0.value < 0x20 && $0 != "\n" && $0 != "\t") }
            pty.close()
            guard clean else { return step("pty-output-sanitized-\(round)", false, String(pty.output.suffix(200))) }
            step("pty-roundtrip-\(round)", true, expected)
        }

        // 3e) Console：guest serial 的内容可读（引导横幅在里面）
        let console = await fetchConsole(id)
        guard let consoleText = console, consoleText.contains("Desk Box") else {
            return step("console", false, String((console ?? "<nil>").suffix(200)))
        }
        step("console", true, "\(consoleText.count) chars")

        // 3f) Stats：两次采样后有内存与 CPU%；选中不存在的沙箱时错误可见、旧数字被清掉
        let stats = StatsModel(client: viewModel.client)
        stats.select(id)
        await sample(stats)
        try? await Task.sleep(for: .milliseconds(1100))
        await sample(stats)
        guard stats.statsError == nil, let mem = stats.memCurrent, mem > 0, let cpu = stats.cpuPercent else {
            return step("stats", false, "err=\(stats.statsError ?? "nil") mem=\(String(describing: stats.memCurrent)) cpu=\(String(describing: stats.cpuPercent))")
        }
        step("stats", true, "mem=\(mem) cpu=\(String(format: "%.1f", cpu))%")
        stats.select("00000000-0000-0000-0000-000000000000")
        await sample(stats)
        guard stats.statsError != nil, stats.memCurrent == nil, stats.cpuPercent == nil, stats.history.isEmpty else {
            return step("stats-error-visible", false, "err=\(stats.statsError ?? "nil") mem=\(String(describing: stats.memCurrent))")
        }
        step("stats-error-visible", true, stats.statsError ?? "")

        // 3g) 再次同步（此时已经运行过 exec / pty）。结果取决于 guest 的 workspace 接收端：
        //     新接收端 → 成功；旧 guest → 被宿主拒绝，界面给出可读原因。两者都是正确行为。
        if let workspace = workspaceDirectory {
            _ = await exec(id, "/bin/sh -c 'cat /workspace/marker.txt'")
            guard viewModel.execOutput.contains("gui-flow-marker") else {
                return step("workspace-sync-content", false, viewModel.execOutput)
            }
            step("workspace-sync-content", true)
            let again: (String, Bool) = await withCheckedContinuation { continuation in
                WorkspaceSync.sync(client: viewModel.client, sandboxId: id, path: workspace) { text, ok in
                    continuation.resume(returning: (text, ok))
                }
            }
            if again.1 {
                step("workspace-resync", true, "allowed")
            } else if again.0.contains("无法再次同步"), again.0.contains("DBX-WS-RESYNC-UNSAFE"),
                      daemonManager.status == .connected {
                step("workspace-resync", true, "gated: \(again.0)")
            } else {
                return step("workspace-resync", false, again.0)
            }
            let bad: (String, Bool) = await withCheckedContinuation { continuation in
                WorkspaceSync.sync(client: viewModel.client, sandboxId: id, path: workspace + "/marker.txt") { text, ok in
                    continuation.resume(returning: (text, ok))
                }
            }
            guard !bad.1, bad.0.contains("不是目录") else { return step("workspace-sync-precheck", false, bad.0) }
            step("workspace-sync-precheck", true)
        }

        // 4) Suspend（行内按钮对应的请求）
        guard SandboxRowActions.available(forState: state(of: id)).contains(.suspend),
              let suspendRequest = SandboxRowActions.request(for: .suspend, sandboxId: id) else {
            return step("suspend", false, "suspend 按钮在 state=\(state(of: id)) 下不可用")
        }
        let suspended = await submit(suspendRequest, label: "suspend")
        guard case .success = suspended, state(of: id) == "suspended" else {
            return step("suspend", false, "\(suspended) state=\(state(of: id))")
        }
        let suspendedActions = SandboxRowActions.available(forState: state(of: id))
        step("suspend", true, suspendedActions.map(\.rawValue).joined(separator: ","))

        // 5) Resume：成功，或在宿主锁屏时得到可读的原因（两者都是正确行为，分别记录）
        guard suspendedActions.contains(.resume),
              let resumeRequest = SandboxRowActions.request(for: .resume, sandboxId: id) else {
            return step("resume", false, "resume 按钮不可用")
        }
        let resumed = await submit(resumeRequest, label: "resume")
        switch resumed {
        case .success:
            guard state(of: id) == "running" else { return step("resume", false, "state=\(state(of: id))") }
            step("resume", true, "resumed")
            _ = await exec(id, "/bin/echo after-resume")
            guard viewModel.execOutput.contains("after-resume") else {
                return step("exec-after-resume", false, viewModel.execOutput)
            }
            step("exec-after-resume", true)
        case .failure(let error):
            let shown = DaemonErrorPresenter.present(error)
            guard shown.code == "DBX-RESUME-HOST-LOCKED" else { return step("resume", false, shown.detail) }
            // 锁屏：界面必须给出可读原因、沙箱保持 suspended、daemon 状态不变。
            guard viewModel.execOutput.contains(shown.title), state(of: id) == "suspended",
                  daemonManager.status == .connected else {
                return step("resume-host-locked-presented", false,
                            "out=\(viewModel.execOutput) state=\(state(of: id)) daemon=\(daemonManager.status.rawValue)")
            }
            step("resume-host-locked-presented", true, shown.logLine)
        }

        // 6) Rm
        guard let rmRequest = SandboxRowActions.request(for: .rm, sandboxId: id) else { return step("rm", false) }
        let removed = await submit(rmRequest, label: "rm")
        guard case .success = removed, state(of: id) == "(absent)" else {
            return step("rm", false, "\(removed) state=\(state(of: id))")
        }
        step("rm", true)
        step("flow-complete", true)
    }

    /// M31：找到 guest 画面（VZVirtualMachineView），让它成为所在窗口的 first responder，
    /// 并记录当时的事实（VM 状态、capturesSystemKeys、焦点是否真的落在它上面）。
    @MainActor
    private func focusDisplayView() -> NSWindow? {
        func find(_ view: NSView) -> VZVirtualMachineView? {
            if let vz = view as? VZVirtualMachineView { return vz }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        for window in NSApp.windows {
            guard let content = window.contentView, let vz = find(content) else { continue }
            let accepted = window.makeFirstResponder(vz)
            displayFacts = [
                "displayViewFound": true,
                "displayVMState": vz.virtualMachine.map { "\($0.state.rawValue)" } ?? "nil",
                "displayVMRunning": vz.virtualMachine?.state == .running,
                "capturesSystemKeys": vz.capturesSystemKeys,
                "makeFirstResponderAccepted": accepted,
                "firstResponderIsDisplayView": window.firstResponder === vz,
                "displayWindowIsSheet": window.sheetParent != nil,
            ]
            return window
        }
        displayFacts = ["displayViewFound": false]
        return nil
    }

    /// AppDelegate 在 terminate 路径上调用：证明退出经由 `applicationShouldTerminate`，而不是崩溃或被杀。
    /// 内容是退出方式：`terminate`（正常）或 `forced`（AppQuit 的兜底）。
    func noteTerminating(path: AppQuit.Path) {
        FileManager.default.createFile(atPath: terminatedMarkerPath, contents: Data("\(path.rawValue)\n".utf8))
    }

    private func startLagSampler() {
        let thread = Thread { [self] in
            while true {
                lock.lock(); let stop = stopSampling; lock.unlock()
                if stop { break }
                let posted = DispatchTime.now()
                DispatchQueue.main.async { [self] in
                    let lag = Double(DispatchTime.now().uptimeNanoseconds - posted.uptimeNanoseconds) / 1_000_000
                    lock.lock()
                    samples += 1
                    if lag > maxLagMs { maxLagMs = lag }
                    lock.unlock()
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.name = "deskbox.gui.selftest.lag"
        thread.start()
    }

    /// 按 AppKit 对带 ⌘ 的 keyDown 的处理顺序投递：
    /// 先让目标窗口（及其视图层级，first responder 所在的那条链）决定是否消费，
    /// 没人消费才交给主菜单。`window == nil` 时直接走主菜单。
    @MainActor
    private func sendSyntheticCommandQ(to window: NSWindow?) -> (consumedByWindow: Bool, handledByMenu: Bool) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12
        ) else { return (false, false) }
        if let window, window.performKeyEquivalent(with: event) {
            return (true, false)   // 被窗口里的视图吃掉了：菜单根本没机会
        }
        return (false, NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
    }

    @MainActor
    private func menuSnapshot(_ menu: NSMenu?, path: String = "") -> [[String: Any]] {
        guard let menu else { return [] }
        var out: [[String: Any]] = []
        for item in menu.items where !item.isSeparatorItem {
            let here = path.isEmpty ? item.title : "\(path) > \(item.title)"
            out.append([
                "path": here,
                "title": item.title,
                "keyEquivalent": item.keyEquivalent,
                "command": item.keyEquivalentModifierMask.contains(.command),
                "shift": item.keyEquivalentModifierMask.contains(.shift),
                "option": item.keyEquivalentModifierMask.contains(.option),
                "control": item.keyEquivalentModifierMask.contains(.control),
                "action": item.action.map(NSStringFromSelector) ?? "",
                "enabled": item.isEnabled,
            ])
            out.append(contentsOf: menuSnapshot(item.submenu, path: here))
        }
        return out
    }

    @MainActor
    private func writeReport(extra: [String: Any]) {
        lock.lock(); let lag = maxLagMs; let n = samples; lock.unlock()
        var report: [String: Any] = [
            "schema": "deskbox-gui-selftest/v1",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "supportRoot": DeskBoxPaths.supportRoot.path,
            "sockPath": DaemonSocketClient.defaultSockPath(),
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "maxMainThreadLagMs": lag,
            "lagSamples": n,
            "windowCount": NSApp.windows.count,
            "menu": menuSnapshot(NSApp.mainMenu),
        ]
        report["scenario"] = scenario
        if !flowSteps.isEmpty { report["flow"] = flowSteps }
        if let daemonManager { report["daemonStatus"] = daemonManager.status.rawValue }
        for (k, v) in displayFacts { report[k] = v }
        for (k, v) in extra { report[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
    }
}
