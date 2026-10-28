import Foundation

/// Egress Broker 策略（docs/design/m2-3-network-credential-broker.md，INV-03/INV-04）。
/// 读取失败即默认拒。任何域不在 allowlist 或未启用 HTTPS 都被拒。
public struct BrokerPolicy: Sendable, Equatable, Codable {
    public let allowedHosts: [String]
    public let allowedSchemes: [String]
    public let maxResponseBytes: UInt64

    public init(allowedHosts: [String], allowedSchemes: [String] = ["https"], maxResponseBytes: UInt64 = 65_536) {
        self.allowedHosts = allowedHosts
        self.allowedSchemes = allowedSchemes
        self.maxResponseBytes = maxResponseBytes
    }

    public static func load(from url: URL) throws -> BrokerPolicy {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw BrokerPolicyError.fileMissing(url.path)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BrokerPolicy.self, from: data)
    }

    public func decision(for url: URL) -> BrokerDecision {
        decision(for: url, resolvedAddresses: nil)
    }

    /// M19：允许调用方把 DNS 解析结果一并送进来。只要**任一**解析地址落在
    /// 私网/环回/链路本地/未指定地址，就拒绝——这是 DNS rebinding 的防线：
    /// allowlist 里的域名被投毒后不能直接打宿主内网。
    public func decision(for url: URL, resolvedAddresses: [String]?) -> BrokerDecision {
        guard let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else {
            return .deny(reason: "scheme 不允许")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return .deny(reason: "host 缺失")
        }
        guard allowedHosts.contains(host) else {
            return .deny(reason: "host 不在 allowlist: \(host)")
        }
        if let addresses = resolvedAddresses, !addresses.isEmpty {
            for address in addresses where Self.isPrivateOrLoopback(address) {
                return .deny(reason: "解析地址落在私网/环回: \(address)")
            }
        }
        return .allow
    }

    /// IPv4 / IPv6 统一入口（用于把解析结果直接丢进来）。
    public static func isPrivateOrLoopback(_ address: String) -> Bool {
        address.contains(":") ? isPrivateOrLoopbackIPv6(address) : isPrivateOrLoopbackIPv4(address)
    }

    public static func isPrivateOrLoopbackIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard let value = Int(part), (0...255).contains(value) else { return false }
            octets.append(value)
        }
        let (a, b) = (octets[0], octets[1])
        if a == 0 { return true }        // 0.0.0.0/8（未指定/本网络）
        if a == 10 { return true }       // 10/8
        if a == 127 { return true }      // 环回
        if a == 169 && b == 254 { return true } // 链路本地 + 云 metadata
        if a == 172 && (16...31).contains(b) { return true } // 172.16/12
        if a == 192 && b == 168 { return true } // 192.168/16
        if a == 100 && (64...127).contains(b) { return true } // 100.64/10 CGNAT
        if a >= 224 { return true }      // 组播/保留
        return false
    }

    public static func isPrivateOrLoopbackIPv6(_ address: String) -> Bool {
        let lower = address.lowercased()
        if lower == "::" || lower == "::1" { return true }
        if lower.hasPrefix("fe80") { return true }  // 链路本地
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true } // ULA
        if lower.hasPrefix("ff") { return true }    // 组播
        // IPv4-mapped（::ffff:127.0.0.1）按内嵌 IPv4 判定。
        if let range = lower.range(of: "::ffff:") {
            return isPrivateOrLoopbackIPv4(String(lower[range.upperBound...]))
        }
        return false
    }

    public enum BrokerPolicyError: Error, Equatable, CustomStringConvertible {
        case fileMissing(String)
        public var description: String {
            switch self {
            case .fileMissing(let p): return "broker policy 缺失: \(p)"
            }
        }
    }

    public enum BrokerDecision: Sendable, Equatable {
        case allow
        case deny(reason: String)

        public var isAllowed: Bool { self == .allow }
    }
}
