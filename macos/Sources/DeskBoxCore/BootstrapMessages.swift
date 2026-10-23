import Foundation

/// Bootstrap message payloads. These are intentionally separate from
/// `BootstrapProof`: a hello is guest-reported identity, not attestation.
public struct BootstrapHello: Sendable, Codable, Equatable {
    public let sandboxID: SandboxID
    public let bootID: BootID
    public let bootNonce: UUID
    public let protocolMajor: Int
    public let guestManifestDigest: String

    public init(
        sandboxID: SandboxID,
        bootID: BootID,
        bootNonce: UUID,
        protocolMajor: Int,
        guestManifestDigest: String
    ) {
        self.sandboxID = sandboxID
        self.bootID = bootID
        self.bootNonce = bootNonce
        self.protocolMajor = protocolMajor
        self.guestManifestDigest = guestManifestDigest
    }

    public init(context: BootContext) {
        self.sandboxID = context.sandboxID
        self.bootID = context.bootID
        self.bootNonce = context.bootNonce
        self.protocolMajor = context.protocolMajor
        self.guestManifestDigest = context.guestManifestDigest
    }

    public func bindingDecision(against context: BootContext) -> Decision {
        guard protocolMajor == context.protocolMajor,
              sandboxID == context.sandboxID,
              bootID == context.bootID,
              bootNonce == context.bootNonce,
              guestManifestDigest == context.guestManifestDigest
        else {
            return .deny(.bootstrapProofMismatch, "guest hello 与当前 boot 上下文不匹配")
        }
        return .allow(reason: .bootstrapHelloAccepted, message: "")
    }
}

public struct BootstrapHelloAck: Sendable, Codable, Equatable {
    public let sessionID: SessionID
    public let requiresTLS: Bool
    public let protocolMajor: Int

    public init(sessionID: SessionID, requiresTLS: Bool = true, protocolMajor: Int = ControlChannelProtocol.currentMajor) {
        self.sessionID = sessionID
        self.requiresTLS = requiresTLS
        self.protocolMajor = protocolMajor
    }
}

public enum BootstrapCodec {
    public static func encodeHello(_ hello: BootstrapHello) throws -> Data {
        try JSONEncoder().encode(hello)
    }

    public static func decodeHello(_ data: Data) throws -> BootstrapHello {
        try JSONDecoder().decode(BootstrapHello.self, from: data)
    }

    public static func encodeAck(_ ack: BootstrapHelloAck) throws -> Data {
        try JSONEncoder().encode(ack)
    }

    public static func decodeAck(_ data: Data) throws -> BootstrapHelloAck {
        try JSONDecoder().decode(BootstrapHelloAck.self, from: data)
    }
}
