import Foundation

/// Guest manifest 签名与防降级模型（docs/design/m1-5-manifest-signing.md）。
///
/// 设计约束：
/// - signer 身份由宿主编译内嵌的公钥允许列表识别，不使用 X.509；
/// - 签名覆盖 **路径无关** 的 canonical payload，assets 的可移植性由 digest 保障；
/// - 签名与防降级检查都在 `GuestAssetValidator`（DeskBoxVZ）里执行，本 struct 只做序列化形式。
public struct ManifestSignature: Sendable, Equatable, Codable {
    public let alg: String   // "ed25519"
    public let keyID: String // first-16-hex chars of trusted Ed25519 public key
    public let sig: String   // base64

    public init(alg: String, keyID: String, sig: String) {
        self.alg = alg
        self.keyID = keyID
        self.sig = sig
    }
}

/// 被签名的 canonical payload（不含绝对路径，不含 manifestDigest）。
/// 只覆盖内容性字段，允许同一批 guest 资产在任意绝对路径上验证通过。
public struct ManifestSigningPayload: Sendable, Equatable, Codable {
    public let fileDigests: [String: String]
    public let guestAssetVersion: Int
    public let kernelCommandLine: String
    public let sbomDigest: String?

    public init(fileDigests: [String: String], guestAssetVersion: Int, kernelCommandLine: String, sbomDigest: String? = nil) {
        self.fileDigests = fileDigests
        self.guestAssetVersion = guestAssetVersion
        self.kernelCommandLine = kernelCommandLine
        self.sbomDigest = sbomDigest
    }

    /// Canonical JSON bytes（sortedKeys + no slashes escaping variance via UTF-8 raw).
    public func canonicalBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public extension GuestAssetManifest {
    var signingPayload: ManifestSigningPayload {
        ManifestSigningPayload(
            fileDigests: fileDigests,
            guestAssetVersion: guestAssetVersion,
            kernelCommandLine: kernelCommandLine,
            sbomDigest: sbomDigest
        )
    }
}
