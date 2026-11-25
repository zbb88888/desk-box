import XCTest
import Darwin
import Foundation
@testable import dbx_poc

/// M27：daemon 单实例守卫——第二个 daemon 不得抢走正在运行的 daemon 的 socket。
final class DaemonInstanceGuardTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/dbxg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        }
        return dir
    }

    /// 在后台线程跑一个 daemon；返回 (完成信号, serveLoop 的错误盒)。
    private final class Run: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _error: String?
        private var _finished = false
        var error: String? { lock.lock(); defer { lock.unlock() }; return _error }
        var finished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }
        func finish(_ e: Error?) { lock.lock(); _error = e.map { "\($0)" }; _finished = true; lock.unlock(); done.signal() }
    }

    private func start(sock: String, dir: URL) -> Run {
        let run = Run()
        let daemon = SandboxDaemon(sockPath: sock, supportRoot: dir)
        Thread {
            do { try daemon.serveLoop(); run.finish(nil) } catch { run.finish(error) }
        }.start()
        addTeardownBlock {
            if !run.finished {
                _ = try? DaemonClient.send(request: DaemonRequest(kind: "shutdown"), sockPath: sock)
                _ = run.done.wait(timeout: .now() + 10)
            }
        }
        return run
    }

    private func waitReady(_ sock: String) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (try? DaemonClient.send(request: DaemonRequest(kind: "ps"), sockPath: sock)) != nil { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private func inode(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    func testSecondDaemonRefusesAndFirstKeepsItsSocket() throws {
        let dir = try tempDir()
        let sock = dir.appendingPathComponent("d.sock").path
        let first = start(sock: sock, dir: dir)
        XCTAssertTrue(waitReady(sock))
        let inodeBefore = inode(sock)

        let second = start(sock: sock, dir: dir)
        XCTAssertEqual(second.done.wait(timeout: .now() + 5), .success, "第二个 daemon 应立即退出")
        XCTAssertTrue(second.error?.contains("DBX-DAEMON-ALREADY-RUNNING") ?? false, second.error ?? "nil")

        // 第一个 daemon 的 socket 文件没有被 unlink/重建，且仍在服务。
        XCTAssertEqual(inode(sock), inodeBefore, "socket 文件被替换了")
        XCTAssertTrue(try DaemonClient.send(request: DaemonRequest(kind: "ps"), sockPath: sock).ok)
        XCTAssertFalse(first.finished)
    }

    func testStaleSocketFromCrashIsTakenOver() throws {
        let dir = try tempDir()
        let sock = dir.appendingPathComponent("d.sock").path
        // 模拟 kill -9 残留：bind 之后直接关闭 fd，不 unlink。
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(sock.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { p in
            for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) } } }
        XCTAssertEqual(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sock))
        XCTAssertFalse(DaemonInstanceGuard.socketIsLive(sock))

        _ = start(sock: sock, dir: dir)
        XCTAssertTrue(waitReady(sock), "stale socket 应被接管")
    }

    func testLiveListenerWithoutLockIsRespected() throws {
        // 旧版本 daemon 不持锁：只能靠 connect 探活识别。
        let dir = try tempDir()
        let sock = dir.appendingPathComponent("d.sock").path
        // M49：这个描述符只关一次。此前这里既有 `defer { close(fd) }`，下面又显式 close(fd)——
        // 显式关闭之后启动的 daemon 会复用这个编号（它的实例锁或监听 socket），方法结束时那个 defer
        // 再把它关掉一次：被关掉的是别人的描述符。后果是跨用例的随机失败（见 m49 文档 §2）。
        var fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { if fd >= 0 { close(fd) } }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(sock.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { p in
            for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) } } }
        XCTAssertEqual(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        XCTAssertEqual(listen(fd, 4), 0)
        let inodeBefore = inode(sock)
        XCTAssertTrue(DaemonInstanceGuard.socketIsLive(sock))

        let run = start(sock: sock, dir: dir)
        XCTAssertEqual(run.done.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(run.error?.contains("DBX-DAEMON-ALREADY-RUNNING") ?? false, run.error ?? "nil")
        XCTAssertEqual(inode(sock), inodeBefore, "正在监听的 socket 被抢走了")

        // 拒绝之后锁必须已释放：监听者退出后，新的 daemon 能正常启动。
        close(fd)
        fd = -1
        _ = start(sock: sock, dir: dir)
        XCTAssertTrue(waitReady(sock))
    }

    func testRestartOnSamePathAfterCleanShutdown() throws {
        let dir = try tempDir()
        let sock = dir.appendingPathComponent("d.sock").path
        for round in 1...3 {
            let run = start(sock: sock, dir: dir)
            XCTAssertTrue(waitReady(sock), "round \(round)")
            XCTAssertTrue(try DaemonClient.send(request: DaemonRequest(kind: "shutdown"), sockPath: sock).ok)
            XCTAssertEqual(run.done.wait(timeout: .now() + 10), .success)
            XCTAssertNil(run.error)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sock))
        }
    }

    func testShutdownDoesNotDependOnTheWakeConnection() throws {
        // M49：停机不依赖「shutdown 的处理线程连一下自己的 socket 把 accept 唤醒」。
        // 这里干脆不发那条唤醒连接：accept 循环自己轮询停机标志，停机仍必须在一个轮询周期内完成。
        let dir = try tempDir()
        let sock = dir.appendingPathComponent("d.sock").path
        for round in 1...5 {
            let run = Run()
            let daemon = SandboxDaemon(sockPath: sock, supportRoot: dir)
            daemon.wakeAcceptLoopOnShutdown = false
            Thread { do { try daemon.serveLoop(); run.finish(nil) } catch { run.finish(error) } }.start()
            XCTAssertTrue(waitReady(sock), "round \(round)")
            let started = Date()
            XCTAssertTrue(try DaemonClient.send(request: DaemonRequest(kind: "shutdown"), sockPath: sock).ok)
            XCTAssertEqual(run.done.wait(timeout: .now() + 3), .success, "round \(round)：应答了 shutdown 却没有退出")
            XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "round \(round)")
            XCTAssertNil(run.error)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sock), "round \(round)：socket 没有清掉")
            // 实例锁已释放：下一轮能在同一路径上重新起来。
        }
    }

    func testAcceptedConnectionsAreBlockingDespiteNonBlockingListener() throws {
        // 监听 socket 现在是非阻塞的；accept 出来的连接不能继承这一点——否则一个发请求稍慢的客户端
        // 会被处理线程当成「没有数据」直接断开。
        let dir = try tempDir()
        let sock = dir.appendingPathComponent("d.sock").path
        let run = start(sock: sock, dir: dir)
        XCTAssertTrue(waitReady(sock))
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(sock.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { p in
            for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) } } }
        XCTAssertEqual(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        // 连上之后过一会儿才发请求，而且分两段发。
        Thread.sleep(forTimeInterval: 0.4)
        let first = Array("{\"kind\":".utf8), second = Array("\"ps\"}\n".utf8)
        XCTAssertEqual(write(fd, first, first.count), first.count)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(write(fd, second, second.count), second.count)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count)
        XCTAssertGreaterThan(n, 0, "慢客户端没有得到应答")
        XCTAssertTrue(String(decoding: buffer[0..<max(0, n)], as: UTF8.self).contains("\"ok\":true"))
        XCTAssertTrue(try DaemonClient.send(request: DaemonRequest(kind: "shutdown"), sockPath: sock).ok)
        XCTAssertEqual(run.done.wait(timeout: .now() + 5), .success)
    }

    func testGuardIsExclusiveAndReleasable() throws {
        let dir = try tempDir()
        let sock = dir.appendingPathComponent("d.sock").path
        let a = try DaemonInstanceGuard.acquire(sockPath: sock)
        XCTAssertThrowsError(try DaemonInstanceGuard.acquire(sockPath: sock)) {
            XCTAssertTrue("\($0)".contains("DBX-DAEMON-ALREADY-RUNNING"), "\($0)")
        }
        // 不同路径互不影响。
        let other = try DaemonInstanceGuard.acquire(sockPath: dir.appendingPathComponent("e.sock").path)
        other.release()
        a.release()
        a.release()   // 幂等
        let b = try DaemonInstanceGuard.acquire(sockPath: sock)
        b.release()
        XCTAssertEqual(DaemonInstanceGuard.lockPath(forSocket: sock), sock + ".lock")
    }

    func testConcurrentStartsYieldExactlyOneDaemon() throws {
        let dir = try tempDir()
        let sock = dir.appendingPathComponent("d.sock").path
        let runs = (0..<6).map { _ in start(sock: sock, dir: dir) }
        XCTAssertTrue(waitReady(sock))
        Thread.sleep(forTimeInterval: 0.5)
        let losers = runs.filter { $0.finished }
        XCTAssertEqual(losers.count, 5, "应恰好 5 个被拒")
        XCTAssertTrue(losers.allSatisfy { $0.error?.contains("DBX-DAEMON-ALREADY-RUNNING") ?? false })
        XCTAssertTrue(try DaemonClient.send(request: DaemonRequest(kind: "ps"), sockPath: sock).ok)
    }
}
