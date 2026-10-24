import Foundation

/// 控制通道消息类型（docs/design/control-channel-security.md §6）。
/// TLS session binding inputs (docs/design/m1-tls-channel-upgrade.md §3.3).
/// The session identifier is derived from both peer fingerprints and the boot
/// context so certificates from older boots cannot be replayed.
public struct SessionBinding: Sendable, Codable, Equatable {
    public let hostFingerprintHex: String
    public let guestFingerprintHex: String
    public let sessionID: SessionID

    public init(hostFingerprintHex: String, guestFingerprintHex: String, sessionID: SessionID) {
        self.hostFingerprintHex = hostFingerprintHex
        self.guestFingerprintHex = guestFingerprintHex
        self.sessionID = sessionID
    }

    public static func deriveSessionID(
        hostFingerprintHex: String,
        guestFingerprintHex: String,
        context: BootContext
    ) -> SessionID {
        let material = [
            "deskbox-m1-tls-v1", hostFingerprintHex, guestFingerprintHex,
            context.sandboxID.raw, context.bootID.raw,
            context.bootNonce.uuidString, context.guestManifestDigest
        ].joined(separator: "|")
        var digestInput = [UInt8](material.utf8)
        digestInput.append(UInt8(context.protocolMajor))
        return SessionID(ControlSessionHash.sha256Hex(of: Data(digestInput)))
    }
}

