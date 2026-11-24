import XCTest
import Foundation
@testable import dbx_poc
@testable import DeskBoxCore
@testable import DeskBoxVZ

/// M24a：daemon 协议决策表（纯函数，不起 VM、不碰文件系统）。
final class DaemonDecisionTests: XCTestCase {

    private let sb = "sb-1"
    private var state: DaemonStateSnapshot {
        DaemonStateSnapshot(sessionDomains: ["sb-1": "work"], ptySandbox: ["pty-1": "sb-1"], draining: false)
    }

    private func req(_ kind: String, _ mutate: (inout DaemonRequest) -> Void = { _ in }) -> DaemonRequest {
        var r = DaemonRequest(kind: kind)
        mutate(&r)
        return r
    }

    private func assertRejected(_ request: DaemonRequest, state: DaemonStateSnapshot,
                                contains needle: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try DaemonDecision.validate(request, state: state), file: file, line: line) { error in
            XCTAssertTrue("\(error)".contains(needle), "期望包含 \(needle)，实际 \(error)", file: file, line: line)
        }
    }

    // MARK: 路由

    func testEveryRouteRoundTripsItsWireName() throws {
        for route in DaemonRoute.allCases {
            XCTAssertEqual(try DaemonDecision.route(route.rawValue), route)
        }
        // 线上协议名锁定：改名即破坏 CLI/GUI 兼容。
        XCTAssertEqual(Set(DaemonRoute.allCases.map(\.rawValue)), [
            "run", "ps", "exec", "execCancel", "stop", "rm", "ptyOpen", "ptyInput", "ptyPoll", "ptyClose",
            "wsSync", "consoleLog", "stats", "suspend", "resume", "restart", "shutdown",
        ])
    }

    func testUnknownKindRejected() {
        assertRejected(req("launchMissiles"), state: state, contains: "unknown kind=launchMissiles")
        assertRejected(req(""), state: state, contains: "unknown kind=")
        // 大小写敏感：不做宽松匹配。
        assertRejected(req("PS"), state: state, contains: "unknown kind=PS")
    }

    // MARK: 必备参数

    func testRunRequiresManifest() throws {
        assertRejected(req("run"), state: state, contains: "run: --manifestPath required")
        XCTAssertEqual(try DaemonDecision.validate(req("run") { $0.manifestPath = "/m.json" }, state: state), .run)
    }

    func testExecRequiresSessionThenArgv() throws {
        assertRejected(req("exec") { $0.argv = ["/bin/echo"] }, state: state, contains: "exec: sandbox not found: nil")
        assertRejected(req("exec") { $0.sandboxId = "nope"; $0.argv = ["/bin/echo"] }, state: state,
                       contains: "exec: sandbox not found: nope")
        assertRejected(req("exec") { $0.sandboxId = self.sb }, state: state, contains: "exec: argv required")
        assertRejected(req("exec") { $0.sandboxId = self.sb; $0.argv = [] }, state: state, contains: "exec: argv required")
        XCTAssertEqual(try DaemonDecision.validate(
            req("exec") { $0.sandboxId = self.sb; $0.argv = ["/bin/echo", "hi"] }, state: state), .exec)
    }

    func testSessionScopedOpsRejectUnknownSandbox() {
        for kind in ["stop", "suspend", "resume", "stats", "consoleLog", "restart", "wsSync", "ptyOpen"] {
            assertRejected(req(kind) { $0.sandboxId = "ghost"; $0.argv = ["/bin/sh"]; $0.workspaceDir = "/w" },
                           state: state, contains: "\(kind): sandbox not found: ghost")
        }
        assertRejected(req("rm"), state: state, contains: "rm: sandboxId required")
        assertRejected(req("rm") { $0.sandboxId = "ghost" }, state: state, contains: "rm: sandbox not found: ghost")
    }

    func testWsSyncRequiresWorkspaceDir() throws {
        assertRejected(req("wsSync") { $0.sandboxId = self.sb }, state: state, contains: "wsSync: workspaceDir required")
        XCTAssertEqual(try DaemonDecision.validate(
            req("wsSync") { $0.sandboxId = self.sb; $0.workspaceDir = "/w" }, state: state), .wsSync)
    }

    // MARK: M23 凭据域（INV-02）

    func testCrossDomainRejectedForEverySessionScopedOp() {
        for kind in ["exec", "stop", "suspend", "resume", "stats", "consoleLog", "restart", "wsSync", "ptyOpen", "rm"] {
            assertRejected(
                req(kind) { $0.sandboxId = self.sb; $0.domain = "personal"; $0.argv = ["/bin/sh"]; $0.workspaceDir = "/w" },
                state: state, contains: "DBX-DOMAIN-SESSION-MISMATCH")
        }
    }

    func testRmHonoursDeclaredDomain() throws {
        // M27：此前 rm 是唯一不比对域的会话级操作（--force 也不例外）。
        assertRejected(req("rm") { $0.sandboxId = self.sb; $0.domain = "personal"; $0.force = true }, state: state,
                       contains: "DBX-DOMAIN-SESSION-MISMATCH: rm")
        XCTAssertEqual(try DaemonDecision.validate(req("rm") { $0.sandboxId = self.sb; $0.domain = "work" }, state: state), .rm)
        XCTAssertEqual(try DaemonDecision.validate(req("rm") { $0.sandboxId = self.sb }, state: state), .rm)
    }

    func testSameDomainAndUndeclaredDomainAccepted() throws {
        XCTAssertEqual(try DaemonDecision.validate(req("stop") { $0.sandboxId = self.sb; $0.domain = "work" }, state: state), .stop)
        XCTAssertEqual(try DaemonDecision.validate(req("stop") { $0.sandboxId = self.sb }, state: state), .stop)
        // 空串等同未声明（与 M23 行为一致）。
        XCTAssertEqual(try DaemonDecision.validate(req("stop") { $0.sandboxId = self.sb; $0.domain = "" }, state: state), .stop)
    }

    func testDomainCheckPrecedesArgumentCheck() {
        // 跨域请求不得通过「缺参」错误探测到沙箱细节：域拒绝优先。
        assertRejected(req("exec") { $0.sandboxId = self.sb; $0.domain = "personal" }, state: state,
                       contains: "DBX-DOMAIN-SESSION-MISMATCH")
    }

    // MARK: PTY

    func testPtyOpenSingleSessionPerSandbox() throws {
        assertRejected(req("ptyOpen") { $0.sandboxId = self.sb; $0.argv = ["/bin/sh"] }, state: state,
                       contains: "sandbox already has an active pty session")
        var free = state
        free.ptySandbox = [:]
        XCTAssertEqual(try DaemonDecision.validate(
            req("ptyOpen") { $0.sandboxId = self.sb; $0.argv = ["/bin/sh"] }, state: free), .ptyOpen)
        assertRejected(req("ptyOpen") { $0.sandboxId = self.sb }, state: free, contains: "ptyOpen: argv required")
    }

    func testAbandonedPtySessionDoesNotBlockReopen() throws {
        // M33：客户端没关就消失的会话（长时间无 poll）不再让终端永久打不开。
        var abandoned = state
        abandoned.stalePtySessions = ["pty-1"]
        XCTAssertEqual(try DaemonDecision.validate(
            req("ptyOpen") { $0.sandboxId = self.sb; $0.argv = ["/bin/sh"] }, state: abandoned), .ptyOpen)
        // 同一沙箱上另有一个活着的会话：仍然拒绝。
        abandoned.ptySandbox["pty-2"] = sb
        assertRejected(req("ptyOpen") { $0.sandboxId = self.sb; $0.argv = ["/bin/sh"] }, state: abandoned,
                       contains: "sandbox already has an active pty session")
        // 别的沙箱上的遗弃标记不影响本沙箱的活会话。
        var other = state
        other.stalePtySessions = ["pty-zzz"]
        assertRejected(req("ptyOpen") { $0.sandboxId = self.sb; $0.argv = ["/bin/sh"] }, state: other,
                       contains: "sandbox already has an active pty session")
        // 被遗弃的会话仍然可以被 close（回收）。
        XCTAssertEqual(try DaemonDecision.validate(req("ptyClose") { $0.ptySessionId = "pty-1" }, state: abandoned), .ptyClose)
    }

    func testPtyEntryStaleness() {
        let now = Date()
        let entry = SandboxDaemon.PtyEntry(session: .init(requestID: UUID()), sandboxId: "sb", lastActivity: now)
        XCTAssertFalse(entry.isStale(now: now))
        XCTAssertFalse(entry.isStale(now: now.addingTimeInterval(SandboxDaemon.PtyEntry.staleAfter)))
        XCTAssertTrue(entry.isStale(now: now.addingTimeInterval(SandboxDaemon.PtyEntry.staleAfter + 0.1)))
        // GUI 每 150ms poll 一次：阈值必须远大于它，不能把正常会话误判为遗弃。
        XCTAssertGreaterThan(SandboxDaemon.PtyEntry.staleAfter, 1.5)
    }

    func testPtySessionLookup() throws {
        for kind in ["ptyInput", "ptyPoll", "ptyClose"] {
            assertRejected(req(kind), state: state, contains: "\(kind): pty session not found")
            assertRejected(req(kind) { $0.ptySessionId = "ghost" }, state: state, contains: "\(kind): pty session not found")
            XCTAssertNoThrow(try DaemonDecision.validate(req(kind) { $0.ptySessionId = "pty-1" }, state: state))
        }
    }

    func testPtyOnDeadSandbox() throws {
        let orphan = DaemonStateSnapshot(sessionDomains: [:], ptySandbox: ["pty-1": "sb-1"], draining: false)
        assertRejected(req("ptyInput") { $0.ptySessionId = "pty-1" }, state: orphan, contains: "sandbox no longer alive")
        assertRejected(req("ptyPoll") { $0.ptySessionId = "pty-1" }, state: orphan, contains: "sandbox no longer alive")
        // close 必须始终可用，否则孤儿会话无法回收。
        XCTAssertEqual(try DaemonDecision.validate(req("ptyClose") { $0.ptySessionId = "pty-1" }, state: orphan), .ptyClose)
    }

    // MARK: draining（M24c）

    func testDrainingRejectsEverythingExceptShutdown() throws {
        var draining = state
        draining.draining = true
        for route in DaemonRoute.allCases where route != .shutdown {
            let r = req(route.rawValue) {
                $0.sandboxId = self.sb; $0.manifestPath = "/m.json"; $0.argv = ["/bin/sh"]
                $0.workspaceDir = "/w"; $0.ptySessionId = "pty-1"
            }
            assertRejected(r, state: draining, contains: "daemon draining")
        }
        XCTAssertEqual(try DaemonDecision.validate(req("shutdown"), state: draining), .shutdown)
    }

    func testUnknownKindStillReportedWhileDraining() {
        var draining = state
        draining.draining = true
        assertRejected(req("bogus"), state: draining, contains: "unknown kind=bogus")
    }

    func testPsAndShutdownNeedNothing() throws {
        let empty = DaemonStateSnapshot()
        XCTAssertEqual(try DaemonDecision.validate(req("ps"), state: empty), .ps)
        XCTAssertEqual(try DaemonDecision.validate(req("shutdown"), state: empty), .shutdown)
    }
}
