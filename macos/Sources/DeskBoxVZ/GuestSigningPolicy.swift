import CryptoKit
import DeskBoxCore
import Foundation

/// Guest manifest 签名策略（docs/design/m1-5-manifest-signing.md）。
///
/// 安全决策：
/// - 信任根是这里 compile-time 内嵌的 Ed25519 公钥 hex 允许列表；不使用 X.509；
/// - 默认 fail-closed：未签名/签名不匹配/recipient 非受信 key 均拒绝；
/// - 唯一开发豁免是 `--allow-unsigned-manifest`（与 `--allow-plaintext` 同级语义）；
/// - 防降级：`minimumGuestAssetVersion` 随每次 guest 安全修复发布单调抬升。
public struct GuestSigningPolicy: Sendable, Equatable {
    public let trustedPublicKeysHex: [String]
    public let minimumGuestAssetVersion: Int

    public init(trustedPublicKeysHex: [String], minimumGuestAssetVersion: Int) {
        self.trustedPublicKeysHex = trustedPublicKeysHex
        self.minimumGuestAssetVersion = minimumGuestAssetVersion
    }

    /// 仓库内置的当前可信开发 key（M1-5 dev）。发布渠道必须替换为发布签名链 key
    /// 的允许列表并且与非 dev 逻辑隔离。
    public static let current = GuestSigningPolicy(
        trustedPublicKeysHex: releaseKeys + [DevSigningPublicKey.value].compactMap { $0 },
        minimumGuestAssetVersion: 1
    )

    /// 发布侧 key（M2 接入）；今天发行面使用每个工作站自建 dev key。
    private static let releaseKeys: [String] = []
}

private extension Data {
    func toHex() -> String { HexCoder.encode(self) }
    init?(hexString: String) { guard let d = HexCoder.decode(hexString) else { return nil }; self = d }
}

public enum ManifestSignerError: Error, Equatable, CustomStringConvertible {
    case invalidKeyMaterial
    case unsignedManifest
    case badAlgorithm(String)
    case unknownSigningKey(String)
    case signatureInvalid
    case revokedKey(String)
    case downgradeRejected(current: Int, minimum: Int)

    public var description: String {
        switch self {
        case .invalidKeyMaterial: return "签名 key 素材非法"
        case .unsignedManifest: return "manifest 未签名"
        case .badAlgorithm(let a): return "不支持的签名算法: \(a)"
        case .unknownSigningKey(let k): return "签名 keyID 不在允许列表: \(k)"
        case .signatureInvalid: return "manifest 签名不可验证"
        case .revokedKey(let k): return "签名 keyID 已 revoked: \(k)"
        case .downgradeRejected(let now, let min): return "guestAssetVersion \(now) 低于允许最低版本 \(min)"
        }
    }
}

public enum ManifestSigner {
    /// Ed25519 raw 密钥材料编解码：private = 32-byte seed；public = 32-byte。
    public static func generateKeypairHex() -> (publicHex: String, privateHex: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.publicKey.rawRepresentation.toHex(), key.rawRepresentation.toHex())
    }

    /// M11：payload digest，用于 release channel manifestDigest 的 deterministic 字段。
    public static func payloadDigestHex(payload: ManifestSigningPayload) throws -> String {
        try CryptoKit.SHA256.hash(data: payload.canonicalBytes()).map { String(format: "%02x", $0) }.joined()
    }

    public static func publicKeyHex(fromPrivateHex privateHex: String) throws -> String {
        guard let privData = Data(hexString: privateHex), privData.count == 32 else {
            throw ManifestSignerError.invalidKeyMaterial
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: privData).publicKey.rawRepresentation.toHex()
    }

    public static func sign(payload: ManifestSigningPayload, privateKeyHex: String) throws -> ManifestSignature {
        guard let privData = Data(hexString: privateKeyHex), privData.count == 32 else {
            throw ManifestSignerError.invalidKeyMaterial
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privData)
        let bytes = try payload.canonicalBytes()
        let sig = try key.signature(for: bytes)
        let pub = key.publicKey.rawRepresentation.toHex()
        return ManifestSignature(alg: "ed25519",
                                 keyID: String(pub.prefix(16)),
                                 sig: sig.base64EncodedString())
    }

    /// keyID 解析出允许列表中唯一的公钥；前缀冲突（理论上）只能落到选错 key 被 verify 拒绝。
    public static func trustedPublicKey(forKeyID keyID: String, policy: GuestSigningPolicy) throws -> Curve25519.Signing.PublicKey {
        for hex in policy.trustedPublicKeysHex where hex.hasPrefix(keyID) {
            if let data = Data(hexString: hex), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) {
                return key
            }
        }
        throw ManifestSignerError.unknownSigningKey(keyID)
    }

    /// M5 扩展：`chain` 参数都是 release-keys.json 内容（revoked/expired/notBefore 应用在 validated）。
    public static func verify(manifest: GuestAssetManifest,
                              chain: ReleaseKeysManifest,
                              now: Date = Date(),
                              allowUnsignedManifest: Bool) throws {
        guard let signature = manifest.signature else {
            if allowUnsignedManifest { return }
            throw ManifestSignerError.unsignedManifest
        }
        guard signature.alg == "ed25519" else { throw ManifestSignerError.badAlgorithm(signature.alg) }
        do {
            _ = try chain.usablePublicHex(forKeyID: signature.keyID, at: now)
        } catch let error as ReleaseSigningChainError {
            switch error {
            case .revokedKey(let kid): throw ManifestSignerError.revokedKey(kid)
            case .unknownKey(let kid): throw ManifestSignerError.unknownSigningKey(kid)
            case .malformed(let reason):
                throw ManifestSignerError.signatureInvalid
            case .notYetActive(let kid, _), .expired(let kid, _):
                throw ManifestSignerError.revokedKey("\(kid) (not-yet-active or expired)")
            }
        }
        guard manifest.guestAssetVersion >= 1 else {
            throw ManifestSignerError.downgradeRejected(current: manifest.guestAssetVersion, minimum: 1)
        }
        // signature check using the chain-provided key
        let pubHex = try chain.usablePublicHex(forKeyID: signature.keyID, at: now)
        guard let data = Data(hexString: pubHex),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) else {
            throw ManifestSignerError.signatureInvalid
        }
        guard let sig = Data(base64Encoded: signature.sig) else { throw ManifestSignerError.signatureInvalid }
        let bytes = try manifest.signingPayload.canonicalBytes()
        guard key.isValidSignature(sig, for: bytes) else { throw ManifestSignerError.signatureInvalid }
    }

    public static func verify(manifest: GuestAssetManifest,
                              policy: GuestSigningPolicy,
                              allowUnsignedManifest: Bool) throws {
        guard let signature = manifest.signature else {
            if allowUnsignedManifest { return }
            throw ManifestSignerError.unsignedManifest
        }
        guard signature.alg == "ed25519" else { throw ManifestSignerError.badAlgorithm(signature.alg) }
        guard manifest.guestAssetVersion >= policy.minimumGuestAssetVersion else {
            throw ManifestSignerError.downgradeRejected(current: manifest.guestAssetVersion,
                                                        minimum: policy.minimumGuestAssetVersion)
        }
        let key = try trustedPublicKey(forKeyID: signature.keyID, policy: policy)
        guard let sig = Data(base64Encoded: signature.sig) else { throw ManifestSignerError.signatureInvalid }
        let bytes = try manifest.signingPayload.canonicalBytes()
        guard key.isValidSignature(sig, for: bytes) else { throw ManifestSignerError.signatureInvalid }
    }
}
