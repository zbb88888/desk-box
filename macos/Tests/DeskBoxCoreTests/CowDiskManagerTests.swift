import XCTest
import CryptoKit
@testable import DeskBoxVZ
@testable import DeskBoxCore

final class CowDiskManagerTests: XCTestCase {
    func testCloneIsIndependentAndCanBeRemoved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskbox-cow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("base.vhd")
        try Data("base".utf8).write(to: source)
        let manager = try CowDiskManager(root: root.appendingPathComponent("cows"))
        let sandbox = SandboxID.new()

        do {
            let lease = try manager.createClone(source: source, sandboxID: sandbox)
            XCTAssertTrue(FileManager.default.fileExists(atPath: lease.cloneURL.path))
            XCTAssertEqual(try Data(contentsOf: lease.cloneURL), Data("base".utf8))
            try Data("clone".utf8).write(to: lease.cloneURL)
            XCTAssertEqual(try Data(contentsOf: source), Data("base".utf8))
            try manager.removeClone(lease)
            XCTAssertFalse(FileManager.default.fileExists(atPath: lease.cloneURL.path))
        } catch let error as SandboxFailure where error.reason == .platformCowUnavailable {
            // The test runner may use a non-APFS temporary volume. The
            // production contract is still fail-closed in that case.
            throw XCTSkip("temporary volume does not support APFS clonefile: \(error)")
        }
    }

    func testExistingCloneDoesNotGetOverwritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskbox-cow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("base.vhd")
        try Data("base".utf8).write(to: source)
        let manager = try CowDiskManager(root: root.appendingPathComponent("cows"))
        let sandbox = SandboxID.new()

        do {
            let first = try manager.createClone(source: source, sandboxID: sandbox)
            XCTAssertThrowsError(try manager.createClone(source: source, sandboxID: sandbox)) { error in
                XCTAssertEqual((error as? SandboxFailure)?.reason, .platformCowUnavailable)
            }
            try manager.removeClone(first)
        } catch let error as SandboxFailure where error.reason == .platformCowUnavailable {
            throw XCTSkip("temporary volume does not support APFS clonefile: \(error)")
        }
    }

    func testRegistrySweepRemovesOnlyDeadProcessEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskbox-reg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = try SandboxRegistry(root: root)
        let orphanClone = root.appendingPathComponent("orphan.vhd")
        try Data("clone".utf8).write(to: orphanClone)
        let liveClone = root.appendingPathComponent("live.vhd")
        try Data("live".utf8).write(to: liveClone)

        try registry.upsert(RegisteredSandbox(
            sandboxID: .new(), bootID: .new(), status: .running,
            clonePath: orphanClone.path, hostPID: Int32(999_999_999)))
        try registry.upsert(RegisteredSandbox(
            sandboxID: .new(), bootID: .new(), status: .running,
            clonePath: liveClone.path,
            hostPID: ProcessInfo.processInfo.processIdentifier))

        let report = try registry.sweep()
        XCTAssertEqual(report.orphanedSandboxes.count, 1)
        XCTAssertEqual(report.removedCloneFiles, [orphanClone.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanClone.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveClone.path))
        XCTAssertEqual(try registry.load().count, 1)
    }

    func testSecureRecordSessionRoundTrip() throws {
        let sandbox = SandboxID.new()
        let boot = BootContext(sandboxID: sandbox, protocolMajor: 1, guestManifestDigest: "digest")
        let hostSession = SecureRecordSession(context: boot)
        XCTAssertEqual(hostSession.hostPublicHex.count, 64)

        // Simulate the guest side with a fresh ephemeral keypair shared through
        // the same HKDF inputs the host uses.
        let guestPrivate = Curve25519.KeyAgreement.PrivateKey()
        let guestPublic = Data(guestPrivate.publicKey.rawRepresentation)
        try hostSession.completeKeyExchange(guestPublicData: guestPublic, boot: boot)
        guard let binding = hostSession.sessionBinding else {
            XCTFail("expected session binding after key exchange")
            return
        }
        XCTAssertEqual(binding.hostFingerprintHex, hostSession.hostPublicHex)
        XCTAssertFalse(binding.sessionID.raw.isEmpty)

        let frame = Data("frame-payload-test".utf8)
        let sealed = try hostSession.encrypt(frameData: frame)
        XCTAssertNotEqual(sealed, frame)
        let opened = try hostSession.decrypt(record: sealed)
        XCTAssertEqual(opened, frame)
    }

    func testRegistryRefusesClonesOutsideCowRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskbox-reg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).vhd")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let registry = try SandboxRegistry(root: root)
        try registry.upsert(RegisteredSandbox(
            sandboxID: .new(), bootID: .new(), status: .running,
            clonePath: outside.path, hostPID: Int32(999_999_999)))

        let report = try registry.sweep()
        XCTAssertEqual(report.removedCloneFiles, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(try registry.load().count, 1)
    }
}
