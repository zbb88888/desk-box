import XCTest
@testable import dbx_poc

/// M37：workload 运行之后的再次同步。
final class WorkspaceResyncPolicyTests: XCTestCase {
    private func refusal(_ started: Bool, _ version: Int?, _ allow: Bool) -> String? {
        WorkspaceResyncPolicy.refusal(workloadStarted: started, guestReceiverVersion: version, allowUnsafe: allow)
    }

    func testFirstSyncIsAlwaysAllowed() {
        // workload 还没运行过：/workspace 里没有不可信代码放的东西，任何 guest 版本都安全。
        for version in [nil, 1, 2, 99] as [Int?] {
            XCTAssertNil(refusal(false, version, false))
        }
    }

    func testResyncAfterWorkloadRequiresFixedReceiver() {
        for old in [nil, 0, 1, -5] as [Int?] {
            let message = refusal(true, old, false)
            XCTAssertNotNil(message, "version=\(String(describing: old))")
            XCTAssertTrue(message!.hasPrefix("DBX-WS-RESYNC-UNSAFE: "), message!)
            XCTAssertTrue(message!.contains("--allow-unsafe-resync"), message!)
        }
        XCTAssertNil(refusal(true, 2, false))
        XCTAssertNil(refusal(true, 3, false))
    }

    func testUnknownVersionIsTreatedAsOld() {
        // stats 查询失败 / 旧 guest 不上报 → nil → 拒绝（fail-closed）。
        XCTAssertNotNil(refusal(true, nil, false))
    }

    func testExplicitOverride() {
        XCTAssertNil(refusal(true, 1, true))
        XCTAssertNil(refusal(true, nil, true))
    }

    func testCLIOnlySendsTheOverrideWhenAsked() throws {
        let plain = try DaemonCLI.wsSync(["SB", "/tmp/ws", "--daemon-sock", "/s"])
        XCTAssertEqual(plain.request.kind, "wsSync")
        XCTAssertEqual(plain.request.sandboxId, "SB")
        XCTAssertEqual(plain.request.workspaceDir, "/tmp/ws")
        XCTAssertNil(plain.request.allowUnsafeResync, "缺省不得带上放行标记")
        XCTAssertEqual(plain.sock, "/s")
        let forced = try DaemonCLI.wsSync(["--allow-unsafe-resync", "SB", "/tmp/a/../ws", "--domain", "work"])
        XCTAssertEqual(forced.request.allowUnsafeResync, true)
        XCTAssertEqual(forced.request.workspaceDir, "/tmp/ws", "路径被规范化")
        XCTAssertEqual(forced.request.domain, "work")
        XCTAssertThrowsError(try DaemonCLI.wsSync(["SB"])) { XCTAssertTrue("\($0)".contains("workspace directory required"), "\($0)") }
        XCTAssertThrowsError(try DaemonCLI.wsSync(["SB", "/w", "--allow-unsafe"])) { XCTAssertTrue("\($0)".contains("unknown option"), "\($0)") }
        // 线上 JSON：缺省请求里不出现 allowUnsafeResync 字段。
        let json = String(decoding: try JSONEncoder().encode(plain.request), as: UTF8.self)
        XCTAssertFalse(json.contains("allowUnsafeResync"), json)
    }

    func testWorkloadFlagIsStickyAndThreadSafe() {
        let session = WorkloadFlagProbe()
        XCTAssertFalse(session.started)
        DispatchQueue.concurrentPerform(iterations: 50) { _ in session.mark() }
        XCTAssertTrue(session.started)
    }
}

/// SandboxSession 需要一个真实的 VZRuntime 才能构造；这里只验证它用的那段加锁逻辑的形状。
private final class WorkloadFlagProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func mark() { lock.lock(); value = true; lock.unlock() }
}
