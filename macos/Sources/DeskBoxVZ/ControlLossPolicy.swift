import Foundation
import DeskBoxCore

/// M43：guest 一侧关闭控制连接时，这算不算「意外」（纯函数）。
///
/// 控制连接会在三种情况下被关闭：
/// 1. 宿主自己关的（stop / destroy / suspend 之后的 resume 会先把 `controlSocket` 置空再重装监听）
///    ——旧连接随后报出的 EOF 与当前会话无关；
/// 2. 沙箱不在 running（正在停止、已挂起、正在恢复……）——连接的生灭由生命周期管理；
/// 3. 沙箱在 running，而且出事的正是当前这条连接——guest 里的控制进程退出、崩溃或被杀。
/// 只有第 3 种需要让等待应答的调用方立刻失败。
public enum ControlLossPolicy {
    public static let code = "DBX-GUEST-CONTROL-LOST"

    public static func isUnexpected(failedSocketIsCurrent: Bool, state: SandboxState) -> Bool {
        failedSocketIsCurrent && state == .running
    }

    public static func message(waitingFor op: String, detail: String) -> String {
        "\(code): 等待 \(op) 的应答时，guest 关闭了控制连接（\(detail)）——guest 里的控制进程已退出或崩溃，"
            + "这台沙箱不会再响应。用 rm 移除后重新创建。"
    }
}

/// 让控制 socket 的失败回调能引用「它自己」（回调在 socket 构造时就要给出）。
final class ControlSocketIdentity: @unchecked Sendable {
    weak var socket: VZControlSocket?
}
