import XCTest
@testable import DeskBoxVZ
@testable import DeskBoxCore

/// M5：release signing chain（INV-09 深面）。
final class ReleaseSigningChainTests: XCTestCase {
    private func makeChain(status: ReleaseKeysManifest.Key.Status = .active,
                           notBefore: String = "2025-08-15T00:00:00Z",
                           notAfter: String? = nil) -> ReleaseKeysManifest {
        ReleaseKeysManifest(
            schema: ReleaseKeysManifest.schemaValue,
            generatedAtUtc: "2025-08-15T00:00:00Z",
            keys: [
                ReleaseKeysManifest.Key(keyID: "curr0", publicHex: String(repeating: "aa", count: 32),
                                        status: status, notBefore: notBefore, notAfter: notAfter, note: nil),
                ReleaseKeysManifest.Key(keyID: "old1",  publicHex: String(repeating: "bb", count: 32),
                                        status: .revoked, notBefore: "2025-01-01T00:00:00Z", notAfter: nil, note: nil),
            ]
        )
    }

    func testActiveKeyUsable() throws {
        let chain = makeChain()
        let hex = try chain.usablePublicHex(forKeyID: "curr0")
        XCTAssertEqual(hex, String(repeating: "aa", count: 32))
    }

    func testRevokedKeyRejected() {
        let chain = makeChain()
        XCTAssertThrowsError(try chain.usablePublicHex(forKeyID: "old1")) { error in
            guard case .revokedKey(let kid) = error as? ReleaseSigningChainError else {
                return XCTFail("expected revokedKey, got \(error)")
            }
            XCTAssertEqual(kid, "old1")
        }
    }

    func testUnknownKeyRejected() {
        let chain = makeChain()
        XCTAssertThrowsError(try chain.usablePublicHex(forKeyID: "missing")) { error in
            guard case .unknownKey(let kid) = error as? ReleaseSigningChainError else {
                return XCTFail("expected unknownKey, got \(error)")
            }
            XCTAssertEqual(kid, "missing")
        }
    }

    func testNotYetActiveRejected() {
        let chain = makeChain(notBefore: "2999-01-01T00:00:00Z")
        XCTAssertThrowsError(try chain.usablePublicHex(forKeyID: "curr0")) { error in
            guard case .notYetActive? = error as? ReleaseSigningChainError else {
                return XCTFail("expected notYetActive, got \(error)")
            }
        }
    }

    func testExpiredRejected() {
        let chain = makeChain(notAfter: "2025-08-16T00:00:00Z")
        XCTAssertThrowsError(try chain.usablePublicHex(forKeyID: "curr0")) { error in
            guard case .expired? = error as? ReleaseSigningChainError else {
                return XCTFail("expected expired, got \(error)")
            }
        }
    }

    func testRetiredAcceptedWithinWindow() throws {
        var chain = makeChain()
        chain.keys[0] = ReleaseKeysManifest.Key(
            keyID: "curr0", publicHex: String(repeating: "aa", count: 32),
            status: .retired, notBefore: "2025-08-15T00:00:00Z", notAfter: nil, note: nil)
        let hex = try chain.usablePublicHex(forKeyID: "curr0")
        XCTAssertEqual(hex, String(repeating: "aa", count: 32))
    }
}
