import Foundation
import Darwin

/// M42：在处理一条长请求（exec）期间，留意它的客户端是否已经走了。
///
/// 此前 daemon 只在写应答时才会发现客户端不在——命令已经在 guest 里跑完了。客户端被强杀、
/// 连接断开、或界面的读超时到点之后，命令仍占着沙箱的操作队列直到自己结束或超时。
///
/// 判定「走了」要小心半关闭：客户端发完请求后 `shutdown(SHUT_WR)`（例如 `nc`）时，
/// 我们这边同样读到 EOF，但它还在等应答。区分办法是往回写一个字节：
/// 对端完全关闭 → EPIPE；只是半关闭 → 写成功。写的是一个空格——JSON 应答之前的空白对解析无影响。
final class ClientDisconnectWatcher: @unchecked Sendable {
    enum Probe: Equatable { case stillConnected, disconnected }

    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    private let done = DispatchSemaphore(value: 0)
    private var started = false

    init(fd: Int32) {
        self.fd = fd
        Self.prepare(fd)
    }

    /// 探测写不能触发 SIGPIPE。必须在对端关闭**之前**设置：对端关闭之后 macOS 的 setsockopt 会以
    /// EINVAL 失败（daemon 进程全局忽略了 SIGPIPE，这里是为了不依赖那个前提）。
    static func prepare(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 开始监视；客户端断开时在后台线程调用一次 `onDisconnect`。
    func start(onDisconnect: @escaping @Sendable () -> Void) {
        lock.lock(); started = true; lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { done.signal() }
            while !isStopped {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 100)
                if isStopped { return }
                if ready < 0 { if errno == EINTR { continue }; return }
                if ready == 0 { continue }
                if pfd.revents & Int16(POLLNVAL) != 0 { return }
                var byte: UInt8 = 0
                let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                if n > 0 { return }      // 客户端在请求之后又发了数据：不是断开；停止监视，避免空转
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                    if pfd.revents & Int16(POLLHUP) == 0 { continue }
                }
                // EOF（或带 HUP 的错误）：半关闭还是真的走了？
                if isStopped { return }
                if Self.probe(fd) == .disconnected { onDisconnect() }
                return
            }
        }
    }

    /// 停止监视并等后台线程退出（之后调用方才可以关闭 / 写这个 fd）。
    func stop() {
        lock.lock()
        let wasStarted = started
        stopped = true
        lock.unlock()
        if wasStarted { done.wait() }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// 往回写一个空格，看对端是否还在。调用前需已 `prepare(fd)`。
    static func probe(_ fd: Int32) -> Probe {
        var space: UInt8 = 0x20
        let n = send(fd, &space, 1, MSG_DONTWAIT)
        if n == 1 { return .stillConnected }
        // 发送缓冲区满（对端还在，只是没读）也算还在。
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS { return .stillConnected }
        return .disconnected
    }
}

/// M42：一条 exec 请求与它的客户端之间的关系（线程安全，纯状态）。
/// 客户端走了之后：还在排队 → 轮到时不再执行；已经在 guest 上 → 请求取消。
final class ExecAbandonment: @unchecked Sendable {
    static let refusalCode = "DBX-EXEC-CLIENT-GONE"

    private let lock = NSLock()
    private var abandoned = false
    private var token: UInt64?

    /// 客户端断开时调用。返回在途 exec 的令牌（需要去取消它）；还没开始执行则为 nil。
    func markAbandoned() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        abandoned = true
        return token
    }

    /// 轮到这条 exec、即将发给 guest 时调用。客户端已经走了则返回 false（不要执行）。
    func begin(token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if abandoned { return false }
        self.token = token
        return true
    }

    var isAbandoned: Bool { lock.lock(); defer { lock.unlock() }; return abandoned }
}