/// SHA-256 is reimplemented to avoid platform crypto dependencies inside the
/// public DeskBoxCore contract surface.
public enum ControlSessionHash {
    public static func sha256Hex(of data: Data) -> String {
        // Uses CommonCrypto on Apple platforms; deterministic and constant across
        // Swift versions for the wire/session contracts.
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { raw in
            _ = SHA256Digest(raw.baseAddress ?? UnsafeRawPointer(bitPattern: 0), raw.count, &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

@_silgen_name("CC_SHA256")
private func SHA256Digest(_ data: UnsafeRawPointer?, _ length: Int, _ md: UnsafeMutablePointer<UInt8>) -> UnsafeMutablePointer<UInt8>?

public enum ControlMessageKind: UInt16, Sendable, Codable {
    case hello = 1
    case helloAck = 2
    case readiness = 3
    case request = 4
    case response = 5
    case event = 6
    case close = 7
    /// Guest -> host ephemeral X25519 public key share. Flows after HelloAck
    /// and before the channel upgrades to record protection (M1-2).
    case keyExchange = 8
}

public struct ControlRequest: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case exec
        case ping
    }
    public let kind: Kind
    public let argv: [String]
    public let env: [String: String]?
    public let cwd: String?
    public let timeoutSeconds: Int?

    public init(kind: Kind, argv: [String], env: [String: String]? = nil, cwd: String? = nil, timeoutSeconds: Int? = nil) {
        self.kind = kind
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct ControlResponse: Sendable, Codable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// 有界应用层 frame。TLS 仍是后续实现的机密性/完整性层；
/// framing 本身负责 parser 边界、版本和序列号，不能单独当作认证。
public struct ControlFrame: Sendable, Equatable {
    public static let magic: UInt32 = 0x44425831 // "DBX1"
    public static let protocolMajor: UInt16 = 1
    public static let headerSize = 4 + 2 + 2 + 8 + 16 + 4
    public static let defaultMaximumPayload = 1 << 20

    public let kind: ControlMessageKind
    public let sequence: UInt64
    public let requestID: UUID
    public let payload: Data

    public init(
        kind: ControlMessageKind,
        sequence: UInt64,
        requestID: UUID = UUID(),
        payload: Data = Data()
    ) throws {
        guard payload.count <= Self.defaultMaximumPayload else {
            throw SandboxFailure(.bootstrapProofMismatch, "控制消息超过最大 payload：\(payload.count)")
        }
        self.kind = kind
        self.sequence = sequence
        self.requestID = requestID
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(contentsOf: Self.magic.bigEndianBytes)
        data.append(contentsOf: Self.protocolMajor.bigEndianBytes)
        data.append(contentsOf: kind.rawValue.bigEndianBytes)
        data.append(contentsOf: sequence.bigEndianBytes)
        data.append(contentsOf: requestID.uuidBytes)
        data.append(contentsOf: UInt32(payload.count).bigEndianBytes)
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data, maximumPayload: Int = defaultMaximumPayload) throws -> ControlFrame {
        guard data.count >= headerSize else {
            throw SandboxFailure(.bootstrapProofMismatch, "控制消息 header 不完整")
        }
        var reader = ByteReader(data)
        guard reader.readUInt32() == magic else {
            throw SandboxFailure(.bootstrapProofMismatch, "控制消息 magic 不匹配")
        }
        guard reader.readUInt16() == protocolMajor else {
            throw SandboxFailure(.bootstrapProofMismatch, "控制协议主版本不匹配")
        }
        guard let rawKind = reader.readUInt16(), let kind = ControlMessageKind(rawValue: rawKind) else {
            throw SandboxFailure(.bootstrapProofMismatch, "未知控制消息类型")
        }
        guard let sequence = reader.readUInt64(), let requestID = reader.readUUID(),
              let length = reader.readUInt32() else {
            throw SandboxFailure(.bootstrapProofMismatch, "控制消息 header 字段不完整")
        }
        let payloadLength = Int(length)
        guard payloadLength <= maximumPayload else {
            throw SandboxFailure(.bootstrapProofMismatch, "控制消息 payload 超过限制")
        }
        guard reader.remaining == payloadLength else {
            throw SandboxFailure(.bootstrapProofMismatch, "控制消息长度不一致")
        }
        return try ControlFrame(kind: kind, sequence: sequence, requestID: requestID, payload: reader.readData(count: payloadLength))
    }

    /// Reads the big-endian payload length without accepting an incomplete frame.
    public static func payloadLength(in data: Data) -> Int? {
        guard data.count >= headerSize else { return nil }
        // Copy the length bytes into zero-based storage. Reading by absolute
        // index on a sliced Data traps in release builds after dropFirst.
        let lengthBytes = Array(data.prefix(headerSize).suffix(4))
        guard lengthBytes.count == 4 else { return nil }
        return Int(UInt32(lengthBytes[0]) << 24 | UInt32(lengthBytes[1]) << 16
            | UInt32(lengthBytes[2]) << 8 | UInt32(lengthBytes[3]))
    }
}

/// Incremental decoder for stream transports. It bounds the buffer and emits
/// complete frames only; malformed data fails closed.
public struct ControlFrameDecoder: Sendable {
    private var buffer = Data()
    public let maximumPayload: Int

    public init(maximumPayload: Int = ControlFrame.defaultMaximumPayload) {
        self.maximumPayload = maximumPayload
    }

    public mutating func append(_ data: Data) throws -> [ControlFrame] {
        guard buffer.count + data.count <= ControlFrame.headerSize + maximumPayload else {
            throw SandboxFailure(.bootstrapProofMismatch, "控制通道缓冲区超过上限")
        }
        buffer.append(data)
        var frames: [ControlFrame] = []
        while buffer.count >= ControlFrame.headerSize {
            guard let payloadLength = ControlFrame.payloadLength(in: buffer) else { break }
            guard payloadLength <= maximumPayload else {
                throw SandboxFailure(.bootstrapProofMismatch, "控制消息 payload 超过限制")
            }
            let frameLength = ControlFrame.headerSize + payloadLength
            guard buffer.count >= frameLength else { break }
            let frameData = buffer.prefix(frameLength)
            let frame = try ControlFrame.decode(Data(frameData), maximumPayload: maximumPayload)
            frames.append(frame)
            // Normalize to zero-based storage instead of keeping a shared
            // slice view; subsequent absolute-index parsing must not trap.
            buffer = Data(buffer.dropFirst(frameLength))
        }
        return frames
    }

    public var bufferedBytes: Int { buffer.count }
}

/// 单向 session 的 replay/order 检查。sequence 从 1 开始且严格递增。
public struct ControlSequenceGuard: Sendable, Equatable {
    public private(set) var lastAccepted: UInt64 = 0

    public init() {}

    public mutating func accept(_ frame: ControlFrame) throws {
        guard frame.sequence == lastAccepted + 1 else {
            throw SandboxFailure(.bootstrapProofMismatch, "控制消息 sequence 非严格递增：收到 \(frame.sequence)，期待 \(lastAccepted + 1)")
        }
        lastAccepted = frame.sequence
    }
}

private struct ByteReader {
    private let data: Data
    private var offset: Int = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - offset }

    mutating func readUInt16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    mutating func readUInt32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    mutating func readUInt64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        defer { offset += 8 }
        return (0..<8).reduce(UInt64(0)) { result, index in
            result << 8 | UInt64(data[offset + index])
        }
    }

    mutating func readUUID() -> UUID? {
        guard remaining >= 16 else { return nil }
        let bytes = Array(data[offset..<(offset + 16)])
        offset += 16
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    mutating func readData(count: Int) -> Data {
        let result = data[offset..<(offset + count)]
        offset += count
        return Data(result)
    }
}

private extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        var value = bigEndian
        return withUnsafeBytes(of: &value) { Array($0) }
    }
}

private extension UUID {
    var uuidBytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }
}
