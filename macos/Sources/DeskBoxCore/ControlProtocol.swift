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
    /// Host -> guest: allocate a PTY and run argv attached to it (M1-4).
    case ptyOpen = 9
    /// Host -> guest: stream input bytes into the PTY master.
    case ptyInput = 10
    /// Host -> guest: resize the PTY window (TIOCSWINSZ).
    case ptyResize = 11
    /// Host -> guest: close the PTY (EOF + kill escalation path).
    case ptyClose = 12
    /// Guest -> host: PTY lifecycle/output event (opened/output/exit).
    case ptyEvent = 13
    /// Host -> guest: workspace sync session start (M2-1).
    case wsBegin = 14
    /// Host -> guest: workspace file chunk (≤512 bytes hex-encoded).
    case wsPut = 15
    /// Host -> guest: workspace sync session commit.
    case wsEnd = 16
    /// Guest -> host: workspace sync result (success or fail-closed reason).
    case wsAck = 17
    /// Guest -> host: 在线 broker 拉取请求（M2-3b，例：\"https://example.com\"）。
    case brokerFetch = 21
    /// Host -> guest: 按 reqId 交付数据块的 hex 实体（≤512 bytes/块）。
    case brokerData = 22
    /// Host -> guest: 拉取终报（status/ok/error）。
    case brokerEnd = 23
    /// Host -> guest: 资源统计请求（M21）。payload 为空对象。
    case statsRequest = 24
    /// Guest -> host: 资源统计响应（M21）。payload 为 SandboxStats JSON。
    case statsResponse = 25
    /// Guest -> host: exec 输出块（M39）。payload 为 ExecOutputChunk JSON；requestID 与 exec 请求相同。
    /// 只有请求带 `streamOutput: true` 时 guest 才会发送。
    case execOutput = 26
    /// Host -> guest: 取消在途的 exec（M41）。requestID 必须与那条 exec 请求相同；payload 为空对象。
    /// 旧 guest 不认识这个类型，会在 exec 结束后把它当作未知帧忽略。
    case execCancel = 27
}

/// M21：guest cgroup v2 采样（只读、诊断用途，不构成安全边界）。
public struct SandboxStats: Sendable, Codable, Equatable {
    /// cgroup 累计 CPU 微秒（cpu.stat usage_usec）。
    public let cpuUsageUsec: UInt64?
    /// 瞬时内存占用（memory.current）。
    public let memoryCurrentBytes: UInt64?
    /// 内存上限（memory.max；为 nil 表示无限制）。
    public let memoryMaxBytes: UInt64?
    /// 当前进程数（pids.current）。
    public let pidsCurrent: Int?
    public let pidsMax: Int?
    /// 活动 exec 子组计数（活动度提示，不参与资源数值）。
    public let activeExecGroups: Int?
    /// 采集失败原因；成功后为 nil。
    public let statsError: String?
    /// M37：guest 的 workspace 接收端版本。旧 guest 不上报（nil，按 1 处理）；
    /// 2 起逐级 O_NOFOLLOW、首块截断。宿主据此决定是否允许「workload 运行之后」的再次同步。
    public let workspaceSyncVersion: Int?
    /// M39：guest 的 exec 输出处理版本。旧 guest 不上报（nil → 1：输出静默截到 1023 字节、
    /// 超过 64KB 会卡到超时）；2 起边等边读、截断有标记、支持流式回传。
    public var execOutputVersion: Int? = nil
    /// M41：guest 是否支持取消在途 exec（nil / 0 = 不支持）。
    public var execCancelVersion: Int? = nil
    /// M42：guest 的 broker 入口版本（nil → 1：exec 期间不受理 broker 请求，且 broker 客户端提前退出
    /// 会连带杀掉 guest 的控制面；2 起两者都已修复）。
    public var brokerVersion: Int? = nil

    public init(cpuUsageUsec: UInt64?, memoryCurrentBytes: UInt64?, memoryMaxBytes: UInt64?,
                pidsCurrent: Int?, pidsMax: Int?, activeExecGroups: Int? = nil,
                statsError: String? = nil, workspaceSyncVersion: Int? = nil) {
        self.workspaceSyncVersion = workspaceSyncVersion
        self.cpuUsageUsec = cpuUsageUsec
        self.memoryCurrentBytes = memoryCurrentBytes
        self.memoryMaxBytes = memoryMaxBytes
        self.pidsCurrent = pidsCurrent
        self.pidsMax = pidsMax
        self.activeExecGroups = activeExecGroups
        self.statsError = statsError
    }
}

// MARK: - Broker online channel messages (M2-3b)

public struct BrokerFetchRequest: Sendable, Codable, Equatable {
    public let reqId: UInt32
    public let url: String
    public let savePath: String   // /workspace/inbound/xxx （由 guest 验证）

    public init(reqId: UInt32, url: String, savePath: String) {
        self.reqId = reqId
        self.url = url
        self.savePath = savePath
    }
}

