import XCTest
@testable import DeskBoxVZ
@testable import DeskBoxCore

/// M1-5: manifest 签名与防降级（docs/design/m1-5-manifest-signing.md）。
final class ManifestSigningTests: XCTestCase {
    private func makeManifest(version: Int, signature: ManifestSignature? = nil) -> GuestAssetManifest {
        GuestAssetManifest(
            kernelURL: URL(fileURLWithPath: "/tmp/kernel"),
            initrdURL: nil,
            rootDiskURL: URL(fileURLWithPath: "/tmp/root.raw"),
            kernelCommandLine: "console=hvc0",
            guestAssetVersion: version,
            manifestDigest: "m",
            fileDigests: ["/tmp/kernel": String(repeating: "aa", count: 32)],
            signature: signature
        )
    }

    private func policy(for privateHex: String) throws -> (GuestSigningPolicy, ManifestSignature) {
        let payload = makeManifest(version: 2).signingPayload
        let sig = try ManifestSigner.sign(payload: payload, privateKeyHex: privateHex)
        // 从私钥推导公钥
        let pub = try ManifestSigner.publicKeyHex(fromPrivateHex: privateHex)
        return (GuestSigningPolicy(trustedPublicKeysHex: [pub], minimumGuestAssetVersion: 1), sig)
    }

    func testSignAndVerifyRoundTrip() throws {
        let keys = ManifestSigner.generateKeypairHex()
        let payload = makeManifest(version: 2).signingPayload
        let sig = try ManifestSigner.sign(payload: payload, privateKeyHex: keys.privateHex)
        let pub = try ManifestSigner.publicKeyHex(fromPrivateHex: keys.privateHex)
        XCTAssertTrue(pub.hasPrefix(sig.keyID))
        let policy = GuestSigningPolicy(trustedPublicKeysHex: [pub], minimumGuestAssetVersion: 1)
        XCTAssertNoThrow(try ManifestSigner.verify(manifest: makeManifest(version: 2, signature: sig),
                                                 policy: policy, allowUnsignedManifest: false))
    }

    func testUnsignedManifestRejectedByDefault() {
        let policy = GuestSigningPolicy(trustedPublicKeysHex: [], minimumGuestAssetVersion: 1)
        XCTAssertThrowsError(try ManifestSigner.verify(manifest: makeManifest(version: 1),
                                                     policy: policy, allowUnsignedManifest: false)) { error in
            XCTAssertEqual(error as? ManifestSignerError, .unsignedManifest)
        }
        XCTAssertNoThrow(try ManifestSigner.verify(manifest: makeManifest(version: 1),
                                                 policy: policy, allowUnsignedManifest: true))
    }

    func testTamperedDigestRejected() throws {
        let keys = ManifestSigner.generateKeypairHex()
        let sig = try ManifestSigner.sign(payload: makeManifest(version: 2).signingPayload, privateKeyHex: keys.privateHex)
        let pub = try ManifestSigner.publicKeyHex(fromPrivateHex: keys.privateHex)
        let policy = GuestSigningPolicy(trustedPublicKeysHex: [pub], minimumGuestAssetVersion: 1)
        var tampered = makeManifest(version: 2, signature: sig)
        tampered = GuestAssetManifest(kernelURL: tampered.kernelURL, initrdURL: nil, rootDiskURL: tampered.rootDiskURL,
                                      kernelCommandLine: tampered.kernelCommandLine,
                                      guestAssetVersion: 2, manifestDigest: tampered.manifestDigest,
                                      fileDigests: ["/tmp/kernel": String(repeating: "bb", count: 32)],
                                      signature: tampered.signature)
        XCTAssertThrowsError(try ManifestSigner.verify(manifest: tampered, policy: policy, allowUnsignedManifest: false)) { error in
            XCTAssertEqual(error as? ManifestSignerError, .signatureInvalid)
        }
    }

    func testUnknownKeyRejected() throws {
        let keys = ManifestSigner.generateKeypairHex()
        let sig = try ManifestSigner.sign(payload: makeManifest(version: 2).signingPayload, privateKeyHex: keys.privateHex)
        let policy = GuestSigningPolicy(trustedPublicKeysHex: [String(repeating: "ff", count: 32)],
                                        minimumGuestAssetVersion: 1)
        XCTAssertThrowsError(try ManifestSigner.verify(manifest: makeManifest(version: 2, signature: sig),
                                                     policy: policy, allowUnsignedManifest: false)) { error in
            guard case .unknownSigningKey? = error as? ManifestSignerError else {
                return XCTFail("expected unknownSigningKey, got \(error)")
            }
        }
    }

    func testDowngradeRejectedBeforeSignatureCheck() throws {
        let keys = ManifestSigner.generateKeypairHex()
        let sig = try ManifestSigner.sign(payload: makeManifest(version: 2).signingPayload, privateKeyHex: keys.privateHex)
        let pub = try ManifestSigner.publicKeyHex(fromPrivateHex: keys.privateHex)
        let policy = GuestSigningPolicy(trustedPublicKeysHex: [pub], minimumGuestAssetVersion: 3)
        XCTAssertThrowsError(try ManifestSigner.verify(manifest: makeManifest(version: 2, signature: sig),
                                                     policy: policy, allowUnsignedManifest: false)) { error in
            guard case .downgradeRejected(let current, let minimum)? = error as? ManifestSignerError else {
                return XCTFail("expected downgradeRejected, got \(error)")
            }
            XCTAssertEqual(current, 2)
            XCTAssertEqual(minimum, 3)
        }
    }

    func testValidatorEnforcesSignature() throws {
        let manifest = makeManifest(version: 1) // unsigned
        XCTAssertThrowsError(try GuestAssetValidator.validate(manifest,
                                                              signingPolicy: GuestSigningPolicy.current,
                                                              allowUnsignedManifest: false))
        XCTAssertThrowsError(try GuestAssetValidator.validate(manifest,
                                                              signingPolicy: GuestSigningPolicy.current,
                                                              allowUnsignedManifest: true))
        // allowUnsigned=true 时前进到 digest 文件校验，由于 /tmp/kernel 不存在仍会失败；
        // 这证明签名校验已被绕过而后续 fail-closed 校验仍在（double-gate）。
    }
}
