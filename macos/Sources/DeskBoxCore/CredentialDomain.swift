import Foundation

/// 凭据域（M23 / INV-02，docs/design/m23-credential-domains.md）。
///
/// 不变量：**不同凭据域不共享 guest kernel**。域是一等概念，绑定三件事：
/// 1. 该域使用哪份 broker 出口策略（null = 该域禁止出站）；
/// 2. 该域使用哪份 broker 凭据表（null = 该域无凭据，只能匿名请求）；
/// 3. 该域额外信任哪些 release key（叠加在既有签名链之上）。
///
/// 解析纪律（fail-closed）：域未声明、schema 不符、字段越界都抛错；
/// 绝不「回退到默认域」——默认域只在**创建**时用于补全省略，且必须显式配置。
public struct CredentialDomainID: Sendable, Hashable, Codable, CustomStringConvertible, Comparable {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public var description: String { raw }

    /// 允许字符：小写字母、数字、`-`、`_`；长度 1...32。
    /// 域 ID 会进入路径（凭据文件名、快照 AAD、决策记录），因此必须限制字符集。
    public var isValid: Bool {
        guard !raw.isEmpty, raw.count <= 32 else { return false }
        return raw.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    public static func < (lhs: CredentialDomainID, rhs: CredentialDomainID) -> Bool {
        lhs.raw < rhs.raw
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.raw = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

public struct CredentialDomain: Sendable, Codable, Equatable {
    public let domainID: CredentialDomainID
    /// 相对宿主 credential root 的文件名；nil 表示该域禁止任何出站。
    public let brokerPolicyFile: String?
    /// 相对宿主 credential root 的文件名；nil 表示该域不携带任何长期凭据。
    public let brokerCredentialsFile: String?
    /// 额外信任的 release key ID（空 = 不额外限制，manifest 签名链仍需通过）。
    public let allowedSigningKeyIDs: [String]

    public init(domainID: CredentialDomainID,
                brokerPolicyFile: String? = nil,
                brokerCredentialsFile: String? = nil,
                allowedSigningKeyIDs: [String] = []) {
        self.domainID = domainID
        self.brokerPolicyFile = brokerPolicyFile
        self.brokerCredentialsFile = brokerCredentialsFile
        self.allowedSigningKeyIDs = allowedSigningKeyIDs
    }

    /// 该域是否允许联网（有策略文件）。
    public var allowsEgress: Bool { brokerPolicyFile != nil }

    private enum CodingKeys: String, CodingKey {
        case domainID, brokerPolicyFile, brokerCredentialsFile, allowedSigningKeyIDs
    }

    /// 手写解码：`brokerPolicyFile` / `brokerCredentialsFile` / `allowedSigningKeyIDs`
    /// 都允许省略（手写 domains.json 时最省事，也避免「忘记写数组就整份配置失效」）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domainID = try c.decode(CredentialDomainID.self, forKey: .domainID)
        brokerPolicyFile = try c.decodeIfPresent(String.self, forKey: .brokerPolicyFile)
        brokerCredentialsFile = try c.decodeIfPresent(String.self, forKey: .brokerCredentialsFile)
        allowedSigningKeyIDs = try c.decodeIfPresent([String].self, forKey: .allowedSigningKeyIDs) ?? []
    }
}

public enum DomainResolutionError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case unknownDomain(String)
    case invalidDomainID(String)
    case policyMissing(domain: String, file: String)
    case policyEscapesCredentialRoot(domain: String, file: String)
    case noDefaultDomain

    public var description: String {
        switch self {
        case .malformed(let r): return "domains.json 非法: \(r)"
        case .unknownDomain(let d): return "未知凭据域: \(d)"
        case .invalidDomainID(let d): return "凭据域 ID 非法（应匹配 [a-z0-9_-]{1,32}）: \(d)"
        case .policyMissing(let d, let f): return "凭据域 \(d) 的策略文件不存在: \(f)"
        case .policyEscapesCredentialRoot(let d, let f):
            return "凭据域 \(d) 的文件路径越出凭据根目录: \(f)"
        case .noDefaultDomain: return "未指定 domain 且 domains.json 未配置 defaultDomain"
        }
    }

    /// 稳定原因码（供 CLI/GUI/证据引用）。
    public var reasonCode: String {
        switch self {
        case .malformed: return "domain-malformed"
        case .unknownDomain: return "domain-unknown"
        case .invalidDomainID: return "domain-invalid-id"
        case .policyMissing: return "domain-policy-missing"
        case .policyEscapesCredentialRoot: return "domain-path-escape"
        case .noDefaultDomain: return "domain-not-specified"
        }
    }
}

/// `domains.json` 的磁盘形态。
public struct CredentialDomainsManifest: Sendable, Codable, Equatable {
    public static let schemaValue = "deskbox-domains/v1"