public struct BrokerDataChunk: Sendable, Codable, Equatable {
    public let reqId: UInt32
    public let dataHex: String
    public init(reqId: UInt32, dataHex: String) { self.reqId = reqId; self.dataHex = dataHex }
}

public struct BrokerFetchEnd: Sendable, Codable, Equatable {
    public let reqId: UInt32
    public let status: Int32
    public let ok: Bool
    public let error: String?

    public init(reqId: UInt32, status: Int32, ok: Bool, error: String? = nil) {
        self.reqId = reqId
        self.status = status
        self.ok = ok
        self.error = error
    }
}

// MARK: - Workspace Sync messages (M2-1)

public struct WsBeginRequest: Sendable, Codable, Equatable {
    public let wsId: String
    public let fileCount: Int
    public let totalBytes: UInt64

    public init(wsId: String, fileCount: Int, totalBytes: UInt64) {
        self.wsId = wsId
        self.fileCount = fileCount
        self.totalBytes = totalBytes
    }
}

public struct WsPutRequest: Sendable, Codable, Equatable {
    public let path: String   // relative to workspace root; no leading '/', no '..'
    public let offset: UInt64
    public let mode: UInt32
    public let dataHex: String

    public init(path: String, offset: UInt64, mode: UInt32, dataHex: String) {
        self.path = path
        self.offset = offset
        self.mode = mode
        self.dataHex = dataHex
    }
}

public struct WsEndRequest: Sendable, Codable, Equatable {
    public let wsId: String
    public init(wsId: String) { self.wsId = wsId }
}

public struct WsAckEvent: Sendable, Codable, Equatable {
    public let wsId: String
    public let ok: Bool
    public let error: String?

    public init(wsId: String, ok: Bool, error: String? = nil) {
        self.wsId = wsId
        self.ok = ok
        self.error = error
    }
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
    /// M39：请求 guest 把输出按块流式回传（`execOutput` 帧），而不是塞进单个应答帧。
    /// 旧 guest 不认识这个字段，会按老办法应答——宿主靠应答里的 `chunked` 区分。
    public var streamOutput: Bool? = nil
    /// M39：每一路输出（stdout / stderr 各自）最多保留多少字节；超过的部分 guest 读掉并丢弃。
    public var maxOutputBytes: Int? = nil

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
    // ---- M39：以下字段旧 guest 不发送（全为 nil） ----
    /// guest 的 exec 输出处理版本（见 SandboxStats.execOutputVersion）。
    public var outputVersion: Int? = nil
    /// true = 输出已通过 `execOutput` 帧送达，本应答里的 stdout 为空。
    public var chunked: Bool? = nil
    public var stdoutBytes: Int? = nil
    public var stderrBytes: Int? = nil
    public var stdoutTruncated: Bool? = nil
    public var stderrTruncated: Bool? = nil
    public var timedOut: Bool? = nil
    /// guest 在发送输出块时失败（输出不完整）。
    public var streamError: Bool? = nil
    /// M41：命令被取消（宿主请求，或控制通道断开），进程组已被杀。
    public var cancelled: Bool? = nil

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// PTY request payloads (docs/design/m1-4-pty-support.md §3.1).
public struct PtyOpenRequest: Sendable, Codable, Equatable {
    public let ptyId: UInt32
    public let argv: [String]
    public let rows: UInt16
    public let cols: UInt16

    public init(ptyId: UInt32 = 0, argv: [String], rows: UInt16 = 24, cols: UInt16 = 80) {
        self.ptyId = ptyId
        self.argv = argv
        self.rows = rows
        self.cols = cols
    }
}

public struct PtyInputRequest: Sendable, Codable, Equatable {
    public let ptyId: UInt32
    public let dataHex: String

    public init(ptyId: UInt32, dataHex: String) {
        self.ptyId = ptyId
        self.dataHex = dataHex
    }
}

public struct PtyResizeRequest: Sendable, Codable, Equatable {
    public let ptyId: UInt32
    public let rows: UInt16
    public let cols: UInt16

    public init(ptyId: UInt32, rows: UInt16, cols: UInt16) {
        self.ptyId = ptyId
        self.rows = rows
        self.cols = cols
    }
}

public struct PtyCloseRequest: Sendable, Codable, Equatable {
    public let ptyId: UInt32

    public init(ptyId: UInt32) { self.ptyId = ptyId }
}

/// Guest -> host PTY events. Data within `output` events is hex-encoded and
/// capped to 512 bytes per frame to keep frames bounded.
public struct PtyEvent: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case opened
        case output
        case exit
    }

    public let ptyId: UInt32
    public let type: Kind
    public let dataHex: String
    public let exitCode: Int32?
    public let signal: Int32?

    public init(ptyId: UInt32, type: Kind, dataHex: String = "", exitCode: Int32? = nil, signal: Int32? = nil) {
        self.ptyId = ptyId
        self.type = type
        self.dataHex = dataHex
        self.exitCode = exitCode
        self.signal = signal
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
