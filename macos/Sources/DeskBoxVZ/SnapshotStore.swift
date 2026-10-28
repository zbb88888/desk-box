import CryptoKit
import Foundation
import DeskBoxCore

/// M20：快照加密信封（INV-10）。
///
/// 设计要点见 `docs/design/m20-lifecycle-persistence.md` §2：
/// - 磁盘上永远是 ChaChaPoly 密文；
/// - AAD = 规范化 metadata JSON，因此任何字段被改都解不开；
/// - metadata 同时参与「不复活权限」的三道闸（manifestDigest / assetVersion / keyID）。
public struct SnapshotMetadata: Sendable, Codable, Equatable {
    public static let schemaValue = "deskbox-snapshot/v1"
    public let schema: String
    public let sandboxID: String
    public let bootID: String
    public let manifestDigest: String
    public let guestAssetVersion: Int
    public let keyID: String
    public let createdAtUtc: String
    public let hostBuild: String
    public let payloadSha256: String
    /// M23（INV-02）：快照所属凭据域，参与 AAD。跨域恢复在解密前就会失败。
    public let domainID: String

    public init(sandboxID: String, bootID: String, manifestDigest: String, guestAssetVersion: Int,
                keyID: String, createdAtUtc: String, hostBuild: String, payloadSha256: String,
                domainID: String = "default") {
        self.schema = Self.schemaValue
        self.sandboxID = sandboxID
        self.bootID = bootID
        self.manifestDigest = manifestDigest
        self.guestAssetVersion = guestAssetVersion
        self.keyID = keyID
        self.createdAtUtc = createdAtUtc
        self.hostBuild = hostBuild
        self.payloadSha256 = payloadSha256
        self.domainID = domainID
    }

    /// 规范化字节：排序键、无空白，作为 AEAD 的 AAD 与绑定校验的输入。
    public func canonicalAAD() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum SnapshotError: Error, Equatable, CustomStringConvertible {
    case keyUnavailable(String)
    case malformed(String)
    case decryptFailed
    case manifestMismatch(stored: String, current: String)
    case assetVersionStale(stored: Int, floor: Int)
    case keyRevoked(String)
    case keyUnknown(String)
    case missing(String)
    /// M23：快照属于别的凭据域（跨域恢复必须拒绝）。
    case domainMismatch(stored: String, current: String)

    public var description: String {
        switch self {
        case .keyUnavailable(let p): return "snapshot key 不可用: \(p)"
        case .malformed(let r): return "快照文件格式非法: \(r)"
        case .decryptFailed: return "快照解密/完整性校验失败（密文、metadata 或 key 不符）"
        case .manifestMismatch(let s, let c): return "快照 manifestDigest 不符: stored=\(s) current=\(c)"
        case .assetVersionStale(let s, let f): return "快照资产版本过旧/不符: stored=\(s) floor=\(f)"
        case .keyRevoked(let k): return "快照签名 key 已 revoked: \(k)"
        case .keyUnknown(let k): return "快照签名 key 未知: \(k)"
        case .domainMismatch(let stored, let current):
            return "snapshot-domain-mismatch: 快照域=\(stored) 请求域=\(current)"
        case .missing(let p): return "快照不存在: \(p)"
        }
    }
}

/// 本机快照密钥的存取 + 信封读写。
public struct SnapshotStore: Sendable {
    public static let magic = Data("DBXSNAP1".utf8)
    public let keyURL: URL

    public init(keyURL: URL) {
        self.keyURL = keyURL
    }

    public static func defaultKeyURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskBox/snapshot.key")
    }

