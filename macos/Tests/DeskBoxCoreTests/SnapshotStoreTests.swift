import XCTest
import Foundation
@testable import DeskBoxCore
@testable import DeskBoxVZ

/// M20：快照信封与「不复活权限」闸门（INV-10）单测。
final class SnapshotStoreTests: XCTestCase {

    private func tempURL(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbx-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(name)
    }

    private func store() throws -> (SnapshotStore, URL) {
        let keyURL = try tempURL("snapshot.key")
        return (SnapshotStore(keyURL: keyURL), keyURL)
    }

    private func metadata(manifestDigest: String = "sha256:aaa",
                          assetVersion: Int = 1,
                          keyID: String = "kid-1",
                          sandboxID: String = "SB-1",
                          bootID: String = "BOOT-1") -> SnapshotMetadata {
        SnapshotMetadata(sandboxID: sandboxID, bootID: bootID, manifestDigest: manifestDigest,
                         guestAssetVersion: assetVersion, keyID: keyID,
                         createdAtUtc: "2026-10-28T00:00:00Z", hostBuild: "macOS-test",
                         payloadSha256: "")
    }

    // MARK: 信封基本语义

    func testRoundTripPreservesPayload() throws {
        let (store, _) = try store()
        let url = try tempURL("sb.snap")
        let payload = Data(repeating: 0xAB, count: 4096)
        try store.seal(payload: payload, metadata: metadata(), to: url)
        let reopened = try store.open(at: url)
        XCTAssertEqual(reopened, payload)
    }

    func testSnapshotOnDiskIsCiphertext() throws {
        let (store, _) = try store()
        let url = try tempURL("sb.snap")
        let secret = Data("GUEST-SECRET-MARKER-0123456789".utf8)
        try store.seal(payload: secret, metadata: metadata(), to: url)
        let raw = try Data(contentsOf: url)
        XCTAssertNil(raw.range(of: secret), "明文机密出现在快照文件中")
        XCTAssertTrue(String(decoding: raw.prefix(8), as: UTF8.self).hasPrefix("DBXSNAP1"))
    }

    func testSnapshotFileIsOwnerOnly() throws {
        let (store, _) = try store()
        let url = try tempURL("sb.snap")
        try store.seal(payload: Data("x".utf8), metadata: metadata(), to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o777, 0o600)
    }

    // MARK: 完整性 / 绑定

    func testTamperedMetadataFailsDecrypt() throws {
        let (store, _) = try store()
        let url = try tempURL("sb.snap")
        try store.seal(payload: Data("payload".utf8), metadata: metadata(), to: url)

        var raw = try Data(contentsOf: url)
        // 翻转 metadata 区域里的一个字节（AAD 参与校验）
        let index = 12 + 5
        raw[index] ^= 0xFF
        try raw.write(to: url)

        XCTAssertThrowsError(try store.open(at: url))
    }

    func testTamperedCiphertextFailsDecrypt() throws {
        let (store, _) = try store()
        let url = try tempURL("sb.snap")
        try store.seal(payload: Data(repeating: 0x11, count: 128), metadata: metadata(), to: url)
        var raw = try Data(contentsOf: url)
        raw[raw.count - 20] ^= 0x01
        try raw.write(to: url)
        XCTAssertThrowsError(try store.open(at: url)) { error in
            XCTAssertEqual(error as? SnapshotError, .decryptFailed)
        }
    }

    func testDifferentKeyCannotOpen() throws {
        let (storeA, _) = try store()
        let url = try tempURL("sb.snap")
        try storeA.seal(payload: Data("payload".utf8), metadata: metadata(), to: url)

        let otherKeyURL = try tempURL("other.key")
        let storeB = SnapshotStore(keyURL: otherKeyURL)
        XCTAssertThrowsError(try storeB.open(at: url)) { error in
            XCTAssertEqual(error as? SnapshotError, .decryptFailed)
        }
    }

    func testMalformedMagicRejected() throws {
        let (store, _) = try store()
        let url = try tempURL("bad.snap")
        try Data("NOT-A-SNAPSHOT-AT-ALL-0123456789".utf8).write(to: url)
        XCTAssertThrowsError(try store.readMetadata(at: url)) { error in
            XCTAssertEqual(error as? SnapshotError, .malformed("magic 不符"))
        }
    }

