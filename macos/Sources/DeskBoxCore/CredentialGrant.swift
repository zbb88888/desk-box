import Foundation

/// Grant 的主体（架构 §5.3：绑定用户、工作区、sandbox、Agent）。
public struct Principal: Sendable, Codable, Equatable, Hashable {
    public let userID: UserID
    public let workspaceID: WorkspaceID
    public let sandboxID: SandboxID
    public let agentID: AgentID

    public init(userID: UserID, workspaceID: WorkspaceID, sandboxID: SandboxID, agentID: AgentID) {
        self.userID = userID
        self.workspaceID = workspaceID
        self.sandboxID = sandboxID
        self.agentID = agentID
    }
}

/// 凭据注入形态。Grant 只引用逻辑凭据，不承载真实值（架构 §5.3）。
public enum InjectionForm: Sendable, Codable, Equatable, Hashable {
    /// 只允许目标级联网，不注入任何凭据。
    case none
    case bearer
    case apiHeader(name: String)
}

public struct NetworkTarget: Sendable, Codable, Equatable {
    public let scheme: String
    public let host: String
    public let port: UInt16?
    public let method: String
    public let path: String

    public init(scheme: String, host: String, port: UInt16?, method: String, path: String) {
        self.scheme = scheme.lowercased()
        var normalizedHost = host.lowercased()
        while normalizedHost.hasSuffix(".") { normalizedHost.removeLast() }
        self.host = normalizedHost
        self.port = port
        self.method = method.uppercased()
        self.path = path.isEmpty ? "/" : path
    }
}

/// CredentialGrant（架构 §5.3、威胁模型 §6）。
/// 同时绑定主体、scheme、host、有效端口、method、path、注入形态与期限；
/// 撤销/过期/suspend 后默认失效（由使用方在评估时传入当前时间与主体）。
public struct CredentialGrant: Sendable, Codable, Equatable, Identifiable {
    public let id: GrantID
    public let subject: Principal
    public let scheme: String
    public let host: String
    public let port: UInt16?
    public let method: String
    public let pathPrefix: String
    public let injection: InjectionForm
    public let issuedAt: Date
    public let expiresAt: Date
    public let maxUses: Int?
    public let rateLimitPerMinute: Int?

