import XCTest
@testable import DeskBoxCore

/// 跨平台 contract suite 的第一批无平台依赖用例。
/// VZ/Hyper-V adapter 接入后，应将同一套断言运行于真实 backend。
final class RuntimeContractTests: XCTestCase {
    func testStateNamesAreStable() {
        XCTAssertEqual(SandboxState.allCases.map(\.rawValue), [
            "pending", "running", "suspending", "suspended",
            "resuming", "stopping", "stopped", "failed"
        ])
    }

    func testTerminalStateIsOnlyStopped() {
        XCTAssertTrue(SandboxState.stopped.isTerminal)
        XCTAssertFalse(SandboxState.failed.isTerminal)
    }

    func testFailedStateCanOnlyConvergeThroughStopping() throws {
        let sandbox = SandboxID.new()
        let boot = BootContext(sandboxID: sandbox, protocolMajor: 1, guestManifestDigest: "expected")
        var machine = LifecycleMachine(sandboxID: sandbox, boot: boot, correlationID: UUID())
        machine.forceFail(reason: .lifecycleUnexpectedExit)
        XCTAssertEqual(machine.state, .failed)
        try machine.transition(to: .stopping, reason: .lifecycleStopRequested)
        try machine.transition(to: .stopped, reason: .lifecycleStopped)
        XCTAssertEqual(machine.state, .stopped)
    }

    func testProofUsesCurrentManifestAndNonce() {
        let sandbox = SandboxID.new()
        let boot = BootContext(sandboxID: sandbox, protocolMajor: 1, guestManifestDigest: "expected")
        let proof = BootstrapProof(
            sandboxID: sandbox, bootID: boot.bootID, bootNonce: boot.bootNonce,
            protocolMajor: 1, guestManifestDigest: "actual", sessionID: .new()
        )
        let decision = BootstrapProof.verify(proof, against: boot, expectedProtocolMajor: 1)
        XCTAssertEqual(decision.reasonCode, .bootstrapProofMismatch)
    }
}
