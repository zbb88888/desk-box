import AppKit
import Foundation

/// M31：所有「退出 App」的请求都走这里。
///
/// 为什么需要它：AppKit 在任一窗口挂着 sheet 时**拒绝终止**——`NSApp.terminate(nil)` 直接返回，
/// `applicationShouldTerminate` 根本不会被调用，也没有任何提示。而这个 GUI 的 Display / Terminal /
/// Console / Settings 全部以 sheet 呈现，所以只要其中任何一个开着，⌘Q、菜单 Quit、菜单栏 Quit、
/// Dock 的 Quit、乃至注销/关机发来的退出事件都无效。这才是「⌘Q 无法退出」的主要原因
///（实测：sheet 打开时 Quit 菜单项是 enabled 的、action 也触发了，但 terminate 立即返回）。
///
/// 做法（三级，逐级兜底）：
/// 1. 请 SwiftUI 自己收起 sheet：广播 `dismissSheetsRequest`，视图把各个 sheet 的呈现状态清掉。
///    这是唯一能让 AppKit 重新允许终止的方式——实测直接在 AppKit 层 `endSheet` 不够：
///    SwiftUI 的绑定仍为 true，`terminate` 照样返回。
/// 2. 1 秒后仍有 sheet（比如某个视图没响应广播）：AppKit 层 `endSheet` 强行收起。
/// 3. `terminate` 仍然返回：自己执行与 `applicationShouldTerminate` 相同的清理后退出进程。
/// 退出不允许静默失败。daemon 是独立进程，不受影响。
@MainActor
enum AppQuit {
    /// 退出方式，供自检报告区分（正常应为 `.terminate`）。
    enum Path: String { case terminate, forced }

    /// 视图收到后应清掉自己所有 sheet 的呈现状态。
    static let dismissSheetsRequest = Notification.Name("deskbox.quit.dismiss-sheets")

    private static var inProgress = false
    private static let pollInterval = 0.05
    private static let totalPolls = 40          // 40 × 50ms = 最多等 2s
    private static let appKitFallbackAt = 20    // 剩余 20 次（已等 1s）时启用第 2 级

    static func quit() {
        guard !inProgress else { return }
        inProgress = true
        if anySheetAttached {
            NotificationCenter.default.post(name: dismissSheetsRequest, object: nil)
        }
        attempt(remaining: totalPolls)
    }

    static var anySheetAttached: Bool {
        NSApp.windows.contains { $0.attachedSheet != nil }
    }

    /// 收起所有 sheet（含 sheet 上再挂的 sheet：从最内层开始）。
    static func dismissAllSheets() {
        for window in NSApp.windows {
            var chain: [(parent: NSWindow, sheet: NSWindow)] = []
            var current = window
            while let sheet = current.attachedSheet {
                chain.append((current, sheet))
                current = sheet
            }
            for link in chain.reversed() { link.parent.endSheet(link.sheet) }
        }
    }

    private static func attempt(remaining: Int) {
        if anySheetAttached && remaining > 0 {
            if remaining <= appKitFallbackAt { dismissAllSheets() }
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                MainActor.assumeIsolated { attempt(remaining: remaining - 1) }
            }
            return
        }
        // 正常情况下 terminate 不会返回：applicationShouldTerminate 回 .terminateNow 后进程退出。
        NSApp.terminate(nil)
        // 走到这里说明 AppKit 拒绝了终止。给它一小段时间（万一是异步完成），然后兜底。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { forceExit() }
        }
    }

    private static func forceExit() {
        // 与 applicationShouldTerminate 相同的清理（display 会话私盘等监听 willTerminate）。
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        GUISelfTest.shared?.noteTerminating(path: .forced)
        exit(0)
    }
}
