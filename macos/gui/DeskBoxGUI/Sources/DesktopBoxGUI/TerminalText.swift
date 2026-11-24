import Foundation

/// M33：十六进制解码（daemon 用 hex 传 PTY / console 字节）。
/// 此前两处手写循环用 `hex.index(i, offsetBy: 2)`，奇数长度的输入会越界 trap——
/// 一条畸形响应就能让 GUI 崩溃。这里非法输入返回 nil。
enum HexCoding {
    static func decode(_ hex: String) -> Data? {
        let bytes = Array(hex.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        var out = Data(capacity: bytes.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var i = 0
        while i < bytes.count {
            guard let hi = nibble(bytes[i]), let lo = nibble(bytes[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// M33：把 PTY 字节流变成可以放进一个纯文本视图的内容（有状态，可单元测试）。
///
/// 这不是终端仿真器：没有光标寻址、没有颜色。目标是「滚动日志」式的可读输出，
/// 并且**不让 guest 控制的字节把界面搞乱**。
///
/// 相比此前的 `sanitize`（无状态、按块处理）修掉的问题：
/// - CSI 的终止字节判断把 `[` 自己当成了终止符，`ESC[0;32m` 会在屏幕上留下 `0;32m`；
/// - 转义序列 / 多字节 UTF-8 字符恰好被切在两次 poll 之间时会漏出乱码；
/// - OSC（设置标题等，`ESC ] … BEL`）完全没处理；
/// - 退格不生效（shell 回显里的 `\b \b`）；
/// - 输出无上限地增长。
struct TerminalTextFilter {
    private enum State { case ground, escape, csi, stringSequence, stringEscape, charset }

    private var state = State.ground
    private var pendingBytes = Data()
    /// 累计文本上限（字符数）。超出后丢弃最早的内容。
    static let maxCharacters = 200_000

    /// 把一块字节追加到 `text`。
    mutating func feed(_ data: Data, into text: inout String) {
        pendingBytes.append(data)
        let decoded = takeDecodablePrefix()
        for scalar in decoded.unicodeScalars { consume(scalar, into: &text) }
        if text.count > Self.maxCharacters {
            text.removeFirst(text.count - Self.maxCharacters)
        }
    }

    /// 取出 `pendingBytes` 里能完整解码的最长 UTF-8 前缀；末尾不完整的多字节序列（最多 3 字节）留到下一块。
    private mutating func takeDecodablePrefix() -> String {
        for keep in 0...min(3, pendingBytes.count) {
            let cut = pendingBytes.count - keep
            if let s = String(data: pendingBytes.prefix(cut), encoding: .utf8) {
                // 只有当留下的尾巴「看起来像」一个未写完的多字节序列时才保留它。
                let tail = pendingBytes.suffix(keep)
                if keep == 0 || Self.isIncompleteUTF8Prefix(tail) {
                    pendingBytes = Data(tail)
                    return s
                }
            }
        }
        // 确实是非法字节：有损解码，不让坏数据卡住后续输出。
        let lossy = String(decoding: pendingBytes, as: UTF8.self)
        pendingBytes.removeAll()
        return lossy
    }

    private static func isIncompleteUTF8Prefix(_ bytes: Data) -> Bool {
        guard let first = bytes.first else { return false }
        let expected: Int
        switch first {
        case 0xC2...0xDF: expected = 2
        case 0xE0...0xEF: expected = 3
        case 0xF0...0xF4: expected = 4
        default: return false
        }
        guard bytes.count < expected else { return false }
        return bytes.dropFirst().allSatisfy { $0 & 0xC0 == 0x80 }
    }

    private mutating func consume(_ s: Unicode.Scalar, into text: inout String) {
        let v = s.value
        switch state {
        case .ground:
            switch v {
            case 0x1B: state = .escape
            case 0x0A, 0x09: text.unicodeScalars.append(s)            // \n \t
            case 0x08, 0x7F:                                           // 退格 / DEL：删掉本行的前一个字符
                if let last = text.last, last != "\n" { text.removeLast() }
            case 0x9B: state = .csi                                    // 8-bit CSI
            case 0x9D, 0x90, 0x98, 0x9E, 0x9F: state = .stringSequence // 8-bit OSC / DCS / SOS / PM / APC
            case 0x00...0x1F, 0x80...0x9F: break                       // 其余 C0 / C1（含 \r、BEL）：丢弃
            default: text.unicodeScalars.append(s)
            }
        case .escape:
            switch v {
            case 0x5B: state = .csi                                    // ESC [
            case 0x5D, 0x50, 0x58, 0x5E, 0x5F: state = .stringSequence // ESC ] P X ^ _
            case 0x28, 0x29, 0x2A, 0x2B: state = .charset              // ESC ( ) * + ：后面还有一个字符
            default: state = .ground                                   // 其它两字节转义
            }
        case .charset:
            state = .ground
        case .csi:
            // 参数 0x30–0x3F、中间字节 0x20–0x2F 继续；0x40–0x7E 是终止字节；其它视为序列被打断。
            if (0x20...0x3F).contains(v) { break }
            state = .ground
        case .stringSequence:
            if v == 0x07 || v == 0x9C { state = .ground }              // BEL 或 ST 结束
            else if v == 0x1B { state = .stringEscape }                // ESC \ 结束
        case .stringEscape:
            state = .ground
        }
    }
}

/// Console（guest serial）文本：整段一次性解码，复用同一套净化规则。
enum ConsoleLog {
    static func text(fromHex hex: String) -> String? {
        guard let data = HexCoding.decode(hex) else { return nil }
        var filter = TerminalTextFilter()
        var text = ""
        filter.feed(data, into: &text)
        return text
    }
}
