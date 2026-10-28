import Foundation
import XCTest
@testable import DeskBoxCore
@testable import DeskBoxVZ

/// M22：更新检查语义（INV-10 在分发面的延伸）。
final class UpdateCheckerTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbx-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: - 版本比较

    func testSemverParsingAndOrdering() throws {
        XCTAssertEqual(try SemanticVersion(parsing: "v0.2.0").description, "0.2.0")
        XCTAssertEqual(try SemanticVersion(parsing: "1.10.3+sha.abc").description, "1.10.3")
        XCTAssertTrue(try SemanticVersion(parsing: "0.2.10") > (try SemanticVersion(parsing: "0.2.9")))
        XCTAssertTrue(try SemanticVersion(parsing: "1.0.0") > (try SemanticVersion(parsing: "1.0.0-rc.1")))
        XCTAssertTrue(try SemanticVersion(parsing: "1.0.0-rc.2") > (try SemanticVersion(parsing: "1.0.0-rc.1")))
        XCTAssertTrue(try SemanticVersion(parsing: "1.0.0-alpha.10") > (try SemanticVersion(parsing: "1.0.0-alpha.9")))
        XCTAssertTrue(try SemanticVersion(parsing: "1.0.0-1") < (try SemanticVersion(parsing: "1.0.0-alpha")))
        XCTAssertEqual(try SemanticVersion(parsing: "0.2.0"), try SemanticVersion(parsing: "v0.2.0+build7"))
    }

    func testSemverRejectsMalformed() {
        for bad in ["", "1", "1.2", "1.2.3.4", "a.b.c", "1.-2.3"] {
            XCTAssertThrowsError(try SemanticVersion(parsing: bad), "should reject \(bad)")
        }
    }

    // MARK: - 决策

    func testUpToDateWhenVersionsEqual() throws {
        let dir = try publishChannel(tag: "v0.2.0", assetVersion: 2)
        let result = try UpdateChecker.check(channelURL: dir.appendingPathComponent("channel.json"),
                                            currentVersion: "0.2.0")
        XCTAssertEqual(result.decision, .upToDate)
        XCTAssertEqual(result.remoteVersion, "0.2.0")
        XCTAssertFalse(result.isRefusal)
    }

    func testAvailableWhenRemoteNewer() throws {
        let dir = try publishChannel(tag: "v0.2.1", assetVersion: 2)
        let result = try UpdateChecker.check(channelURL: dir.appendingPathComponent("channel.json"),
                                            currentVersion: "0.2.0")
        XCTAssertEqual(result.decision, .available)
        XCTAssertEqual(result.remoteVersion, "0.2.1")
        XCTAssertEqual(result.assetVersion, 2)
        XCTAssertNotNil(result.manifestDigest)
    }

    /// 核心负例：远端版本更旧必须拒绝（不复活旧版本）。
    func testRollbackRefused() throws {
        let dir = try publishChannel(tag: "v0.1.9", assetVersion: 2)
        XCTAssertThrowsError(try UpdateChecker.check(channelURL: dir.appendingPathComponent("channel.json"),
                                                     currentVersion: "0.2.0")) { error in
            guard case UpdateCheckError.rollbackRefused(let cur, let remote) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(cur, "0.2.0")
            XCTAssertEqual(remote, "0.1.9")
        }
    }

    /// 预发布 → 正式版算升级；正式版 → 预发布算回滚。
    func testPrereleaseTransitionIsOrdered() throws {
        let older = try publishChannel(tag: "v0.2.0-rc.1", assetVersion: 2, name: "rc")
        let r1 = try UpdateChecker.check(channelURL: older.appendingPathComponent("channel.json"),
                                         currentVersion: "0.2.0-rc.0")
        XCTAssertEqual(r1.decision, .available)

        let released = try publishChannel(tag: "v0.2.0", assetVersion: 2, name: "final")
        let r2 = try UpdateChecker.check(channelURL: released.appendingPathComponent("channel.json"),
                                         currentVersion: "0.2.0-rc.1")
        XCTAssertEqual(r2.decision, .available)

        // 反方向：远端是 rc，本地已是正式版 → 回滚，必须拒绝。
        XCTAssertThrowsError(try UpdateChecker.check(channelURL: older.appendingPathComponent("channel.json"),
                                                     currentVersion: "0.2.0"))
    }

    // MARK: - 完整性 / 密钥

    func testTamperedChannelDigestRejected() throws {
        let dir = try publishChannel(tag: "v0.3.0", assetVersion: 3)
        let manifestURL = dir.appendingPathComponent("manifest.json")
        var text = try String(contentsOf: manifestURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "console=ttyAMA0", with: "console=ttyAMA0 quiet")
        try text.write(to: manifestURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try UpdateChecker.check(channelURL: dir.appendingPathComponent("channel.json"),
                                                     currentVersion: "0.2.0")) { error in
            guard case UpdateCheckError.channel(.manifestDigestMismatch) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRevokedOnlyKeysRefused() throws {
        let dir = try publishChannel(tag: "v0.3.0", assetVersion: 3, keyStatus: "revoked")
        XCTAssertThrowsError(try UpdateChecker.check(channelURL: dir.appendingPathComponent("channel.json"),
                                                     currentVersion: "0.2.0")) { error in
            guard case UpdateCheckError.noUsableReleaseKey = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testExpiredKeyRefused() throws {
        let dir = try publishChannel(tag: "v0.3.0", assetVersion: 3,
                                     notAfter: "2020-01-01T00:00:00Z")
        XCTAssertThrowsError(try UpdateChecker.check(channelURL: dir.appendingPathComponent("channel.json"),
                                                     currentVersion: "0.2.0")) { error in
            guard case UpdateCheckError.noUsableReleaseKey = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testMissingChannelFile() {
        let missing = workspace.appendingPathComponent("nope.json")
        XCTAssertThrowsError(try UpdateChecker.check(channelURL: missing, currentVersion: "0.2.0"))
    }

    func testRefusalProducesStructuredResult() throws {
        let dir = try publishChannel(tag: "v0.1.0", assetVersion: 2)
        var caught: Error?
        do {
            _ = try UpdateChecker.check(channelURL: dir.appendingPathComponent("channel.json"),
                                        currentVersion: "0.2.0")
            return XCTFail("expected refusal")
        } catch let error {
            caught = error
        }
        let error = try XCTUnwrap(caught)
        let refusal = UpdateChecker.refusal(currentVersion: "0.2.0", error: error)
        XCTAssertEqual(refusal.decision, .rollback)
        XCTAssertTrue(refusal.isRefusal)
        XCTAssertEqual(refusal.schema, UpdateCheckResult.schemaValue)
        XCTAssertTrue(refusal.reason?.contains("update-rollback-refused") == true)
        // 可编码（GUI/CLI 共用结构化输出）。
        XCTAssertNoThrow(try JSONEncoder().encode(refusal))
    }

    // MARK: - helpers

    /// 用真实 publish 流程产出 channel（manifest 签名 + channel 覆盖）。
    private func publishChannel(tag: String,
                                assetVersion: Int,
                                name: String = "main",
                                keyStatus: String = "active",
                                notAfter: String? = nil) throws -> URL {
        let dir = workspace.appendingPathComponent("channel-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let kernel = dir.appendingPathComponent("vmlinuz-virt")
        let rootDisk = dir.appendingPathComponent("root-disk.raw")
        let sbom = dir.appendingPathComponent("sbom.json")
        try Data("kernel-\(name)".utf8).write(to: kernel)
        try Data("disk-\(name)".utf8).write(to: rootDisk)
        let sbomText = """
        {"schema":"deskbox-guest-sbom/v1","builtAtUtc":"2026-01-01T00:00:00Z","assetVersion":\(assetVersion),\
        "inputs":[],"outputs":[{"name":"vmlinuz-virt","sha256":"\(try DigestVerifier.sha256Hex(of: kernel))"}]}
        """
        try Data(sbomText.utf8).write(to: sbom)

        let kernelDigest = try DigestVerifier.sha256Hex(of: kernel)
        let diskDigest = try DigestVerifier.sha256Hex(of: rootDisk)
        let sbomDigestForManifest = try DigestVerifier.sha256Hex(of: sbom)
        let base = GuestAssetManifest(
            kernelURL: kernel, initrdURL: nil, rootDiskURL: rootDisk,
            kernelCommandLine: "console=ttyAMA0",
            guestAssetVersion: assetVersion,
            manifestDigest: "pending",
            fileDigests: [kernel.path: kernelDigest, rootDisk.path: diskDigest],
            sbomDigest: sbomDigestForManifest
        )
        let keys = ManifestSigner.generateKeypairHex()
        let sig = try ManifestSigner.sign(payload: base.signingPayload, privateKeyHex: keys.privateHex)
        let pubHex = try ManifestSigner.publicKeyHex(fromPrivateHex: keys.privateHex)
        let signed = GuestAssetManifest(
            kernelURL: kernel, initrdURL: nil, rootDiskURL: rootDisk,
            kernelCommandLine: "console=ttyAMA0",
            guestAssetVersion: assetVersion,
            manifestDigest: "pending",
            fileDigests: base.fileDigests,
            signature: sig,
            sbomDigest: sbomDigestForManifest
        )

        let manifestURL = dir.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(signed).write(to: manifestURL)

        let now = "2026-01-01T00:00:00Z"
        var keyJSON = """
        {"keyID":"\(sig.keyID)","publicHex":"\(pubHex)",\
        "status":"\(keyStatus)","notBefore":"2020-01-01T00:00:00Z"
        """
        if let notAfter { keyJSON += ",\"notAfter\":\"\(notAfter)\"" }
        keyJSON += "}"
        let keysURL = dir.appendingPathComponent("release-keys.json")
        try Data("""
        {"schema":"deskbox-release-keys/v1","generatedAtUtc":"\(now)","keys":[\(keyJSON)]}
        """.utf8).write(to: keysURL)

        // channel.json：manifestDigest 必须是 canonical payload digest。
        let payload = ManifestSigningPayload(fileDigests: signed.fileDigests,
                                             guestAssetVersion: signed.guestAssetVersion,
                                             kernelCommandLine: signed.kernelCommandLine,
                                             sbomDigest: signed.sbomDigest)
        let manifestDigest = try ManifestSigner.payloadDigestHex(payload: payload)
        let sbomDigest = sbomDigestForManifest
        let channel = """
        {"schema":"\(ReleaseChannelManifest.schemaValue)","generatedAtUtc":"\(now)",\
        "releaseTag":"\(tag)","minGuestAssetVersionFloor":1,\
        "keys":[\(keyJSON)],\
        "manifest":{"files":{"manifest":"manifest.json","sbom":"sbom.json"},\
        "assetVersion":\(assetVersion),"manifestDigest":"\(manifestDigest)","sbomDigest":"\(sbomDigest)"}}
        """
        try Data(channel.utf8).write(to: dir.appendingPathComponent("channel.json"))
        return dir
    }
}
