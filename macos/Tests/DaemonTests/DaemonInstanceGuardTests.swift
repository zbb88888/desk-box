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
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
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