    func testMissingSnapshotRejected() throws {
        let (store, _) = try store()
        let url = try tempURL("absent.snap")
        XCTAssertThrowsError(try store.readMetadata(at: url)) { error in
            guard case .missing = (error as? SnapshotError) ?? .malformed("x") else {
                return XCTFail("期望 missing，实际 \(error)")
            }
        }
    }

    // MARK: 三道闸（不复活权限）

    private func keys(_ status: ReleaseKeysManifest.Key.Status, keyID: String = "kid-1") -> ReleaseKeysManifest {
        ReleaseKeysManifest(
            schema: ReleaseKeysManifest.schemaValue,
            generatedAtUtc: "2026-01-01T00:00:00Z",
            keys: [.init(keyID: keyID, publicHex: "00", status: status,
                         notBefore: "2020-01-01T00:00:00Z")]
        )
    }

    func testGateAcceptsMatchingSnapshot() throws {
        let gate = SnapshotGate(manifestDigest: "sha256:aaa", guestAssetVersion: 1,
                                minimumAssetVersionFloor: 1, releaseKeys: keys(.active))
        XCTAssertNoThrow(try gate.check(metadata()))
    }

    func testGateRejectsManifestMismatch() throws {
        let gate = SnapshotGate(manifestDigest: "sha256:bbb", guestAssetVersion: 1,
                                minimumAssetVersionFloor: 1, releaseKeys: keys(.active))
        XCTAssertThrowsError(try gate.check(metadata())) { error in
            guard case .manifestMismatch = (error as? SnapshotError) ?? .malformed("x") else {
                return XCTFail("期望 manifestMismatch，实际 \(error)")
            }
        }
    }

    func testGateRejectsStaleAssetVersion() throws {
        let gate = SnapshotGate(manifestDigest: "sha256:aaa", guestAssetVersion: 2,
                                minimumAssetVersionFloor: 2, releaseKeys: keys(.active))
        XCTAssertThrowsError(try gate.check(metadata(assetVersion: 1))) { error in
            guard case .assetVersionStale = (error as? SnapshotError) ?? .malformed("x") else {
                return XCTFail("期望 assetVersionStale，实际 \(error)")
            }
        }
    }

    func testGateRejectsAssetVersionBelowFloor() throws {
        let gate = SnapshotGate(manifestDigest: "sha256:aaa", guestAssetVersion: 1,
                                minimumAssetVersionFloor: 3, releaseKeys: keys(.active))
        XCTAssertThrowsError(try gate.check(metadata(assetVersion: 1))) { error in
            guard case .assetVersionStale = (error as? SnapshotError) ?? .malformed("x") else {
                return XCTFail("期望 assetVersionStale，实际 \(error)")
            }
        }
    }

    func testGateRejectsRevokedKey() throws {
        let gate = SnapshotGate(manifestDigest: "sha256:aaa", guestAssetVersion: 1,
                                minimumAssetVersionFloor: 1, releaseKeys: keys(.revoked))
        XCTAssertThrowsError(try gate.check(metadata())) { error in
            XCTAssertEqual(error as? SnapshotError, .keyRevoked("kid-1"))
        }
    }

    func testGateRejectsUnknownKey() throws {
        let gate = SnapshotGate(manifestDigest: "sha256:aaa", guestAssetVersion: 1,
                                minimumAssetVersionFloor: 1, releaseKeys: keys(.active, keyID: "other"))
        XCTAssertThrowsError(try gate.check(metadata())) { error in
            XCTAssertEqual(error as? SnapshotError, .keyUnknown("kid-1"))
        }
    }

    func testGateWithoutChainSkipsKeyCheck() throws {
        let gate = SnapshotGate(manifestDigest: "sha256:aaa", guestAssetVersion: 1,
                                minimumAssetVersionFloor: 1, releaseKeys: nil)
        XCTAssertNoThrow(try gate.check(metadata()))
    }
}