    /// 读取既有 key；不存在则生成并落盘（0600）。
    public func loadOrCreateKey() throws -> SymmetricKey {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let dir = keyURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, 32, base)
        }
        guard status == 0 else { throw SnapshotError.keyUnavailable(keyURL.path) }
        try bytes.write(to: keyURL, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return SymmetricKey(data: bytes)
    }

    /// 加密写入。`payload` 是 VZ 的 save file 原始字节。
    public func seal(payload: Data, metadata base: SnapshotMetadata, to url: URL) throws {
        let key = try loadOrCreateKey()
        let payloadHash = Data(SHA256.hash(data: payload)).map { String(format: "%02x", $0) }.joined()
        // 注意：必须逐字段带上 domainID，否则 metadata 会被重建为默认域，
        // AAD 与闸门都会看到错的域（M23 实施时踩到的真实 bug）。
        let metadata = SnapshotMetadata(
            sandboxID: base.sandboxID, bootID: base.bootID,
            manifestDigest: base.manifestDigest, guestAssetVersion: base.guestAssetVersion,
            keyID: base.keyID, createdAtUtc: base.createdAtUtc,
            hostBuild: base.hostBuild, payloadSha256: payloadHash,
            domainID: base.domainID)
        let aad = try metadata.canonicalAAD()
        let sealed = try ChaChaPoly.seal(payload, using: key, authenticating: aad)

        // 落盘的 metadata 必须与 AAD 字节完全一致（canonical），否则 open() 会因 AAD 不符而失败。
        let metaJSON = aad
        var out = Data()
        out.append(Self.magic)
        var length = UInt32(metaJSON.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(metaJSON)
        out.append(sealed.nonce.withUnsafeBytes { Data($0) })
        out.append(sealed.ciphertext)
        out.append(sealed.tag)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try out.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 读取信封（不解密）。用于「三道闸」先把关，避免把不可用快照交给 VZ。
    public func readMetadata(at url: URL) throws -> SnapshotMetadata {
        let (metadata, _, _, _) = try parseEnvelope(at: url)
        return metadata
    }

    /// 解密并返回 payload 字节。
    public func open(at url: URL) throws -> Data {
        let (metadata, metaJSON, nonce, body) = try parseEnvelope(at: url)
        let key = try loadOrCreateKey()
        let tagLength = 16
        guard body.count > tagLength else { throw SnapshotError.malformed("body 过短") }
        let ciphertext = body.prefix(body.count - tagLength)
        let tag = body.suffix(tagLength)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try ChaChaPoly.open(box, using: key, authenticating: metaJSON)
        } catch {
            throw SnapshotError.decryptFailed
        }
    }

    private func parseEnvelope(at url: URL) throws -> (SnapshotMetadata, Data, ChaChaPoly.Nonce, Data) {
        guard FileManager.default.fileExists(atPath: url.path) else { throw SnapshotError.missing(url.path) }
        let data = try Data(contentsOf: url)
        guard data.count >= 8, data.prefix(8) == Self.magic else {
            throw SnapshotError.malformed("magic 不符")
        }
        guard data.count > 8 + 4 + 12 + 16 else { throw SnapshotError.malformed("文件过短") }
        let lengthBytes = data.subdata(in: 8..<12)
        let metaLen = Int(lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard metaLen > 0, data.count > 12 + metaLen + 12 + 16 else {
            throw SnapshotError.malformed("metaLen 越界")
        }
        let metaJSON = data.subdata(in: 12..<(12 + metaLen))
        let metadata: SnapshotMetadata
        do {
            metadata = try JSONDecoder().decode(SnapshotMetadata.self, from: metaJSON)
        } catch {
            throw SnapshotError.malformed("metadata 解码失败")
        }
        guard metadata.schema == SnapshotMetadata.schemaValue else {
            throw SnapshotError.malformed("schema=\(metadata.schema)")
        }
        let nonceStart = 12 + metaLen
        let nonceBytes = data.subdata(in: nonceStart..<(nonceStart + 12))
        let nonce = try ChaChaPoly.Nonce(data: nonceBytes)
        let body = data.subdata(in: (nonceStart + 12)..<data.count)
        return (metadata, metaJSON, nonce, body)
    }
}

/// 恢复前的「不复活权限」闸门。任一失败即拒绝。
public struct SnapshotGate: Sendable {
    public let manifestDigest: String
    public let guestAssetVersion: Int
    public let minimumAssetVersionFloor: Int
    public let releaseKeys: ReleaseKeysManifest?
    /// M23（INV-02）：当前沙箱的凭据域；快照域必须与之相同。
    public let domainID: CredentialDomainID

    public init(manifestDigest: String, guestAssetVersion: Int, minimumAssetVersionFloor: Int,
                releaseKeys: ReleaseKeysManifest?,
                domainID: CredentialDomainID = CredentialDomainID("default")) {
        self.manifestDigest = manifestDigest
        self.guestAssetVersion = guestAssetVersion
        self.minimumAssetVersionFloor = minimumAssetVersionFloor
        self.releaseKeys = releaseKeys
        self.domainID = domainID
    }

    public func check(_ metadata: SnapshotMetadata) throws {
        // 域闸放在最前：跨域快照在语义上就不可用，不该再走 manifest/资产的比较。
        guard metadata.domainID == domainID.raw else {
            throw SnapshotError.domainMismatch(stored: metadata.domainID, current: domainID.raw)
        }
        guard metadata.manifestDigest == manifestDigest else {
            throw SnapshotError.manifestMismatch(stored: metadata.manifestDigest, current: manifestDigest)
        }
        guard metadata.guestAssetVersion >= minimumAssetVersionFloor,
              metadata.guestAssetVersion == guestAssetVersion else {
            throw SnapshotError.assetVersionStale(stored: metadata.guestAssetVersion, floor: minimumAssetVersionFloor)
        }
        if let chain = releaseKeys {
            guard let key = chain.keys.first(where: { $0.keyID == metadata.keyID }) else {
                throw SnapshotError.keyUnknown(metadata.keyID)
            }
            if key.status == .revoked { throw SnapshotError.keyRevoked(metadata.keyID) }
        }
    }
}
