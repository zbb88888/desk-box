import CryptoKit
import XCTest
@testable import DeskBoxVZ
@testable import DeskBoxCore

/// M7: release channel verifier（INV-09 发布面）。
final class ReleaseChannelTests: XCTestCase {
    private func makeChannelDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskbox-channel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "manifest-body".write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "sbom-body".write(to: dir.appendingPathComponent("sbom.json"), atomically: true, encoding: .utf8)
        return dir
    }

    private func sha(_ s: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(s.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func writeChannel(to dir: URL, manifestDigest: String, sbomDigest: String,
                              floor: Int = 1, assetVersion: Int = 2) throws {
        let channel = ReleaseChannelManifest(
            schema: ReleaseChannelManifest.schemaValue,
            generatedAtUtc: "2025-09-01T00:00:00Z",
            releaseTag: "v0.1.0",
            minGuestAssetVersionFloor: floor,
            keys: [
                ReleaseKeysManifest.Key(keyID: "k1", publicHex: String(repeating: "aa", count: 32),
                                        status: .active, notBefore: "2025-01-01T00:00:00Z", notAfter: nil, note: nil)
            ],
            manifest: ReleaseChannelManifest.Manifest(
                files: .init(manifest: "manifest.json", sbom: "sbom.json"),
                assetVersion: assetVersion,
                manifestDigest: manifestDigest,
                sbomDigest: sbomDigest
            )
        )
        try JSONEncoder().encode(channel).write(to: dir.appendingPathComponent("channel.json"))
    }

    func testVerifyAcceptsConsistentChannel() throws {
        let dir = try makeChannelDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeChannel(to: dir, manifestDigest: sha("manifest-body"), sbomDigest: sha("sbom-body"))
        let result = try ReleaseChannelVerifier.verify(channelURL: dir.appendingPathComponent("channel.json"))
        XCTAssertTrue(result.manifestFilesVerified)
        XCTAssertEqual(result.channel.manifest.assetVersion, 2)
    }

    func testVerifyRejectsTamperedDigest() throws {
        let dir = try makeChannelDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeChannel(to: dir, manifestDigest: String(repeating: "cc", count: 32),
                         sbomDigest: sha("sbom-body"))
        XCTAssertThrowsError(try ReleaseChannelVerifier.verify(channelURL: dir.appendingPathComponent("channel.json"))) { error in
            guard case .manifestDigestMismatch? = error as? ReleaseChannelError else {
                return XCTFail("expected manifestDigestMismatch, got \(error)")
            }
        }
    }

    func testVerifyRejectsLowAssetVersion() throws {
        let dir = try makeChannelDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeChannel(to: dir, manifestDigest: sha("manifest-body"), sbomDigest: sha("sbom-body"),
                         floor: 3, assetVersion: 2)
        XCTAssertThrowsError(try ReleaseChannelVerifier.verify(channelURL: dir.appendingPathComponent("channel.json"))) { error in
            guard case .assetVersionTooLow(let cur, let floor) = error as? ReleaseChannelError else {
                return XCTFail("expected assetVersionTooLow, got \(error)")
            }
            XCTAssertEqual(cur, 2)
            XCTAssertEqual(floor, 3)
        }
    }

    func testVerifyRejectsUnreadableChannel() {
        XCTAssertThrowsError(try ReleaseChannelVerifier.verify(channelURL: URL(fileURLWithPath: "/nonexistent/channel.json"))) { error in
            guard case .unreadable? = error as? ReleaseChannelError else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }
}
