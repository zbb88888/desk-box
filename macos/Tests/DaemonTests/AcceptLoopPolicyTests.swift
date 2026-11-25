import XCTest
import Darwin
@testable import dbx_poc

/// M49：accept 循环的异常处理。
final class AcceptLoopPolicyTests: XCTestCase {
    func testPollEvents() {
        XCTAssertEqual(AcceptLoopPolicy.action(revents: Int16(POLLIN)), .accept)
        XCTAssertEqual(AcceptLoopPolicy.action(revents: Int16(POLLIN | POLLHUP)), .accept, "有连接可取时先取")
        XCTAssertEqual(AcceptLoopPolicy.action(revents: Int16(POLLNVAL)), .listenerDead)
        XCTAssertEqual(AcceptLoopPolicy.action(revents: Int16(POLLNVAL | POLLIN)), .listenerDead)
        XCTAssertEqual(AcceptLoopPolicy.action(revents: Int16(POLLERR)), .listenerDead)
        XCTAssertEqual(AcceptLoopPolicy.action(revents: Int16(POLLHUP)), .listenerDead)
    }

    func testAcceptErrors() {
        for code in [EBADF, ENOTSOCK, EINVAL, EOPNOTSUPP] {
            XCTAssertEqual(AcceptLoopPolicy.action(acceptErrno: code), .listenerDead, "\(code)")
        }
        for code in [EMFILE, ENFILE, ENOMEM, ENOBUFS] {
            XCTAssertEqual(AcceptLoopPolicy.action(acceptErrno: code), .wait, "\(code)")
        }
        for code in [EAGAIN, EWOULDBLOCK, ECONNABORTED, EINTR, EPROTO] {
            XCTAssertEqual(AcceptLoopPolicy.action(acceptErrno: code), .accept, "\(code)")
        }
    }

    /// 真实的失效场景：有人把 daemon 的监听描述符关掉了。daemon 必须停下来，而不是空转。
    func testDaemonStopsWhenItsListeningSocketIsClosedUnderIt() throws {
        let dir = URL(fileURLWithPath: "/tmp/dbxa-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let sock = dir.appendingPathComponent("d.sock").path
        let daemon = SandboxDaemon(sockPath: sock, supportRoot: dir)
        let done = DispatchSemaphore(value: 0)
        Thread { _ = try? daemon.serveLoop(); done.signal() }.start()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, (try? DaemonClient.send(request: DaemonRequest(kind: "ps"), sockPath: sock)) == nil { usleep(10_000) }
        let listener = daemon.listeningDescriptorForTesting
        XCTAssertGreaterThanOrEqual(listener, 0)
        XCTAssertEqual(close(listener), 0)      // 模拟「别处的一次重复 close 关掉了它」
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success, "监听 socket 失效后 daemon 没有停下来（旧实现会以 100% CPU 空转）")
    }
}
