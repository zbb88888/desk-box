import XCTest
@testable import DeskBoxCore

/// M28：suspend 失败回滚（suspending → running）的状态机契约。
final class SuspendRollbackContractTests: XCTestCase {
    private func runningMachine() throws -> (LifecycleMachine, BootContext, BootstrapProof) {
        let sandbox = SandboxID.new()
        let boot = BootContext(sandboxID: sandbox, protocolMajor: ControlChannelProtocol.currentMajor,
                               guestManifestDigest: "digest")
        let proof = BootstrapProof(sandboxID: sandbox, bootID: boot.bootID, bootNonce: boot.bootNonce,
                                   protocolMajor: ControlChannelProtocol.currentMajor,
                                   guestManifestDigest: "digest", sessionID: .new())
        var machine = LifecycleMachine(sandboxID: sandbox, boot: boot, correlationID: UUID())
        try machine.transition(to: .running, reason: .bootstrapProofAccepted, proof: proof)
        return (machine, boot, proof)
    }

    func testRollbackReturnsToRunningWithSameBootProof() throws {
        var (machine, _, proof) = try runningMachine()
        try machine.transition(to: .suspending, reason: .lifecycleStopRequested)
        try machine.transition(to: .running, reason: .lifecycleSuspendAborted, proof: proof)
        XCTAssertEqual(machine.state, .running)
        XCTAssertEqual(machine.history.last?.from, .suspending)
        XCTAssertEqual(machine.history.last?.reason, .lifecycleSuspendAborted)
        // 回滚之后是一台正常的 running 沙箱：可以再次 suspend。
        try machine.transition(to: .suspending, reason: .lifecycleStopRequested)
        try machine.transition(to: .suspended, reason: .lifecycleStopped)
    }

    func testRollbackStillRequiresProof() throws {
        var (machine, _, _) = try runningMachine()
        try machine.transition(to: .suspending, reason: .lifecycleStopRequested)
        XCTAssertThrowsError(try machine.transition(to: .running, reason: .lifecycleSuspendAborted)) {
            XCTAssertEqual(($0 as? SandboxFailure)?.reason, .bootstrapProofMissing)
        }
        XCTAssertEqual(machine.state, .suspending, "被拒的转换不得改变状态")
    }

    func testRollbackRejectsProofFromAnotherBoot() throws {
        var (machine, boot, _) = try runningMachine()
        try machine.transition(to: .suspending, reason: .lifecycleStopRequested)
        let foreign = BootstrapProof(sandboxID: boot.sandboxID, bootID: .new(), bootNonce: UUID(),
                                     protocolMajor: ControlChannelProtocol.currentMajor,
                                     guestManifestDigest: "digest", sessionID: .new())
        XCTAssertThrowsError(try machine.transition(to: .running, reason: .lifecycleSuspendAborted, proof: foreign)) {
            XCTAssertEqual(($0 as? SandboxFailure)?.reason, .bootstrapProofMismatch)
        }
        XCTAssertEqual(machine.state, .suspending)
    }

    func testSuspendedCannotJumpStraightToRunning() throws {
        // 新增的边只对 suspending 开放：已落盘的快照必须经 resuming（VZ restore + 新握手）。
        var (machine, _, proof) = try runningMachine()
        try machine.transition(to: .suspending, reason: .lifecycleStopRequested)
        try machine.transition(to: .suspended, reason: .lifecycleStopped)
        XCTAssertThrowsError(try machine.transition(to: .running, reason: .lifecycleSuspendAborted, proof: proof)) {
            XCTAssertEqual(($0 as? SandboxFailure)?.reason, .lifecycleInvalidTransition)
        }
        XCTAssertEqual(machine.state, .suspended)
    }

    func testUnrecoverableSuspendConvergesThroughFailed() throws {
        var (machine, _, _) = try runningMachine()
        try machine.transition(to: .suspending, reason: .lifecycleStopRequested)
        machine.forceFail(reason: .lifecycleSuspendFailed)
        XCTAssertEqual(machine.state, .failed)
        try machine.transition(to: .stopping, reason: .lifecycleStopRequested)
        try machine.transition(to: .stopped, reason: .lifecycleStopped)
    }

    func testReasonCodesAreStable() {
        XCTAssertEqual(ReasonCode.lifecycleSuspendAborted.value, "DBX-LIFECYCLE-SUSPEND-ABORTED")
        XCTAssertEqual(ReasonCode.lifecycleSuspendFailed.value, "DBX-LIFECYCLE-SUSPEND-FAILED")
    }
}
