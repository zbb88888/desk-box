import Foundation

/// 每次启动的身份材料（docs/design/control-channel-security.md §3-5）。
/// BootContext 由宿主在启动前生成；guest 自报字段不属于 attestation，
/// 只用于发现配置错误与协议串线。
public struct BootContext: Sendable, Codable, Equatable {
    public let sandboxID: SandboxID
    public let bootID: BootID
    public let bootNonce: UUID
    public let protocolMajor: Int
    public let guestManifestDigest: String

    public init(
        sandboxID: SandboxID,
        bootID: BootID = .new(),
        bootNonce: UUID = UUID(),
        protocolMajor: Int,
        guestManifestDigest: String
    ) {
        self.sandboxID = sandboxID
        self.bootID = bootID
        self.bootNonce = bootNonce
        self.protocolMajor = protocolMajor
        self.guestManifestDigest = guestManifestDigest
    }
}

/// guest 握手后回呈的身份证明。bind 到当前 boot，不能跨 VM/跨 boot 重放。
public struct BootstrapProof: Sendable, Codable, Equatable {
    public let sandboxID: SandboxID
    public let bootID: BootID
    public let bootNonce: UUID
    public let protocolMajor: Int
    public let guestManifestDigest: String
    public let sessionID: SessionID

    public init(
        sandboxID: SandboxID,
        bootID: BootID,
        bootNonce: UUID,
        protocolMajor: Int,
        guestManifestDigest: String,
        sessionID: SessionID
    ) {
        self.sandboxID = sandboxID
        self.bootID = bootID
        self.bootNonce = bootNonce
        self.protocolMajor = protocolMajor
        self.guestManifestDigest = guestManifestDigest
        self.sessionID = sessionID
    }

    /// 绑定检查；任何层级不匹配都拒绝（双层模型 §7.1）。
    public static func verify(
        _ proof: BootstrapProof,
        against context: BootContext,
        expectedProtocolMajor: Int
    ) -> Decision {
        guard proof.protocolMajor == expectedProtocolMajor else {
            return .error(.bootstrapProofMismatch, "协议主版本不兼容：\(proof.protocolMajor) != \(expectedProtocolMajor)")
        }
        guard proof.sandboxID == context.sandboxID,
              proof.bootID == context.bootID,
              proof.bootNonce == context.bootNonce,
              proof.guestManifestDigest == context.guestManifestDigest
        else {
            return .deny(.bootstrapProofMismatch, "proof 与当前 boot 上下文不匹配，疑似串线或重放")
        }
        return .allow(reason: .bootstrapProofAccepted, message: "")
    }
}

/// 当前控制通道协议主版本。与 control-channel-security 设计文档保持一致；
/// 降级协商被禁止，不兼容必须失败关闭。
public enum ControlChannelProtocol {
    public static let currentMajor = 1
}