    /// 建構即规范化与校验；非法 grant 不存在（威胁模型 §6-2 的结构性保证）。
    public init(
        id: GrantID,
        subject: Principal,
        scheme: String,
        host: String,
        port: UInt16?,
        method: String,
        pathPrefix: String,
        injection: InjectionForm,
        issuedAt: Date,
        expiresAt: Date,
        maxUses: Int? = nil,
        rateLimitPerMinute: Int? = nil
    ) throws {
        let normalizedScheme = scheme.lowercased()
        var normalizedHost = host.lowercased()
        while normalizedHost.hasSuffix(".") { normalizedHost.removeLast() }
        guard !normalizedScheme.isEmpty, !normalizedHost.isEmpty else {
            throw SandboxFailure(.grantInvalid, "scheme/host 不能为空")
        }
        guard normalizedHost.range(of: #"^[a-z0-9._-]+$"#, options: .regularExpression) != nil
            || normalizedHost.range(of: #"^[0-9a-f:.\[\]%]+$"#, options: .regularExpression) != nil
        else {
            throw SandboxFailure(.grantInvalid, "host 含非法字符：\(host)")
        }
        guard pathPrefix.hasPrefix("/") else {
            throw SandboxFailure(.grantInvalid, "pathPrefix 必须以 / 开头：\(pathPrefix)")
        }
        guard expiresAt > issuedAt else {
            throw SandboxFailure(.grantInvalid, "expiresAt 必须晚于 issuedAt")
        }
        if case .apiHeader(let name) = injection {
            guard !name.isEmpty, name.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else {
                throw SandboxFailure(.grantInvalid, "非法 header 名：\(name)")
            }
        }
        self.id = id
        self.subject = subject
        self.scheme = normalizedScheme
        self.host = normalizedHost
        self.port = port
        self.method = method.uppercased()
        self.pathPrefix = pathPrefix
        self.injection = injection
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.maxUses = maxUses
        self.rateLimitPerMinute = rateLimitPerMinute
    }

    /// 单 grant 匹配。redirect 后的新目标必须重新评估（威胁模型 §6-4），
    /// 因此匹配不包含跨请求状态；次数/速率限制由 Broker 单独跟踪。
    public func matches(_ target: NetworkTarget, for subject: Principal, at now: Date) -> Decision {
        guard now >= issuedAt else {
            return .error(.grantNotYetValid, "grant 尚未生效，状态按不明处理")
        }
        guard now < expiresAt else {
            return .deny(.grantExpired, "grant 已过期")
        }
        guard subject == self.subject else {
            return .deny(.grantSubjectMismatch, "grant 不属于当前 user/workspace/sandbox/agent")
        }
        guard target.scheme == scheme else {
            return .deny(.grantTargetMismatch, "scheme 不匹配：\(target.scheme) != \(scheme)")
        }
        guard target.host == host else {
            return .deny(.grantTargetMismatch, "host 不匹配：\(target.host) != \(host)")
        }
        let targetPort = target.port ?? Self.defaultPort(for: target.scheme)
        let grantPort = port ?? Self.defaultPort(for: scheme)
        guard targetPort == grantPort else {
            return .deny(.grantTargetMismatch, "端口不匹配")
        }
        guard method == "*" || target.method == method else {
            return .deny(.grantTargetMismatch, "method 不匹配：\(target.method) != \(method)")
        }
        guard target.path.hasPrefix(pathPrefix) else {
            return .deny(.grantTargetMismatch, "path 越界：\(target.path) 不在 \(pathPrefix) 内")
        }
        return .allow()
    }

    public static func defaultPort(for scheme: String) -> UInt16? {
        switch scheme.lowercased() {
        case "http": return 80
        case "https": return 443
        case "ssh": return 22
        default: return nil
        }
    }
}

/// 多 grant 解析（威胁模型 §6-6）：相同请求匹配多个互不等价 grant 时拒绝。
public enum GrantResolver {
    public struct Resolution: Sendable, Equatable {
        public let decision: Decision
        public let grant: CredentialGrant?
    }

    public static func resolve(
        grants: [CredentialGrant],
        target: NetworkTarget,
        subject: Principal,
        at now: Date
    ) -> Resolution {
        var matched: [CredentialGrant] = []
        var sawExpired = false
        for grant in grants {
            let decision = grant.matches(target, for: subject, at: now)
            if decision.isAllowed {
                matched.append(grant)
            }
            if decision.reasonCode == .grantExpired {
                sawExpired = true
            }
        }
        guard !matched.isEmpty else {
            if sawExpired {
                return Resolution(decision: .deny(.grantExpired, "目标仅由已过期 grant 覆盖"), grant: nil)
            }
            return Resolution(decision: .deny(.grantNotFound, "没有允许该目标的 grant"), grant: nil)
        }
        let first = matched[0]
        let distinctBindings = Set(matched.map { BindingKey($0) })
        guard distinctBindings.count == 1 else {
            return Resolution(decision: .deny(.grantAmbiguous, "多个互不等价 grant 同时匹配，按歧义拒绝"), grant: nil)
        }
        return Resolution(decision: .allow(), grant: first)
    }

    private struct BindingKey: Hashable {
        let subject: Principal
        let scheme: String
        let host: String
        let port: UInt16?
        let method: String
        let pathPrefix: String
        let injection: InjectionForm

        init(_ grant: CredentialGrant) {
            subject = grant.subject
            scheme = grant.scheme
            host = grant.host
            port = grant.port
            method = grant.method
            pathPrefix = grant.pathPrefix
            injection = grant.injection
        }
    }
}
