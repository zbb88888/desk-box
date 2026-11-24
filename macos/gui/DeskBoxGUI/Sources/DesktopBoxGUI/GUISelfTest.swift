import AppKit
import DeskBoxVZ
import Foundation

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

    func start() {
        startLagSampler()
        let raw = ProcessInfo.processInfo.environment["DBX_GUI_SELFTEST_QUIT_AFTER"] ?? ""
        guard let seconds = Double(raw), seconds > 0, seconds <= 120 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            writeReport(extra: ["phase": "before-cmd-q"])
            let handled = sendSyntheticCommandQ()
            // 走到这里说明 ⌘Q 没有让 App 退出。
            writeReport(extra: ["phase": "after-cmd-q", "cmdQHandledByMenu": handled, "stillRunningAfterCmdQ": true])
        }
    }

    /// AppDelegate 在 terminate 路径上调用：证明退出经由 `applicationShouldTerminate`，而不是崩溃或被杀。
    func noteTerminating() {
        FileManager.default.createFile(atPath: terminatedMarkerPath, contents: Data("terminate-path\n".utf8))
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

    private func sendSyntheticCommandQ() -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12
        ) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

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
        for (k, v) in extra { report[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
    }
}
