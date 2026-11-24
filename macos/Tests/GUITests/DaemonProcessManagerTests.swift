import XCTest
import Darwin
import Foundation
@testable import DeskBoxGUI

/// M28：GUI 的 daemon 客户端 / 进程管理（不起界面、不起真 daemon）。
final class DaemonProcessManagerTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/dbxgui-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        }
        return dir
    }

    /// 假 daemon：监听 UNIX socket；`reply` 为 nil 时 accept 后一言不发（模拟「活着但正忙」）。
    private final class FakeDaemon: @unchecked Sendable {
        let fd: Int32
        private let lock = NSLock()
        private var clients: [Int32] = []
        private var stopped = false
        private(set) var requests: [String] = []

        init(path: String, reply: String?) {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { p in
                for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) } } }
            let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            precondition(rc == 0, "bind errno=\(errno)")
            listen(fd, 16)
            Thread { [self] in
                while true {
                    let c = accept(fd, nil, nil)
                    if c < 0 { break }
                    lock.lock(); clients.append(c); let done = stopped; lock.unlock()
                    if done { break }
                    guard let reply else { continue }   // 沉默：保持连接不回话
                    var buf = [UInt8](repeating: 0, count: 4096)
                    let n = read(c, &buf, buf.count)
                    if n > 0 { lock.lock(); requests.append(String(decoding: buf[0..<n], as: UTF8.self)); lock.unlock() }
                    let out = Array((reply + "\n").utf8)
                    _ = out.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
                }
            }.start()
        }

        func stop() {
            lock.lock(); stopped = true; let cs = clients; clients = []; lock.unlock()
            for c in cs { close(c) }
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    /// 让主队列上的回调得以执行，直到条件成立或超时。
    private func spin(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: 核心回归：GUI 不得删除 socket 文件

    func testRefreshNeverDeletesSocketOfBusyDaemon() throws {
        // daemon 活着但 2s 内不回话（旧实现：探活超时 → unlink 它的 socket → daemon 变孤儿）。
        let dir = try tempDir()
        let sock = dir.appendingPathComponent("d.sock").path
        let daemon = FakeDaemon(path: sock, reply: nil)
        addTeardownBlock { daemon.stop() }

        let manager = DaemonProcessManager(sockPath: sock)
        manager.refresh()
        spin(until: { manager.status == .stopped }, timeout: 6)
        XCTAssertEqual(manager.status, .stopped, "探活超时应显示为 stopped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sock), "GUI 删除了一个正在监听的 daemon 的 socket")
    }

    func testRefreshLeavesStaleSocketForDaemonToTakeOver() throws {
        // 崩溃残留：文件在、无人监听。清理它是 daemon 启动时的职责（带探活），不是 GUI 的。
        let dir = try tempDir()
        let sock = dir.appendingPathComponent("d.sock").path
        let dead = FakeDaemon(path: sock, reply: nil)
        close(dead.fd)   // 不 unlink：留下 stale socket 文件
        XCTAssertTrue(FileManager.default.fileExists(atPath: sock))

        let manager = DaemonProcessManager(sockPath: sock)
        manager.refresh()
        spin(until: { manager.status == .stopped }, timeout: 6)
        XCTAssertEqual(manager.status, .stopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sock), "GUI 不应触碰 socket 文件")

        manager.noteDiedIfNeeded()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sock))
    }

    func testRefreshReportsConnectedForResponsiveDaemon() throws {
        let dir = try tempDir()
        let sock = dir.appendingPathComponent("d.sock").path
        let daemon = FakeDaemon(path: sock, reply: #"{"ok":true,"sandboxes":[]}"#)
        addTeardownBlock { daemon.stop() }

        let manager = DaemonProcessManager(sockPath: sock)
        manager.refresh()
        spin(until: { manager.status == .connected }, timeout: 5)
        XCTAssertEqual(manager.status, .connected)
    }

    func testRefreshWithNoSocketAtAll() throws {
        let dir = try tempDir()
        let manager = DaemonProcessManager(sockPath: dir.appendingPathComponent("absent.sock").path)
        manager.refresh()
        spin(until: { manager.status == .stopped }, timeout: 5)
        XCTAssertEqual(manager.status, .stopped)
    }

    // MARK: 客户端

    func testClientDecodesRejectionAsRejectedNotUnreachable() throws {
        let dir = try tempDir()
        let sock = dir.appendingPathComponent("d.sock").path
        let daemon = FakeDaemon(path: sock, reply: #"{"ok":false,"error":"request rejected (kind=run): DBX-BOOT-TIMEOUT: x"}"#)
        addTeardownBlock { daemon.stop() }

        let client = DaemonSocketClient(sockPath: sock)
        XCTAssertThrowsError(try client.send(DaemonRequest(kind: "run"), timeoutSec: 3)) { error in
            guard case DaemonClientError.rejected(let message)? = error as? DaemonClientError else {
                return XCTFail("期望 .rejected，实际 \(error)")
            }
            XCTAssertTrue(message.contains("DBX-BOOT-TIMEOUT"))
            XCTAssertFalse((error as! DaemonClientError).indicatesDaemonUnreachable)
            XCTAssertEqual(DaemonErrorPresenter.present(error).title, "沙箱引导超时")
        }
        XCTAssertFalse(client.probing(), "ok=false 的响应不算探活成功")
    }

    func testClientReportsConnectFailureAsUnreachable() throws {
        let dir = try tempDir()
        let client = DaemonSocketClient(sockPath: dir.appendingPathComponent("absent.sock").path)
        XCTAssertThrowsError(try client.send(DaemonRequest(kind: "ps"), timeoutSec: 1)) { error in
            XCTAssertTrue((error as? DaemonClientError)?.indicatesDaemonUnreachable ?? false, "\(error)")
        }
    }

    func testClientSendsOneJsonLine() throws {
        let dir = try tempDir()
        let sock = dir.appendingPathComponent("d.sock").path
        let daemon = FakeDaemon(path: sock, reply: #"{"ok":true,"sandboxId":"SB","state":"running"}"#)
        addTeardownBlock { daemon.stop() }
        var request = DaemonRequest(kind: "exec")
        request.sandboxId = "SB"
        request.argv = ["/bin/echo", "hi there"]
        let response = try DaemonSocketClient(sockPath: sock).send(request, timeoutSec: 3)
        XCTAssertEqual(response.sandboxId, "SB")
        spin(until: { !daemon.requests.isEmpty }, timeout: 2)
        let line = try XCTUnwrap(daemon.requests.first)
        XCTAssertTrue(line.hasSuffix("\n") && line.filter({ $0 == "\n" }).count == 1, "必须恰好一行 JSON")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "exec")
        XCTAssertEqual(object["argv"] as? [String], ["/bin/echo", "hi there"])
    }

    func testSocketPathTooLongIsRejectedBeforeConnecting() {
        let client = DaemonSocketClient(sockPath: "/tmp/" + String(repeating: "x", count: 200))
        XCTAssertThrowsError(try client.send(DaemonRequest(kind: "ps"), timeoutSec: 1))
    }
}
