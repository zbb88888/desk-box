import Foundation
import Darwin

/// M49：accept 循环遇到异常时怎么办（纯函数）。
enum AcceptLoopPolicy {
    enum Action: Equatable {
        /// 正常：去 accept / 回到 poll。
        case accept
        /// 暂时性的资源问题：退避一下再试，别空转。
        case wait
        /// 监听 socket 本身已经失效：继续下去只会空转，daemon 应当停下来。
        case listenerDead
    }

    /// poll 返回的事件。
    static func action(revents: Int16) -> Action {
        if revents & Int16(POLLNVAL) != 0 { return .listenerDead }                 // 描述符已经不是打开的了
        if revents & Int16(POLLERR | POLLHUP) != 0, revents & Int16(POLLIN) == 0 { return .listenerDead }
        return .accept
    }

    /// accept 失败时的 errno。
    static func action(acceptErrno code: Int32) -> Action {
        switch code {
        case EBADF, ENOTSOCK, EINVAL, EOPNOTSUPP:
            return .listenerDead
        case EMFILE, ENFILE, ENOMEM, ENOBUFS:
            return .wait
        default:
            return .accept      // EAGAIN / EWOULDBLOCK / ECONNABORTED / EINTR / EPROTO：这一条连接没了，继续
        }
    }
}