    public let schema: String
    public let defaultDomain: CredentialDomainID?
    public let domains: [CredentialDomain]

    public init(schema: String = CredentialDomainsManifest.schemaValue,
                defaultDomain: CredentialDomainID? = nil,
                domains: [CredentialDomain] = []) {
        self.schema = schema
        self.defaultDomain = defaultDomain
        self.domains = domains
    }

    /// 内置的单域默认值：不写 `domains.json` 时的行为与 M23 之前一致
    /// （单域 `default`，不携带任何凭据，出口策略沿用调用方传入的路径）。
    public static let singleDefault = CredentialDomainsManifest(
        defaultDomain: CredentialDomainID("default"),
        domains: [CredentialDomain(domainID: CredentialDomainID("default"))]
    )
}

/// 域注册表：加载 + 校验 + 解析。所有失败都是拒绝，没有「宽松模式」。
public struct DomainRegistry: Sendable {
    public let manifest: CredentialDomainsManifest
    /// 凭据根目录：broker policy/credentials 的相对路径以此为准。
    public let credentialRoot: URL

    public init(manifest: CredentialDomainsManifest, credentialRoot: URL) {
        self.manifest = manifest
        self.credentialRoot = credentialRoot
    }

    public var domains: [CredentialDomain] { manifest.domains }
    public var defaultDomain: CredentialDomainID? { manifest.defaultDomain }

    public static func load(from url: URL, credentialRoot: URL) throws -> DomainRegistry {
        let data = try Data(contentsOf: url)
        let manifest: CredentialDomainsManifest
        do {
            manifest = try JSONDecoder().decode(CredentialDomainsManifest.self, from: data)
        } catch {
            throw DomainResolutionError.malformed(error.localizedDescription)
        }
        return try DomainRegistry(manifest: manifest, credentialRoot: credentialRoot).validated()
    }

    /// 校验 schema、域 ID 合法性与唯一性、文件路径不越界。
    public func validated() throws -> DomainRegistry {
        guard manifest.schema == CredentialDomainsManifest.schemaValue else {
            throw DomainResolutionError.malformed("schema=\(manifest.schema)")
        }
        var seen: Set<String> = []
        for domain in manifest.domains {
            guard domain.domainID.isValid else {
                throw DomainResolutionError.invalidDomainID(domain.domainID.raw)
            }
            guard seen.insert(domain.domainID.raw).inserted else {
                throw DomainResolutionError.malformed("重复的 domainID: \(domain.domainID.raw)")
            }
            for file in [domain.brokerPolicyFile, domain.brokerCredentialsFile].compactMap({ $0 }) {
                try Self.validateRelativeFileName(file, domain: domain.domainID)
            }
        }
        if let defaultDomain = manifest.defaultDomain, !manifest.domains.contains(where: { $0.domainID == defaultDomain }) {
            throw DomainResolutionError.unknownDomain(defaultDomain.raw)
        }
        return self
    }

    /// 文件名必须是单一相对路径分量（不允许 `..`/`/`/绝对路径），防止越出凭据根目录。
    static func validateRelativeFileName(_ file: String, domain: CredentialDomainID) throws {
        guard !file.isEmpty,
              !file.hasPrefix("/"),
              !file.contains(".."),
              !file.contains("/"),
              !file.contains("\\") else {
            throw DomainResolutionError.policyEscapesCredentialRoot(domain: domain.raw, file: file)
        }
    }

    /// 解析域；`nil` 时只在**创建**路径上使用 `defaultDomain`。
    public func resolve(_ requested: CredentialDomainID?) throws -> CredentialDomain {
        guard let id = requested ?? manifest.defaultDomain else {
            throw DomainResolutionError.noDefaultDomain
        }
        guard id.isValid else { throw DomainResolutionError.invalidDomainID(id.raw) }
        guard let domain = manifest.domains.first(where: { $0.domainID == id }) else {
            throw DomainResolutionError.unknownDomain(id.raw)
        }
        return domain
    }

    /// 解析并确认策略文件存在（供 broker 使用；缺文件即拒绝，不静默无网）。
    public func resolveForBroker(_ requested: CredentialDomainID?) throws -> (domain: CredentialDomain, policyURL: URL?, credentialsURL: URL?) {
        let domain = try resolve(requested)
        var policyURL: URL?
        if let file = domain.brokerPolicyFile {
            let url = credentialRoot.appendingPathComponent(file)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw DomainResolutionError.policyMissing(domain: domain.domainID.raw, file: file)
            }
            policyURL = url
        }
        var credentialsURL: URL?
        if let file = domain.brokerCredentialsFile {
            let url = credentialRoot.appendingPathComponent(file)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw DomainResolutionError.policyMissing(domain: domain.domainID.raw, file: file)
            }
            credentialsURL = url
        }
        return (domain, policyURL, credentialsURL)
    }
}
