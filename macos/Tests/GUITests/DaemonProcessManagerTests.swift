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

    // MARK: 核心回归：GUI 不得删除 socket 文件

    func testRefreshNeverDeletesSocketOfBusyDaemon() throws {
        // daemon 活着但 2s 内不回话（旧实现：探活超时 → unlink 它的 socket → daemon 变孤儿）。
        let dir = try tempDir()
        let sock = dir.appendingPathComponent("d.sock").path
        let daemon = FakeDaemon(path: sock, reply: nil)
        addTeardownBlock { daemon.stop() }

        let manager = DaemonProcessManager(sockPath: sock)
        manager.refresh()
        spinMainRunLoop(until: { manager.status == .stopped }, timeout: 6)
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
        spinMainRunLoop(until: { manager.status == .stopped }, timeout: 6)
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
        spinMainRunLoop(until: { manager.status == .connected }, timeout: 5)
        XCTAssertEqual(manager.status, .connected)
    }

    func testRefreshWithNoSocketAtAll() throws {
        let dir = try tempDir()
        let manager = DaemonProcessManager(sockPath: dir.appendingPathComponent("absent.sock").path)
        manager.refresh()
        spinMainRunLoop(until: { manager.status == .stopped }, timeout: 5)
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
        spinMainRunLoop(until: { !daemon.requests.isEmpty }, timeout: 2)
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
