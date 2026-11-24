import XCTest
@testable import dbx_poc

/// M41：取消在途的 exec。
final class ExecCancelTests: XCTestCase {
    // MARK: ExecTracker

    func testNothingInFlightInitially() {
        let tracker = ExecTracker()
        XCTAssertNil(tracker.current)
    }

    func testBeginEndLifecycle() {
        let tracker = ExecTracker()
        let a = tracker.begin()
        XCTAssertEqual(tracker.current, a)
        XCTAssertEqual(tracker.outcome(of: a), .running)
        tracker.end(a, cancelled: true)
        XCTAssertNil(tracker.current)
        XCTAssertEqual(tracker.outcome(of: a), .finished(cancelled: true))
        let b = tracker.begin()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(tracker.outcome(of: b), .running)
        // 旧令牌的结论不受新 exec 影响（取消方问的是「我取消的那一条」）。
        XCTAssertEqual(tracker.outcome(of: a), .finished(cancelled: true))
        tracker.end(b, cancelled: false)
        XCTAssertEqual(tracker.outcome(of: b), .finished(cancelled: false))
    }

    func testEndingAStaleTokenDoesNotClearTheCurrentOne() {
        let tracker = ExecTracker()
        let a = tracker.begin()
        tracker.end(a, cancelled: false)
        let b = tracker.begin()
        tracker.end(a, cancelled: false)      // 重复 / 迟到的 end
        XCTAssertEqual(tracker.current, b)
    }

    func testForgottenTokensCountAsFinishedNotCancelled() {
        let tracker = ExecTracker()
        let first = tracker.begin()
        tracker.end(first, cancelled: true)
        for _ in 0..<40 { let t = tracker.begin(); tracker.end(t, cancelled: false) }
        XCTAssertEqual(tracker.outcome(of: first), .finished(cancelled: false), "只记最近若干条")
        XCTAssertEqual(tracker.outcome(of: 9_999), .finished(cancelled: false), "从未见过的令牌不算在途")
    }

    func testConcurrentUse() {
        let tracker = ExecTracker()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let token = tracker.begin()
            _ = tracker.outcome(of: token)
            tracker.end(token, cancelled: i % 2 == 0)
        }
        XCTAssertNil(tracker.current)
    }

    // MARK: 结论

    func testVerdictIsBasedOnWhatActuallyHappened() {
        XCTAssertEqual(ExecCancelVerdict.classify(hadInFlight: false, outcomeAfterWait: .finished(cancelled: false)), .notRunning)
        XCTAssertEqual(ExecCancelVerdict.classify(hadInFlight: true, outcomeAfterWait: .finished(cancelled: true)), .cancelled)
        XCTAssertEqual(ExecCancelVerdict.classify(hadInFlight: true, outcomeAfterWait: .finished(cancelled: false)), .alreadyFinished)
        XCTAssertEqual(ExecCancelVerdict.classify(hadInFlight: true, outcomeAfterWait: .running), .unsupported)
    }

    func testMessagesAndRefusals() {
        XCTAssertEqual(ExecCancelVerdict.cancelled.message, "exec cancelled")
        XCTAssertNil(ExecCancelVerdict.cancelled.refusal)
        XCTAssertEqual(ExecCancelVerdict.alreadyFinished.message, "exec already finished")
        XCTAssertNil(ExecCancelVerdict.alreadyFinished.refusal)
        XCTAssertNil(ExecCancelVerdict.unsupported.message)
        XCTAssertTrue(ExecCancelVerdict.unsupported.refusal!.hasPrefix("DBX-EXEC-CANCEL-UNSUPPORTED: "))
        XCTAssertTrue(ExecCancelVerdict.unsupported.refusal!.contains("rm --force"))
        XCTAssertTrue(ExecCancelVerdict.notRunning.refusal!.hasPrefix("DBX-EXEC-NOT-RUNNING: "))
    }

    // MARK: 路由 / CLI

    func testDecisionRequiresAnExistingSessionAndMatchingDomain() throws {
        var state = DaemonStateSnapshot()
        state.sessionDomains = ["SB": "work"]
        var request = DaemonRequest(kind: "execCancel")
        XCTAssertThrowsError(try DaemonDecision.validate(request, state: state))     // 缺 sandboxId
        request.sandboxId = "nope"
        XCTAssertThrowsError(try DaemonDecision.validate(request, state: state)) { XCTAssertTrue("\($0)".contains("sandbox not found"), "\($0)") }
        request.sandboxId = "SB"
        XCTAssertEqual(try DaemonDecision.validate(request, state: state), .execCancel)
        request.domain = "personal"
        XCTAssertThrowsError(try DaemonDecision.validate(request, state: state)) { XCTAssertTrue("\($0)".contains("DBX-DOMAIN-SESSION-MISMATCH"), "\($0)") }
        request.domain = "work"
        state.draining = true
        XCTAssertThrowsError(try DaemonDecision.validate(request, state: state)) { XCTAssertTrue("\($0)".contains("draining"), "\($0)") }
    }

    func testCLISpec() throws {
        let inv = try DaemonCLI.single(["SB", "--domain", "work", "--daemon-sock", "/s"], spec: DaemonCLISpecs.execCancel, kind: "execCancel")
        XCTAssertEqual(inv.request.kind, "execCancel")
        XCTAssertEqual(inv.request.sandboxId, "SB")
        XCTAssertEqual(inv.request.domain, "work")
        XCTAssertEqual(inv.sock, "/s")
        XCTAssertThrowsError(try DaemonCLI.single([], spec: DaemonCLISpecs.execCancel, kind: "execCancel"))
        XCTAssertThrowsError(try DaemonCLI.single(["SB", "--force"], spec: DaemonCLISpecs.execCancel, kind: "execCancel")) {
            XCTAssertTrue("\($0)".contains("unknown option"), "\($0)")
        }
        XCTAssertTrue(DaemonCLISpecs.all.contains { $0.command == "exec-cancel" })
    }

    func testCancelledExitStatus() {
        XCTAssertEqual(ExecExitStatus.processStatus(forGuestExitCode: -3), 253, "被取消（非本进程的 Ctrl-C）")
        XCTAssertEqual(ExecExitStatus.processStatus(forGuestExitCode: 128 + 2), 130, "被自己的 Ctrl-C 取消")
    }
}
