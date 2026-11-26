import Foundation

/// M53：不可撤销的操作先确认。
///
/// 此前 Rm / Restart / Stop / Shutdown Daemon 都是一点即执行：Rm 就在 Stop 旁边，点错一次，
/// 沙箱连同里面的数据就没了；Shutdown Daemon 会结束所有沙箱，同样没有任何提示。
struct ConfirmationPrompt: Equatable, Identifiable {
    enum Target: Equatable {
        case sandbox(action: SandboxAction, sandboxId: String)
        case shutdownDaemon
    }
    let target: Target
    let title: String
    let message: String
    /// 确认按钮上的字（说出要做的事，不用「OK」）。
    let confirmLabel: String

    var id: String {
        switch target {
        case .sandbox(let action, let sandboxId): return "\(action.rawValue):\(sandboxId)"
        case .shutdownDaemon: return "shutdown"
        }
    }
}

enum ActionConfirmation {
    /// 需要确认的行内操作返回提示；可以撤销 / 没有损失的操作返回 nil（直接执行）。
    static func prompt(for action: SandboxAction, sandboxId: String, state: String) -> ConfirmationPrompt? {
        let short = String(sandboxId.prefix(8))
        let target = ConfirmationPrompt.Target.sandbox(action: action, sandboxId: sandboxId)
        switch action {
        case .rm:
            let losing = state == "failed" || state == "stopped"
                ? "它的磁盘会被删除。"
                : "它会被立刻结束，沙箱里的数据（包括 /workspace 里没有取回的内容）会被删除。"
            return ConfirmationPrompt(target: target, title: "移除沙箱 \(short)…？",
                                      message: losing + "这个操作不能撤销。", confirmLabel: "移除")
        case .restart:
            return ConfirmationPrompt(target: target, title: "重建沙箱 \(short)…？",
                                      message: "Restart 会移除这台沙箱，再用同样的参数新建一台（新的 sandbox id）。沙箱里的数据不保留，这个操作不能撤销。",
                                      confirmLabel: "重建")
        case .stop:
            return ConfirmationPrompt(target: target, title: "停止沙箱 \(short)…？",
                                      message: "停止后的沙箱不能再启动，只能移除；里面正在运行的程序会被结束。想保留现场请用 Suspend。",
                                      confirmLabel: "停止")
        case .terminal, .console, .exec, .suspend, .resume:
            return nil
        }
    }

    /// Shutdown Daemon：名下没有沙箱时没有损失，直接执行。
    static func shutdownPrompt(sandboxCount: Int) -> ConfirmationPrompt? {
        guard sandboxCount > 0 else { return nil }
        return ConfirmationPrompt(target: .shutdownDaemon, title: "关闭 daemon？",
                                  message: "daemon 名下的 \(sandboxCount) 台沙箱会全部结束（suspended 的也不能再恢复）。这个操作不能撤销。",
                                  confirmLabel: "关闭 daemon")
    }
}
