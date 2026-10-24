import Foundation
import CryptoKit
import DeskBoxCore

/// Encrypted control-channel session for the M1-2 upgrade.
///
/// Construction (docs/design/m1-tls-channel-upgrade.md):
/// - The host generates an ephemeral X25519 keypair per boot and ships its
///   public key inside `BootstrapHelloAck`;
/// - The guest generates its own ephemeral X25519 keypair and ships its public
///   key to the host inside the (plaintext) `keyExchange` frame;
/// - Both sides derive the record protection key via
///   X25519 + HKDF-SHA256; ChaChaPoly AEAD seals each frame with a direction
///   namespaced 96-bit nonce (integrity + replay protection);
/// - `sessionBinding.sessionID` is derived from both public keys and the boot
///   context so older boots' material can't be replayed;
/// - All post-upgrade frames flow over this protected channel (fail closed if
///   any decryption fails).
///
/// This is the record-protection and session-binding core of M1-2. An X.509
/// certificate envelope + true TLS 1.3 framing is a separate hardening step
/// (see doc §1 boundary) and does not change this protocol's input contract.
final class SecureRecordSession: @unchecked Sendable {
    private var key: SymmetricKey?
    private let hostPrivateKey: Curve25519.KeyAgreement.PrivateKey

    private(set) var hostPublicHex: String
    private(set) var guestPublicHex: String?
    private(set) var sessionBinding: SessionBinding?

    private var outboundCounter: UInt64 = 0

    private static let directionOutboundToGuest: [UInt8] = [0x01, 0x00, 0x00, 0x00]
    private static let directionInboundFromGuest: [UInt8] = [0x02, 0x00, 0x00, 0x00]

    init(context: BootContext) {
        let keyPair = Curve25519.KeyAgreement.PrivateKey()
        self.hostPrivateKey = keyPair
        self.hostPublicHex = Data(keyPair.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined()
        self.key = nil
    }

    /// Finish the key exchange once the guest's ephemeral public key arrives
    /// (32-byte X25519 public key in request payload). Both public keys and the
    /// boot context are mixed into the session binding.
    func completeKeyExchange(guestPublicData: Data, boot context: BootContext) throws {
        try completeKeyExchange(
            guestPublicHex: guestPublicData.map { String(format: "%02x", $0) }.joined(),
            boot: context
        )
    }

    func completeKeyExchange(guestPublicHex: String, boot context: BootContext) throws {
        guard guestPublicHex.count == 64,
              let guestPublicData = Data(hexString: guestPublicHex),
              guestPublicData.count == 32,
              let guestPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: guestPublicData)
        else {
            throw SandboxFailure(.bootstrapTLSRequired, "guest key exchange payload is not a valid X25519 public key")
        }
        let sharedSecret = try hostPrivateKey.sharedSecretFromKeyAgreement(with: guestPublicKey)
        self.key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("deskbox-m1-tls-v1".utf8),
            sharedInfo: Data("record-protection-v1".utf8),
            outputByteCount: 32
        )
        self.guestPublicHex = guestPublicHex
        self.sessionBinding = SessionBinding(
            hostFingerprintHex: hostPublicHexUnbase,
            guestFingerprintHex: guestPublicHex,
            sessionID: SessionBinding.deriveSessionID(
                hostFingerprintHex: hostPublicHexUnbase,
                guestFingerprintHex: guestPublicHex,
                context: context
            )
        )
    }

    var hostPublicHexUnbase: String { hostPublicHex }

    /// Protect a frame for transport. Guarded by outer sequence numbers in
    /// ControlSequenceGuard; the AEAD also authenticates direction+counter.
    func encrypt(frameData: Data) throws -> Data {
        guard sessionBinding != nil else {
            throw SandboxFailure(.bootstrapTLSRequired, "key exchange not completed")
        }
        let nonce = Self.nonce(direction: Self.directionOutboundToGuest, counter: outboundCounter)
        outboundCounter += 1
        guard let protectKey = key else {
            throw SandboxFailure(.bootstrapTLSRequired, "record key unavailable")
        }
        let sealed = try ChaChaPoly.seal(frameData, using: protectKey, nonce: nonce, authenticating: Data())
        return sealed.combined
    }

    func decrypt(record: Data) throws -> Data {
        guard sessionBinding != nil else {
            throw SandboxFailure(.bootstrapTLSRequired, "key exchange not completed")
        }
        guard let protectKey = key else {
            throw SandboxFailure(.bootstrapTLSRequired, "record key unavailable")
        }
        let box = try ChaChaPoly.SealedBox(combined: record)
        // The sealed box carries the sender nonce; record ordering/authenticity
        // beyond AEAD is enforced by the outer ControlSequenceGuard.
        let plaintext = try ChaChaPoly.open(box, using: protectKey)
        return plaintext
    }

    var recordPrefixByteCount: Int { 4 }

    private static func nonce(direction: [UInt8], counter: UInt64) -> ChaChaPoly.Nonce {
        precondition(counter <= (UInt64(1) << 63), "record counter exhausted")
        var bytes = direction
        withUnsafeBytes(of: counter.bigEndian) { raw in bytes.append(contentsOf: raw) }
        return try! ChaChaPoly.Nonce(data: Data(bytes[0..<12]))
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let byteString = hexString[index..<hexString.index(index, offsetBy: 2)]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = hexString.index(index, offsetBy: 2)
        }
        self = data
    }
}
