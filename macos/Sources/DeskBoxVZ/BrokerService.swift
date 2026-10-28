import CryptoKit
import Foundation

/// Credential Broker（INV-03）：token 只放宿主；只对 allowlisted host 加注 Authorization 头。
public struct CredentialBroker: Sendable {
    /// host -> "Bearer xxx" 格式的注入 value。
    public let tokenByHost: [String: String]

    public init(tokenByHost: [String: String]) { self.tokenByHost = tokenByHost }

    public static func load(from url: URL) -> CredentialBroker {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return CredentialBroker(tokenByHost: [:])
        }
        return CredentialBroker(tokenByHost: map)
    }

    /// Returns headers to inject; sneaky host mismatch 不会被 token 触碰。
    public func authorizationHeader(forHost host: String) -> String? {
        tokenByHost[host.lowercased()]
    }
}

public struct BrokerFetchReport: Sendable, Equatable {
    public let url: URL
    public let statusCode: Int
    public let contentType: String?
    public let bytes: UInt64
    public let sha256Hex: String
    public let truncated: Bool
    public let decision: String

    public init(url: URL, statusCode: Int, contentType: String?, bytes: UInt64, sha256Hex: String, truncated: Bool, decision: String) {
        self.url = url
        self.statusCode = statusCode
        self.contentType = contentType
        self.bytes = bytes
        self.sha256Hex = sha256Hex
        self.truncated = truncated
        self.decision = decision
    }
}

public enum BrokerError: Error, Equatable, CustomStringConvertible {
    case policyDenied(String)
    case badStatus(Int)

    public var description: String {
        switch self {
        case .policyDenied(let r): return "broker 拒绝出站: \(r)"
        case .badStatus(let s): return "broker 非 2xx: \(s)"
        }
    }
}

public actor BrokerService {
    private let policy: BrokerPolicy
    private let credentials: CredentialBroker
    private let session: URLSession

    public init(policy: BrokerPolicy, credentials: CredentialBroker, session: URLSession = .shared) {
        self.policy = policy
        self.credentials = credentials
        self.session = session
    }

    public func fetch(_ url: URL) async throws -> (data: Data, report: BrokerFetchReport) {
        // 1) Policy gate（fail-closed）。M19：先解析域名，把地址一并交给策略判定，
        //    防止 allowlist 内域名被 DNS rebinding 到私网/环回。
        let resolved = url.host.map { BrokerService.resolveAddresses(host: $0) } ?? []
        let decision = policy.decision(for: url, resolvedAddresses: resolved.isEmpty ? nil : resolved)
        guard decision.isAllowed else {
            if case .deny(let reason) = decision { throw BrokerError.policyDenied(reason) }
            throw BrokerError.policyDenied("denied")
        }
        // 2) 注凭据：只对 allowlisted host 注入，绝不写入磁盘/日志。
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let host = url.host?.lowercased(), let bearer = credentials.authorizationHeader(forHost: host) {
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
        }
        // 3) 拉取。
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BrokerError.badStatus(-1) }
        guard (200..<300).contains(http.statusCode) else { throw BrokerError.badStatus(http.statusCode) }
        let cap = policy.maxResponseBytes
        let truncated = UInt64(data.count) > cap
        let body = truncated ? data.prefix(Int(cap)) : data
        let sha = BrokerService.sha256Hex(Data(body))
        let report = BrokerFetchReport(
            url: url, statusCode: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            bytes: UInt64(body.count), sha256Hex: sha, truncated: truncated,
            decision: "allow"
        )
        return (Data(body), report)
    }
}

extension BrokerService {
    /// 解析 host 的全部 A/AAAA 记录（返回字符串形式）。解析失败返回空数组。
    static func resolveAddresses(host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }
        var addresses: [String] = []
        var cursor = result
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: buffer)
                if !addresses.contains(text) { addresses.append(text) }
            }
            cursor = info.pointee.ai_next
        }
        return addresses
    }

    static func sha256Hex(_ data: Data) -> String {
        var hasher = CryptoKit.SHA256()
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
