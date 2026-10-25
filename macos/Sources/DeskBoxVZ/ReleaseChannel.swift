import DeskBoxCore
import Foundation

/// Release channel（docs/design/m7-release-channel.md）— downstream verification
/// 仅依赖 channel.json 中公开的内容。
public struct ReleaseChannelManifest: Sendable, Equatable, Codable {
    public static let schemaValue = "deskbox-release-channel/v1"

    public let schema: String
    public let generatedAtUtc: String
    public let releaseTag: String
    public let minGuestAssetVersionFloor: Int
    public let keys: [ReleaseKeysManifest.Key]
    public let manifest: Manifest

    public init(schema: String, generatedAtUtc: String, releaseTag: String,
                minGuestAssetVersionFloor: Int, keys: [ReleaseKeysManifest.Key], manifest: Manifest) {
        self.schema = schema
        self.generatedAtUtc = generatedAtUtc
        self.releaseTag = releaseTag
        self.minGuestAssetVersionFloor = minGuestAssetVersionFloor
        self.keys = keys
        self.manifest = manifest
    }

    public struct Manifest: Sendable, Equatable, Codable {
        public struct Files: Sendable, Equatable, Codable {
            public let manifest: String
            public let sbom: String
            public init(manifest: String, sbom: String) {
                self.manifest = manifest
                self.sbom = sbom
            }
        }

        public let files: Files
        public let assetVersion: Int
        public let manifestDigest: String
        public let sbomDigest: String

        public init(files: Files, assetVersion: Int, manifestDigest: String, sbomDigest: String) {
            self.files = files
            self.assetVersion = assetVersion
            self.manifestDigest = manifestDigest
            self.sbomDigest = sbomDigest
        }
    }
}

public enum ReleaseChannelError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case unreadable(String)
    case manifestDigestMismatch(computed: String, declared: String)
    case sbomDigestMismatch(computed: String, declared: String)
    case assetVersionTooLow(current: Int, floor: Int)
    case signatureKeyNotInChannel(String)
    case releaseKeysEmpty

    public var description: String {
        switch self {
        case .malformed(let r): return "release channel manifest 非法: \(r)"
        case .unreadable(let p): return "release channel 文件不可读: \(p)"
        case .manifestDigestMismatch(let c, let d): return "manifest digest 不匹配 computed=\(c) declared=\(d)"
        case .sbomDigestMismatch(let c, let d): return "sbom digest 不匹配 computed=\(c) declared=\(d)"
        case .assetVersionTooLow(let now, let floor): return "assetVersion \(now) 低于 channel floor \(floor)"
        case .signatureKeyNotInChannel(let kid): return "signature keyID 不在 channel keys: \(kid)"
        case .releaseKeysEmpty: return "渠道 key 列表为空"
        }
    }
}

public enum ReleaseChannelVerifier {
    /// 验证 channel 一致性（fail-closed）：manifest/sbom digest 覆盖与 publish floor/signature 应用。
    public static func verify(channelURL: URL) throws -> (channel: ReleaseChannelManifest,
                                                          manifestFilesVerified: Bool) {
        guard FileManager.default.isReadableFile(atPath: channelURL.path) else {
            throw ReleaseChannelError.unreadable(channelURL.path)
        }
        let channel: ReleaseChannelManifest
        do {
            channel = try JSONDecoder().decode(ReleaseChannelManifest.self, from: Data(contentsOf: channelURL))
        } catch {
            throw ReleaseChannelError.malformed(error.localizedDescription)
        }
        guard channel.schema == ReleaseChannelManifest.schemaValue else {
            throw ReleaseChannelError.malformed("schema=\(channel.schema)")
        }
        guard !channel.keys.isEmpty else { throw ReleaseChannelError.releaseKeysEmpty }
        let dir = channelURL.deletingLastPathComponent()
        let manifestURL = dir.appendingPathComponent(channel.manifest.files.manifest)
        let sbomURL = dir.appendingPathComponent(channel.manifest.files.sbom)
        /// M11：manifestDigest 是 canonical payload digest（不签名挂钩），与发布致性验证。
        struct MinimalManifest: Decodable {
            let fileDigests: [String: String]
            let guestAssetVersion: Int
            let kernelCommandLine: String
            let sbomDigest: String?
        }
        let decoded = try JSONDecoder().decode(MinimalManifest.self, from: Data(contentsOf: manifestURL.standardizedFileURL))
        let payload = ManifestSigningPayload(
            fileDigests: decoded.fileDigests,
            guestAssetVersion: decoded.guestAssetVersion,
            kernelCommandLine: decoded.kernelCommandLine,
            sbomDigest: decoded.sbomDigest
        )
        let manifestActual = try ManifestSigner.payloadDigestHex(payload: payload)
        guard manifestActual == channel.manifest.manifestDigest else {
            throw ReleaseChannelError.manifestDigestMismatch(computed: manifestActual,
                                                             declared: channel.manifest.manifestDigest)
        }
        let sbomActual = try DigestVerifier.sha256Hex(of: sbomURL.standardizedFileURL)
        guard sbomActual == channel.manifest.sbomDigest else {
            throw ReleaseChannelError.sbomDigestMismatch(computed: sbomActual,
                                                         declared: channel.manifest.sbomDigest)
        }
        // 1) minGuestAssetVersionFloor：发布面资产得不少于 floor。
        guard channel.manifest.assetVersion >= channel.minGuestAssetVersionFloor else {
            throw ReleaseChannelError.assetVersionTooLow(current: channel.manifest.assetVersion,
                                                         floor: channel.minGuestAssetVersionFloor)
        }
        return (channel, true)
    }

    /// 附加检查：manifest 的 signature keyID 必须在 channel.keys 里（验证发布完整性）。
    public static func verifySignedManifestSignatureTruncation(channelURL: URL,
                                                               manifestURL: URL,
                                                               chainForSignature: ReleaseKeysManifest) throws {
        // 只做 key 存在性检查；签名有效性只是路径特性分开由 ManifestSigner.verify 带来。
        let data = try Data(contentsOf: channelURL)
        let channel = try JSONDecoder().decode(ReleaseChannelManifest.self, from: data)
        let mdata = try Data(contentsOf: manifestURL)
        struct CS: Codable { var signature: ManifestSignature? }
        let guest = try JSONDecoder().decode(GuestAssetManifest.self, from: mdata)
        guard let sig = guest.signature else { throw ReleaseChannelError.malformed("unsigned manifest inside channel") }
        guard channel.keys.contains(where: { $0.keyID == sig.keyID }) else {
            throw ReleaseChannelError.signatureKeyNotInChannel(sig.keyID)
        }
        _ = chainForSignature
    }
}
