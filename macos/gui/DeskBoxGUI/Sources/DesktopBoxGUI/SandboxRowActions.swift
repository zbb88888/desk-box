import Foundation

/// M30：沙箱行内操作按生命周期状态启用（纯函数，可单元测试）。
///
/// 此前所有按钮对任何状态都可点：对 suspended 沙箱点 Terminal/Exec 只会得到一条 daemon 拒绝；
/// 而 suspend / resume 在 GUI 里根本没有入口。
enum SandboxAction: String, CaseIterable, Identifiable {
    case terminal, console, exec, suspend, resume, restart, stop, rm
    var id: String { rawValue }

    var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .console: return "Console"
        case .exec: return "Exec"
        case .suspend: return "Suspend"
        case .resume: return "Resume"
        case .restart: return "Restart"
        case .stop: return "Stop"
        case .rm: return "Rm"
        }
    }

    /// 对应的 daemon 请求 kind；nil 表示纯界面动作（打开面板 / 填充输入框）。
    var daemonKind: String? {
        switch self {
        case .terminal, .console, .exec: return nil
        case .suspend: return "suspend"
        case .resume: return "resume"
        case .restart: return "restart"
        case .stop: return "stop"
        case .rm: return "rm"
        }
    }

    var isDestructive: Bool { self == .rm }
}

enum SandboxRowActions {
    /// `state` 是 daemon `ps` 返回的生命周期状态字符串。
    ///
    /// - Console（宿主侧 serial 缓冲）与 Rm（强制移除）对任何状态都可用——后者是任何
    ///   异常状态的唯一出路，绝不能被禁掉。
    /// - 未知状态按最保守处理：只给 Console 与 Rm。
    static func available(forState state: String) -> [SandboxAction] {
        switch state {
        case "running":
            return [.terminal, .console, .exec, .suspend, .restart, .stop, .rm]
        case "suspended":
            return [.console, .resume, .rm]
        default:
            // pending / suspending / resuming / stopping / stopped / failed / 未知
            return [.console, .rm]
        }
    }

    /// 构造行内操作对应的 daemon 请求（界面动作返回 nil）。GUI 的 Rm 一律强制。
    static func request(for action: SandboxAction, sandboxId: String) -> DaemonRequest? {
        guard let kind = action.daemonKind else { return nil }
        var request = DaemonRequest(kind: kind)
        request.sandboxId = sandboxId
        if action == .rm { request.force = true }
        return request
    }
}
