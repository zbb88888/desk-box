import XCTest
@testable import DeskBoxCore

final class CoreContractTests: XCTestCase {
    func testRunningRequiresBootstrapProof() throws {
        let sandbox = SandboxID.new()
        let boot = BootContext(sandboxID: sandbox, protocolMajor: ControlChannelProtocol.currentMajor, guestManifestDigest: String(repeating: "a", count: 64))
        var machine = LifecycleMachine(sandboxID: sandbox, boot: boot, correlationID: UUID())

        XCTAssertThrowsError(try machine.transition(to: .running, reason: .lifecycleRunningConfirmed)) { error in
            XCTAssertEqual((error as? SandboxFailure)?.reason, .bootstrapProofMissing)
        }
        XCTAssertEqual(machine.state, .pending)
    }

    func testBootstrapProofIsBoundToBoot() throws {
        let sandbox = SandboxID.new()
        let boot = BootContext(sandboxID: sandbox, protocolMajor: ControlChannelProtocol.currentMajor, guestManifestDigest: "digest")
        let proof = BootstrapProof(
            sandboxID: sandbox, bootID: boot.bootID, bootNonce: UUID(),
            protocolMajor: boot.protocolMajor, guestManifestDigest: boot.guestManifestDigest,
            sessionID: .new()
        )
        XCTAssertFalse(BootstrapProof.verify(proof, against: boot, expectedProtocolMajor: 1).isAllowed)
    }

    func testRootImageIsRejectedByDefault() {
        let result = WorkloadSpecCompiler.compile(
            image: OCIImageConfig(user: "root", entrypoint: ["/bin/sh"]),
            policy: CompilerPolicy()
        )
        XCTAssertTrue(result.rejected)
        XCTAssertEqual(result.rejection?.reasonCode, .specUserRootDenied)
    }

    func testImageEnvironmentIsAllowlisted() {
        let result = WorkloadSpecCompiler.compile(
            image: OCIImageConfig(env: ["PATH=/usr/bin", "SECRET=never", "LD_PRELOAD=bad"]),
            policy: CompilerPolicy()
        )
        XCTAssertFalse(result.rejected)
        XCTAssertEqual(result.spec.environment, ["PATH": "/usr/bin"])
    }

    func testUncontrolledVolumeIsDropped() {
        let result = WorkloadSpecCompiler.compile(
            image: OCIImageConfig(volumes: ["/host", "/workspace"]),
            policy: CompilerPolicy(allowedVolumes: ["/workspace": VolumeBinding(name: "workspace", readOnly: false)])
        )
        XCTAssertFalse(result.rejected)
        XCTAssertEqual(result.spec.volumes, [VolumeBinding(name: "workspace", readOnly: false)])
        XCTAssertTrue(result.decisions.contains { $0.decision.reasonCode == .specVolumeDropped })
    }

    func testGrantAmbiguityFailsClosed() throws {
        let principal = Principal(userID: .new(), workspaceID: .new(), sandboxID: .new(), agentID: .new())
        let now = Date()
        let common: (InjectionForm) throws -> CredentialGrant = { injection in
            try CredentialGrant(
                id: .new(), subject: principal, scheme: "https", host: "api.example.com",
                port: 443, method: "GET", pathPrefix: "/v1", injection: injection,
                issuedAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(60)
            )
        }
        let a = try common(.bearer)
        let b = try common(.apiHeader(name: "X-API-Key"))
        let target = NetworkTarget(scheme: "https", host: "api.example.com", port: 443, method: "GET", path: "/v1/models")
        let resolution = GrantResolver.resolve(grants: [a, b], target: target, subject: principal, at: now)
        XCTAssertFalse(resolution.decision.isAllowed)
        XCTAssertEqual(resolution.decision.reasonCode, .grantAmbiguous)
    }
}
