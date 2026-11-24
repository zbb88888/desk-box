import Foundation

/// M41：`dbx-poc exec` 运行期间的 SIGINT / SIGTERM 处理。
///
/// 主线程阻塞在读 daemon 的应答上；信号由 DispatchSource 在后台队列接收：
/// 1. 第一次：另开一条连接发 `execCancel`。成功 → 什么都不做，主线程很快会读到「已取消」的应答
///   （带着取消之前的输出）。失败（旧 guest 不支持 / daemon 不可达）→ 打印原因并以 128+信号 退出，
///    这就是此前的行为：客户端走了，命令留在 guest 里。
/// 2. 第二次：不再等，直接退出。
final class ExecInterruptHandler: @unchecked Sendable {
    private let sandboxId: String?
    private let domain: String?
    private let sock: String?
    private let queue = DispatchQueue(label: "deskbox.exec.interrupt")
    private var sources: [DispatchSourceSignal] = []
    private let lock = NSLock()
    private var signalSeen: Int32?

    init(sandboxId: String?, domain: String?, sock: String?) {
        self.sandboxId = sandboxId
        self.domain = domain
        self.sock = sock
    }

    /// 收到过的信号（没有则为 nil）。
    var receivedSignal: Int32? {
        lock.lock(); defer { lock.unlock() }
        return signalSeen
    }

    func install() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)     // 交给 DispatchSource；默认动作会直接杀掉进程
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.handle(number) }
            source.resume()
            sources.append(source)
        }
    }

    func uninstall() {
        for source in sources { source.cancel() }
        sources.removeAll()
    }

    private func handle(_ number: Int32) {
        lock.lock()
        let first = signalSeen == nil
        signalSeen = number
        lock.unlock()
        guard first else { Foundation.exit(128 + number) }
        var request = DaemonRequest(kind: "execCancel")
        request.sandboxId = sandboxId
        request.domain = domain
        do {
            _ = try DaemonClient.send(request: request, sockPath: sock)
        } catch {
            fputs("dbx-poc: 无法取消 guest 里的命令：\(error)\n", stderr)
            Foundation.exit(128 + number)
        }
    }
}
