import Foundation

/// Bootstrap message payloads. These are intentionally separate from
/// `BootstrapProof`: a hello is guest-reported identity, not attestation.
public struct BootstrapHello: Sendable, Codable, Equatable {
    // Guest bootstrap uses the stable v1 wire shape. Swift's default Codable
    // would encode UUID as base64 data, which is not the documented contract.
    enum CodingKeys: String, CodingKey {
        case sandboxID
        case bootID
        case bootNonce
        case protocolMajor
        case guestManifestDigest
    }

    private struct Ref: Codable {
        var raw: String
    }

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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sandboxID = SandboxID(try container.decode(Ref.self, forKey: .sandboxID).raw)
        bootID = BootID(try container.decode(Ref.self, forKey: .bootID).raw)
        let nonceString = try container.decode(String.self, forKey: .bootNonce)
        guard let nonce = UUID(uuidString: nonceString) else {
            throw DecodingError.dataCorruptedError(forKey: .bootNonce, in: container, debugDescription: "invalid boot nonce")
        }
        bootNonce = nonce
        protocolMajor = try container.decode(Int.self, forKey: .protocolMajor)
        guestManifestDigest = try container.decode(String.self, forKey: .guestManifestDigest)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Ref(raw: sandboxID.raw), forKey: .sandboxID)
        try container.encode(Ref(raw: bootID.raw), forKey: .bootID)
        try container.encode(bootNonce.uuidString, forKey: .bootNonce)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(guestManifestDigest, forKey: .guestManifestDigest)
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
    /// Optional host X25519 public key for the M1-2 record-protection upgrade.
    /// Present only when the host intends to start the encrypted session.
    public let hostKeyPublicHex: String?

    public init(
        sessionID: SessionID,
        requiresTLS: Bool = true,
        protocolMajor: Int = ControlChannelProtocol.currentMajor,
        hostKeyPublicHex: String? = nil
    ) {
        self.sessionID = sessionID
        self.requiresTLS = requiresTLS
        self.protocolMajor = protocolMajor
        self.hostKeyPublicHex = hostKeyPublicHex
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
