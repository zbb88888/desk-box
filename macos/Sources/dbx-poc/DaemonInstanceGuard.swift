import Darwin
import Foundation

/// M27：daemon 单实例守卫（按 socket 路径）。
///
/// 两道检查，缺一不可：
/// 1. `<sock>.lock` 上的 `flock(LOCK_EX|LOCK_NB)`，持有到 daemon 退出——新版本 daemon 之间
///    无竞争地互斥（两个 daemon 同时启动也只有一个能拿到）；
/// 2. 对现有 socket 做一次 `connect` 探活——识别**不持锁的旧版本 daemon**（以及任何其它
///    正在该路径上监听的进程）。能连上就拒绝启动；连不上（ECONNREFUSED / ENOENT）才是
///    崩溃残留的 stale socket，可以清掉。
///
/// 锁文件常驻（与 registry.lock 一样）：unlink 锁文件会引入「旧 fd 持锁、新文件无锁」的竞争。
final class DaemonInstanceGuard {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func lockPath(forSocket sockPath: String) -> String { sockPath + ".lock" }

    static func acquire(sockPath: String) throws -> DaemonInstanceGuard {
        let lockPath = lockPath(forSocket: sockPath)
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw CLIError.usage("DBX-DAEMON-LOCK: cannot open \(lockPath): errno=\(errno)")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK {
                throw CLIError.usage("DBX-DAEMON-ALREADY-RUNNING: another daemon holds \(lockPath); refusing to take over \(sockPath)")
            }
            throw CLIError.usage("DBX-DAEMON-LOCK: flock \(lockPath) failed: errno=\(code)")
        }
        if socketIsLive(sockPath) {
            flock(fd, LOCK_UN)
            close(fd)
            throw CLIError.usage("DBX-DAEMON-ALREADY-RUNNING: a daemon is already listening on \(sockPath); refusing to take over")
        }
        return DaemonInstanceGuard(fd: fd)
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }

    /// 路径上是否有进程在 accept。只 connect、不发任何字节（daemon 侧把空请求当探活忽略）。
    static func socketIsLive(_ sockPath: String) -> Bool {
        let pathBytes = Array(sockPath.utf8)
        guard pathBytes.count < 104 else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { buf in
            buf.withMemoryRebound(to: CChar.self, capacity: 104) { p in
                for (i, b) in pathBytes.enumerated() { p[i] = CChar(bitPattern: b) }
            }
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
    }
}
