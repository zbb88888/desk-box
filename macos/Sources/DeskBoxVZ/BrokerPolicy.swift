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
        return .allow
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
