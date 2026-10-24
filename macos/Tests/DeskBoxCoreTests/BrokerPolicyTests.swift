import XCTest
@testable import DeskBoxVZ
@testable import DeskBoxCore

/// M2-3a: Broker policy 与凭据注入（INV-03/INV-04）。
final class BrokerPolicyTests: XCTestCase {
    private let policy = BrokerPolicy(allowedHosts: ["api.github.com", "example.com"],
                                      allowedSchemes: ["https"], maxResponseBytes: 1024)

    func testAllowed() {
        XCTAssertTrue(policy.decision(for: URL(string: "https://api.github.com/zen")!).isAllowed)
        XCTAssertTrue(policy.decision(for: URL(string: "https://example.com")!).isAllowed)
    }

    func testUnknownHostDenied() {
        guard case .deny(let reason) = policy.decision(for: URL(string: "https://evil.example.com")!) else {
            return XCTFail("expected deny")
        }
        XCTAssertTrue(reason.contains("allowlist"))
    }

    func testSchemeDenied() {
        guard case .deny = policy.decision(for: URL(string: "http://example.com")!) else {
            return XCTFail("expected deny")
        }
    }

    func testCredentialInjectionTargetsAllowlistedHostOnly() {
        let broker = CredentialBroker(tokenByHost: ["api.github.com": "Bearer t0ken"])
        XCTAssertEqual(broker.authorizationHeader(forHost: "api.github.com"), "Bearer t0ken")
        XCTAssertNil(broker.authorizationHeader(forHost: "evil.example.com"))
    }

    func testPolicyJsonRoundTrip() throws {
        let encoded = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(BrokerPolicy.self, from: encoded)
        XCTAssertEqual(decoded, policy)
    }
}
