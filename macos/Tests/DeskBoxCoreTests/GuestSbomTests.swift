import CryptoKit
import XCTest
@testable import DeskBoxVZ
@testable import DeskBoxCore

/// M3：SBOM verifier（INV-09 fail-closed）。
final class GuestSbomTests: XCTestCase {
    private func makeSbomDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskbox-sbom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "alpha".write(to: root.appendingPathComponent("a.bin"), atomically: true, encoding: .utf8)
        return root
    }

    private func sha256(_ string: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(string.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func testVerifyAcceptsMatchingDigest() throws {
        let root = try makeSbomDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = sha256("alpha")
        let sbom = GuestSbom(schema: "deskbox-guest-sbom/v1", builtAtUtc: "2025-01-01T00:00:00Z", assetVersion: 1,
                             inputs: [],
                             outputs: [GuestSbom.Entry(name: "a.bin", sha256: digest)])
        let sbomURL = root.appendingPathComponent("sbom.json")
        try JSONEncoder().encode(sbom).write(to: sbomURL)
        let verified = try GuestSbomVerifier.verify(sbomURL: sbomURL)
        XCTAssertEqual(verified.assetVersion, 1)
    }

    func testVerifyRejectsMismatch() throws {
        let root = try makeSbomDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sbom = GuestSbom(schema: "deskbox-guest-sbom/v1", builtAtUtc: "2025-01-01T00:00:00Z", assetVersion: 1,
                             inputs: [],
                             outputs: [GuestSbom.Entry(name: "a.bin", sha256: String(repeating: "cc", count: 32))])
        let sbomURL = root.appendingPathComponent("sbom.json")
        try JSONEncoder().encode(sbom).write(to: sbomURL)
        XCTAssertThrowsError(try GuestSbomVerifier.verify(sbomURL: sbomURL)) { error in
            guard case .digestMismatch? = error as? GuestSbomError else {
                return XCTFail("expected digestMismatch, got \(error)")
            }
        }
    }

    func testVerifyRejectsUnreadable() {
        XCTAssertThrowsError(try GuestSbomVerifier.verify(sbomURL: URL(fileURLWithPath: "/nonexistent/sbom.json"))) { error in
            guard case .unreadable? = error as? GuestSbomError else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }
}
