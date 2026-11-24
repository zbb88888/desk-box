import Foundation

/// M39：exec 输出块（guest → host，`execOutput` 帧的 payload）。
public struct ExecOutputChunk: Sendable, Codable, Equatable {
    /// 1 = stdout，2 = stderr。
    public let s: Int
    public let dataHex: String

    public init(s: Int, dataHex: String) {
        self.s = s
        self.dataHex = dataHex
    }
}

/// M39：exec 的最终结果（宿主侧汇总后的形态）。
public struct ExecResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    /// 输出**确定**被截断（guest 明确报告，或宿主自己的上限生效）。
    public var stdoutTruncated = false
    public var stderrTruncated = false
    /// 输出**可能**被截断：旧 guest 不报告截断，但某一路输出的长度达到了它的固定上限。
    public var possiblyTruncated = false
    public var timedOut = false
    /// M41：命令被取消（guest 已杀掉进程组）；stdout / stderr 是取消之前的输出。
    public var cancelled = false
    /// 输出不完整的其它原因（块丢失 / 字节数对不上 / guest 发送失败）。nil = 没有问题。
    public var integrityProblem: String?
    /// guest 的 exec 输出处理版本（1 = 旧 guest）。
    public var guestOutputVersion = 1

    /// 给人看的提示行（CLI 打到 stderr、GUI 显示在输出下方）。没有需要提示的事情时为空。
    public var notices: [String] {
        var lines: [String] = []
        if stdoutTruncated { lines.append("stdout 被截断：只保留了前 \(stdout.utf8.count) 字节") }
        if stderrTruncated { lines.append("stderr 被截断：只保留了前 \(stderr.utf8.count) 字节") }
        if possiblyTruncated {
            lines.append("输出可能被截断：这台沙箱的 guest 资产较旧，每一路最多返回 \(ExecOutputPolicy.legacyStdoutCap) 字节且不报告截断"
                + "（输出超过 64KB 时命令还会卡到超时）。升级 guest 资产后可完整返回。")
        }
        if timedOut, guestOutputVersion < 2 {
            lines.append("旧 guest 上，输出超过 64KB 的命令会卡住直到超时——如果这条命令输出很多，超时可能是这个原因。")
        }
        if let integrityProblem { lines.append("输出不完整：\(integrityProblem)") }
        return lines
    }
}

public enum ExecOutputPolicy {
    /// 每一路输出默认保留的上限。
    public static let defaultMaxBytes = 1024 * 1024
    /// 旧 guest 的 stdout 固定上限（`EXEC_MAX_OUTPUT - 1`）。
    public static let legacyStdoutCap = 1023
    /// 宿主等 guest 应答时，在 exec 超时之上多等的时间：超时由 guest 执行并应答
    ///（它会杀掉进程组并报告 exit -2）；宿主如果同时放弃，用户看到的就是一个含糊的通道错误。
    public static let responseGraceSeconds = 5
}

/// M39：把 `execOutput` 块和最终应答汇总成 ExecResult（纯逻辑，不做 I/O）。
///
/// 宿主不信任 guest 的自我约束：guest 声称的上限由宿主再执行一遍（超出的块丢弃并标记截断），
/// guest 报告的字节数与实际收到的不符时标记为不完整。
public struct ExecOutputAssembler: Sendable {
    public let maxBytes: Int
    public private(set) var stdout = Data()
    public private(set) var stderr = Data()
    public private(set) var hostTruncatedStdout = false
    public private(set) var hostTruncatedStderr = false
    public private(set) var malformedChunks = 0

    public init(maxBytes: Int = ExecOutputPolicy.defaultMaxBytes) {
        self.maxBytes = max(1, maxBytes)
    }

    public mutating func append(_ chunk: ExecOutputChunk) {
        guard chunk.s == 1 || chunk.s == 2, let data = Self.decodeHex(chunk.dataHex) else {
            malformedChunks += 1
            return
        }
        if chunk.s == 1 {
            hostTruncatedStdout = Self.append(data, to: &stdout, limit: maxBytes) || hostTruncatedStdout
        } else {
            hostTruncatedStderr = Self.append(data, to: &stderr, limit: maxBytes) || hostTruncatedStderr
        }
    }

    /// - Returns: 是否因为上限丢掉了数据。
    private static func append(_ data: Data, to buffer: inout Data, limit: Int) -> Bool {
        let room = max(0, limit - buffer.count)
        buffer.append(data.prefix(room))
        return data.count > room
    }

    public func finish(_ response: ControlResponse) -> ExecResult {
        let version = response.outputVersion ?? 1
        guard response.chunked == true else {
            // 单帧应答：旧 guest，或新 guest 在非流式模式下。
            var result = ExecResult(exitCode: response.exitCode, stdout: response.stdout, stderr: response.stderr)
            result.guestOutputVersion = version
            result.stdoutTruncated = response.stdoutTruncated ?? false
            result.stderrTruncated = response.stderrTruncated ?? false
            result.timedOut = response.timedOut ?? (response.exitCode == -2)
            result.cancelled = response.cancelled ?? false
            if version < 2 {
                result.possiblyTruncated = response.stdout.utf8.count >= ExecOutputPolicy.legacyStdoutCap
                    || response.stderr.utf8.count >= ExecOutputPolicy.legacyStdoutCap
            }
            if !stdout.isEmpty || !stderr.isEmpty || malformedChunks > 0 {
                result.integrityProblem = "guest 发来了输出块，但最终应答没有声明流式输出"
            }
            return result
        }
        var result = ExecResult(exitCode: response.exitCode,
                                stdout: String(decoding: stdout, as: UTF8.self),
                                stderr: String(decoding: stderr, as: UTF8.self))
        result.guestOutputVersion = version
        result.stdoutTruncated = (response.stdoutTruncated ?? false) || hostTruncatedStdout
        result.stderrTruncated = (response.stderrTruncated ?? false) || hostTruncatedStderr
        result.timedOut = response.timedOut ?? false
        result.cancelled = response.cancelled ?? false
        // guest 自己的说明（例如超时提示）接在收到的 stderr 之后。
        if !response.stderr.isEmpty {
            if !result.stderr.isEmpty, !result.stderr.hasSuffix("\n") { result.stderr += "\n" }
            result.stderr += response.stderr
        }
        var problems: [String] = []
        if response.streamError == true { problems.append("guest 报告发送输出块失败") }
        if malformedChunks > 0 { problems.append("\(malformedChunks) 个输出块无法解析") }
        // 宿主上限生效时，收到的字节数本来就会少于 guest 报告的数目，不算不一致。
        if let claimed = response.stdoutBytes, claimed != stdout.count, !hostTruncatedStdout {
            problems.append("stdout 收到 \(stdout.count) 字节，guest 报告 \(claimed)")
        }
        if let claimed = response.stderrBytes, claimed != stderr.count, !hostTruncatedStderr {
            problems.append("stderr 收到 \(stderr.count) 字节，guest 报告 \(claimed)")
        }
        if !problems.isEmpty { result.integrityProblem = problems.joined(separator: "；") }
        return result
    }

    static func decodeHex(_ hex: String) -> Data? {
        let bytes = Array(hex.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        var data = Data(capacity: bytes.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var i = 0
        while i < bytes.count {
            guard let hi = nibble(bytes[i]), let lo = nibble(bytes[i + 1]) else { return nil }
            data.append(hi << 4 | lo)
            i += 2
        }
        return data
    }
}
