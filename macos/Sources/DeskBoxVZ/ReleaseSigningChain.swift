import DeskBoxCore
import Foundation

/// Release 签名链（docs/design/m5-release-signing-chain.md）。
/// 智能构建期间（本地 dev chain）该由 `release-keys.json` 提供 metadata；release 将由 host 内嵌生成文件提供。
public struct ReleaseKeysManifest: Sendable, Equatable, Codable {
    public static let schemaValue = "deskbox-release-keys/v1"
    public let schema: String
    public let generatedAtUtc: String
    public var keys: [Key]

    public init(schema: String, generatedAtUtc: String, keys: [Key]) {
        self.schema = schema
        self.generatedAtUtc = generatedAtUtc
        self.keys = keys
    }

    public struct Key: Sendable, Equatable, Codable {
        public let keyID: String
        public let publicHex: String
        public let status: Status
        public let notBefore: String
        public let notAfter: String?
        public let note: String?

        public init(keyID: String, publicHex: String, status: Status,
                    notBefore: String, notAfter: String? = nil, note: String? = nil) {
            self.keyID = keyID
            self.publicHex = publicHex
            self.status = status
            self.notBefore = notBefore
            self.notAfter = notAfter
            self.note = note
        }

        public enum Status: String, Sendable, Equatable, Codable {
            case active
            case retired
            case revoked
        }
    }
}

public enum ReleaseSigningChainError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case unknownKey(String)
    case revokedKey(String)
    case notYetActive(keyID: String, notBefore: String)
    case expired(keyID: String, notAfter: String)

    public var description: String {
        switch self {
        case .malformed(let r): return "release keys manifest 非法: \(r)"
        case .unknownKey(let k): return "未知 release keyID: \(k)"
        case .revokedKey(let k): return "key 已 revoked: \(k)"
        case .notYetActive(let k, let t): return "key 尚未生效: \(k) notBefore=\(t)"
        case .expired(let k, let t): return "key 已过期: \(k) notAfter=\(t)"
        }
    }
}

public extension ReleaseKeysManifest {
    func usablePublicHex(forKeyID keyID: String, at date: Date = Date()) throws -> String {
        guard let key = keys.first(where: { $0.keyID == keyID }) else {
            throw ReleaseSigningChainError.unknownKey(keyID)
        }
        switch key.status {
        case .revoked:
            throw ReleaseSigningChainError.revokedKey(key.keyID)
        case .active, .retired:
            if let notBefore = ISO8601DateFormatter().date(from: key.notBefore), date < notBefore {
                throw ReleaseSigningChainError.notYetActive(keyID: key.keyID, notBefore: key.notBefore)
            }
            if let notAfterStr = key.notAfter,
               let notAfter = ISO8601DateFormatter().date(from: notAfterStr), date >= notAfter {
                throw ReleaseSigningChainError.expired(keyID: key.keyID, notAfter: notAfterStr)
            }
            return key.publicHex
        }
    }

    var activeKeyIDs: [String] {
        keys.filter { $0.status == .active }.map(\.keyID)
    }

    /// M22：判断单把 key 在给定时刻是否可用于「发布面」验证（active/retired 且在有效期内）。
    static func isUsable(_ key: Key, at date: Date = Date()) -> Bool {
        guard key.status != .revoked else { return false }
        let fmt = ISO8601DateFormatter()
        if let notBefore = fmt.date(from: key.notBefore), date < notBefore { return false }
        if let notAfterStr = key.notAfter, let notAfter = fmt.date(from: notAfterStr), date >= notAfter {
            return false
        }
        return true
    }
}
