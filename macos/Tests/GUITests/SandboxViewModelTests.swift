import XCTest
import Foundation
@testable import DeskBoxGUI

/// M32：按钮背后的操作逻辑（视图模型），对着假 daemon 验证。
final class SandboxViewModelTests: XCTestCase {

    private func tempSock() throws -> String {
        let dir = URL(fileURLWithPath: "/tmp/dbxvm-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        }
        return dir.appendingPathComponent("d.sock").path
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Result<DaemonResponse, Error>?
        var value: Result<DaemonResponse, Error>? { lock.lock(); defer { lock.unlock() }; return _value }
        func set(_ v: Result<DaemonResponse, Error>) { lock.lock(); _value = v; lock.unlock() }
    }

    /// 等 completion 被调用（它在主队列上回调）。
    private func waitFor(_ flag: Flag, timeout: TimeInterval = 5) -> Result<DaemonResponse, Error>? {
        spinMainRunLoop(until: { flag.value != nil }, timeout: timeout)
        return flag.value
    }

    private func make(reply: String?) throws -> (SandboxViewModel, DaemonProcessManager, FakeDaemon) {
        let sock = try tempSock()
        let daemon = FakeDaemon(path: sock, reply: reply)
        addTeardownBlock { daemon.stop() }
        let manager = DaemonProcessManager(sockPath: sock)
        manager.status = .connected
        return (SandboxViewModel(client: DaemonSocketClient(sockPath: sock)), manager, daemon)
    }

    // MARK: 请求构造

    func testRunRequest() {
        let request = SandboxViewModel.runRequest(manifestPath: "/g/manifest.json")
        XCTAssertEqual(request.kind, "run")
        XCTAssertEqual(request.manifestPath, "/g/manifest.json")
        XCTAssertNil(request.sandboxId)
    }

    func testBootBoundRequestsGetALongerClientTimeout() {
        // daemon 侧引导等待上限 90s；客户端必须等得更久，否则界面先超时而 daemon 随后成功。
        for kind in ["run", "resume", "restart"] {
            XCTAssertGreaterThan(SandboxViewModel.timeoutSeconds(forKind: kind), 90, kind)
        }
        XCTAssertEqual(SandboxViewModel.timeoutSeconds(forKind: "ps"), 30)
        XCTAssertEqual(SandboxViewModel.timeoutSeconds(forKind: "rm"), 30)
        XCTAssertGreaterThanOrEqual(SandboxViewModel.timeoutSeconds(forKind: "exec"), 60)
    }

    // MARK: submit

    func testSubmitSuccessCallsCompletionOnMainAfterRefresh() throws {
        let (vm, manager, daemon) = try make(reply: #"{"ok":true,"sandboxId":"SB","state":"running","sandboxes":[{"sandboxId":"SB","state":"running","bootedAtUtc":"t","manifestPath":"/m"}]}"#)
        let done = Flag()
        vm.submit(SandboxViewModel.runRequest(manifestPath: "/m"), label: "run started", daemonManager: manager) { result in
            XCTAssertTrue(Thread.isMainThread)
            done.set(result)
        }
        guard case .success(let response)? = waitFor(done) else { return XCTFail("\(String(describing: done.value))") }
        XCTAssertEqual(response.sandboxId, "SB")
        // completion 在列表刷新之后：调用方此时就能看到新状态。
        XCTAssertEqual(vm.sandboxes.map(\.sandboxId), ["SB"])
        XCTAssertEqual(manager.status, .connected)
        XCTAssertTrue(daemon.requests.contains { $0.contains(#""kind":"run""#) })
        XCTAssertTrue(daemon.requests.contains { $0.contains(#""kind":"ps""#) }, "成功后应刷新列表")
    }

    func testRejectionIsPresentedAndDoesNotMarkDaemonStopped() throws {
        let (vm, manager, _) = try make(reply: #"{"ok":false,"error":"request rejected (kind=resume): DBX-RESUME-HOST-LOCKED: locked | underlying: x"}"#)
        let done = Flag()
        let request = try XCTUnwrap(SandboxRowActions.request(for: .resume, sandboxId: "SB"))
        vm.submit(request, label: "resume", daemonManager: manager) { done.set($0) }
        guard case .failure(let error)? = waitFor(done) else { return XCTFail("应失败") }
        XCTAssertEqual(DaemonErrorPresenter.present(error).code, "DBX-RESUME-HOST-LOCKED")
        XCTAssertTrue(vm.execOutput.contains("无法恢复：Mac 处于锁屏状态"), vm.execOutput)
        XCTAssertEqual(manager.status, .connected, "被拒绝说明 daemon 活着")
    }

    func testUnreachableDaemonIsMarkedStopped() throws {
        let sock = try tempSock()   // 没有任何人监听
        let manager = DaemonProcessManager(sockPath: sock)
        manager.status = .connected
        let vm = SandboxViewModel(client: DaemonSocketClient(sockPath: sock))
        let done = Flag()
        vm.submit(DaemonRequest(kind: "stop"), label: "stop", daemonManager: manager) { done.set($0) }
        guard case .failure? = waitFor(done) else { return XCTFail("应失败") }
        XCTAssertEqual(manager.status, .stopped)
        XCTAssertTrue(vm.execOutput.contains("无法连接 daemon"), vm.execOutput)
    }

    // MARK: exec

    func testExecSendsParsedArgvAndShowsOutput() throws {
        let (vm, manager, daemon) = try make(reply: #"{"ok":true,"exitCode":0,"stdout":"a b\n","stderr":""}"#)
        let done = Flag()
        vm.exec(sandboxId: "SB", commandLine: "/bin/sh -c 'echo a b'", daemonManager: manager) { done.set($0) }
        XCTAssertEqual(vm.execOutput, "running…")
        guard case .success? = waitFor(done) else { return XCTFail("应成功") }
        XCTAssertTrue(vm.execOutput.hasPrefix("exit=0\n---stdout---\na b\n"), vm.execOutput)
        let line = try XCTUnwrap(daemon.requests.first { $0.contains(#""kind":"exec""#) })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["argv"] as? [String], ["/bin/sh", "-c", "echo a b"])
        XCTAssertEqual(object["sandboxId"] as? String, "SB")
    }

    func testExecWithMalformedCommandLineNeverReachesDaemon() throws {
        let (vm, manager, daemon) = try make(reply: #"{"ok":true}"#)
        let done = Flag()
        vm.exec(sandboxId: "SB", commandLine: "/bin/echo 'oops", daemonManager: manager) { done.set($0) }
        guard case .failure? = waitFor(done, timeout: 1) else { return XCTFail("应在本地失败") }
        XCTAssertTrue(vm.execOutput.contains("命令行无法解析"), vm.execOutput)
        XCTAssertTrue(vm.execOutput.contains("单引号没有闭合"), vm.execOutput)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(daemon.requests.isEmpty, "非法命令行不应发给 daemon：\(daemon.requests)")
    }

    func testExecWithEmptyCommandLine() throws {
        let (vm, manager, daemon) = try make(reply: #"{"ok":true}"#)
        let done = Flag()
        vm.exec(sandboxId: "SB", commandLine: "   ", daemonManager: manager) { done.set($0) }
        guard case .failure? = waitFor(done, timeout: 1) else { return XCTFail("应在本地失败") }
        XCTAssertEqual(vm.execOutput, "argv empty")
        XCTAssertTrue(daemon.requests.isEmpty)
    }

    func testExecRejectionKeepsDaemonConnected() throws {
        let (vm, manager, _) = try make(reply: #"{"ok":false,"error":"request rejected (kind=exec): DBX-OP-CANCELLED: exec aborted (sandbox is being removed)"}"#)
        let done = Flag()
        vm.exec(sandboxId: "SB", commandLine: "/bin/echo x", daemonManager: manager) { done.set($0) }
        guard case .failure? = waitFor(done) else { return XCTFail("应失败") }
        XCTAssertTrue(vm.execOutput.contains("操作已取消"), vm.execOutput)
        XCTAssertEqual(manager.status, .connected)
    }

    func testRefreshCompletionRunsAfterListUpdate() throws {
        let (vm, _, _) = try make(reply: #"{"ok":true,"sandboxes":[{"sandboxId":"A","state":"suspended","bootedAtUtc":"t","manifestPath":"/m"}]}"#)
        let exp = expectation(description: "refresh")
        vm.refresh {
            XCTAssertEqual(vm.sandboxes.first?.state, "suspended")
            XCTAssertEqual(SandboxRowActions.available(forState: vm.sandboxes.first?.state ?? ""), [.console, .resume, .rm])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }
}
