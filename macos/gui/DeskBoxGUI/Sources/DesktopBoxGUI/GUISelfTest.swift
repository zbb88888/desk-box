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

    func start() {
        startLagSampler()
        let raw = ProcessInfo.processInfo.environment["DBX_GUI_SELFTEST_QUIT_AFTER"] ?? ""
        guard let seconds = Double(raw), seconds > 0, seconds <= 120 else { return }
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
        var target: NSWindow? = nil
        if scenario == "display" { target = focusDisplayView() }
        if scenario == "sheet" { target = NSApp.windows.first { $0.sheetParent != nil } }
        let sheetOpen = AppQuit.anySheetAttached
        writeReport(extra: ["phase": "before-cmd-q", "sheetAttachedBeforeQuit": sheetOpen, "quitVia": quitVia])
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
        for (k, v) in displayFacts { report[k] = v }
        for (k, v) in extra { report[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
    }
}
