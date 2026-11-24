import XCTest
import Darwin
@testable import dbx_poc

/// M42：exec 客户端断开的检测。
final class ClientDisconnectWatcherTests: XCTestCase {
    private func pair() -> (server: Int32, client: Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (fds[0], fds[1])
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func hit() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func waitFor(_ flag: Flag, _ expected: Int, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if flag.value == expected { return true }; usleep(10_000) }
        return flag.value == expected
    }

    func testFullCloseFiresOnce() {
        let (server, client) = pair()
        defer { close(server) }
        let flag = Flag()
        let watcher = ClientDisconnectWatcher(fd: server)
        watcher.start { flag.hit() }
        usleep(150_000)
        XCTAssertEqual(flag.value, 0, "对端还在时不触发")
        close(client)
        XCTAssertTrue(waitFor(flag, 1, seconds: 2), "对端关闭后应触发")
        usleep(300_000)
        XCTAssertEqual(flag.value, 1, "只触发一次")
        watcher.stop()
    }

    func testHalfCloseIsNotADisconnect() {
        // 客户端发完请求后 shutdown(SHUT_WR)（nc 的常见用法）：它还在等应答。
        let (server, client) = pair()
        defer { close(server); close(client) }
        let flag = Flag()
        let watcher = ClientDisconnectWatcher(fd: server)
        watcher.start { flag.hit() }
        XCTAssertEqual(shutdown(client, SHUT_WR), 0)
        usleep(500_000)
        XCTAssertEqual(flag.value, 0, "半关闭不是断开")
        watcher.stop()
        // 探测字节是一个空格，随后的应答仍然能被对端完整读到并解析。
        let reply = Array("{\"ok\":true}\n".utf8)
        XCTAssertEqual(write(server, reply, reply.count), reply.count)
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = read(client, &buffer, buffer.count)
        XCTAssertGreaterThan(n, 0)
        let text = String(decoding: buffer[0..<max(0, n)], as: UTF8.self)
        XCTAssertEqual(text, " {\"ok\":true}\n")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(text.utf8)), "前导空格不影响 JSON 解析")
    }

    func testQuietConnectionNeverFiresAndStopIsPrompt() {
        let (server, client) = pair()
        defer { close(server); close(client) }
        let flag = Flag()
        let watcher = ClientDisconnectWatcher(fd: server)
        watcher.start { flag.hit() }
        usleep(400_000)
        let started = Date()
        watcher.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "stop 应在一个轮询周期内返回")
        XCTAssertEqual(flag.value, 0)
        // stop 之后对端再关闭也不会触发。
        close(client)
        usleep(300_000)
        XCTAssertEqual(flag.value, 0)
    }

    func testExtraDataFromClientIsNotADisconnect() {
        let (server, client) = pair()
        defer { close(server); close(client) }
        let flag = Flag()
        let watcher = ClientDisconnectWatcher(fd: server)
        watcher.start { flag.hit() }
        XCTAssertEqual(write(client, "x", 1), 1)
        usleep(400_000)
        XCTAssertEqual(flag.value, 0)
        watcher.stop()
    }

    func testStopWithoutStartDoesNotBlock() {
        let (server, client) = pair()
        defer { close(server); close(client) }
        ClientDisconnectWatcher(fd: server).stop()
    }

    func testProbe() {
        let (server, client) = pair()
        ClientDisconnectWatcher.prepare(server)
        XCTAssertEqual(ClientDisconnectWatcher.probe(server), .stillConnected)
        close(client)
        XCTAssertEqual(ClientDisconnectWatcher.probe(server), .disconnected)
        close(server)
    }

    // MARK: ExecAbandonment

    func testAbandonedBeforeItsTurnMeansDoNotRun() {
        let a = ExecAbandonment()
        XCTAssertNil(a.markAbandoned(), "还没开始执行：没有需要取消的令牌")
        XCTAssertTrue(a.isAbandoned)
        XCTAssertFalse(a.begin(token: 7), "客户端已经走了：轮到它时不执行")
    }

    func testAbandonedWhileRunningYieldsTheTokenToCancel() {
        let a = ExecAbandonment()
        XCTAssertTrue(a.begin(token: 7))
        XCTAssertFalse(a.isAbandoned)
        XCTAssertEqual(a.markAbandoned(), 7)
        XCTAssertTrue(a.isAbandoned)
    }

    func testAbandonmentRaceHasExactlyOneOutcome() {
        // 断开与「轮到它」并发：要么不执行，要么拿到令牌去取消——不会两头落空。
        for _ in 0..<200 {
            let a = ExecAbandonment()
            let results = Flag()
            let group = DispatchGroup()
            var began = false
            var token: UInt64?
            let lock = NSLock()
            group.enter(); DispatchQueue.global().async { let b = a.begin(token: 1); lock.lock(); began = b; lock.unlock(); group.leave() }
            group.enter(); DispatchQueue.global().async { let t = a.markAbandoned(); lock.lock(); token = t; lock.unlock(); group.leave() }
            group.wait()
            _ = results
            XCTAssertTrue(a.isAbandoned)
            XCTAssertEqual(began, token != nil, "began=\(began) token=\(String(describing: token))")
        }
    }
}
