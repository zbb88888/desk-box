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
    /// M44：光标在当前行（最后一行）里的列。nil = 在行尾（追加）。
    /// `\r` 把它置 0，之后的可打印字符**覆盖**该列上已有的字符——进度条、行内重绘靠这个。
    /// 此前 `\r` 被直接丢弃，`10%\r20%\r30%` 会显示成 `10%20%30%`。
    private var column: Int?
    private var csiParameters = ""
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
            case 0x0A:                                                 // \n：换行总是接在全文末尾
                column = nil
                text.unicodeScalars.append(s)
            case 0x0D: column = 0                                      // \r：回到行首（\r\n 时随后的 \n 会复位）
            case 0x09: put(Character(s), into: &text)                  // \t
            case 0x08, 0x7F:                                           // 退格 / DEL
                if let current = column {
                    column = max(0, current - 1)                       // 行内重绘中：只移动光标
                } else if let last = text.last, last != "\n" {
                    text.removeLast()                                  // 在行尾：删掉本行的前一个字符
                }
            case 0x9B: state = .csi; csiParameters = ""                // 8-bit CSI
            case 0x9D, 0x90, 0x98, 0x9E, 0x9F: state = .stringSequence // 8-bit OSC / DCS / SOS / PM / APC
            case 0x00...0x1F, 0x80...0x9F: break                       // 其余 C0 / C1（BEL 等）：丢弃
            default: put(Character(s), into: &text)
            }
        case .escape:
            switch v {
            case 0x5B: state = .csi; csiParameters = ""                // ESC [
            case 0x5D, 0x50, 0x58, 0x5E, 0x5F: state = .stringSequence // ESC ] P X ^ _
            case 0x28, 0x29, 0x2A, 0x2B: state = .charset              // ESC ( ) * + ：后面还有一个字符
            default: state = .ground                                   // 其它两字节转义
            }
        case .charset:
            state = .ground
        case .csi:
            // 参数 0x30–0x3F、中间字节 0x20–0x2F 继续；0x40–0x7E 是终止字节；其它视为序列被打断。
            if (0x20...0x3F).contains(v) {
                if csiParameters.count < 16 { csiParameters.unicodeScalars.append(s) }
                break
            }
            state = .ground
            // 只解释「擦除行」（EL）：`\r` + `ESC[K` 是行内重绘最常见的组合。其余 CSI 序列照旧丢弃。
            if v == 0x4B { eraseInLine(mode: csiParameters, in: &text) }
            // ED（擦到屏幕末尾）：我们只有「最后一行」这一个概念，缺省 / 0 等同于擦到行尾（ash 的行编辑重绘用它）。
            if v == 0x4A, csiParameters.isEmpty || csiParameters == "0" { eraseInLine(mode: "0", in: &text) }
        case .stringSequence:
            if v == 0x07 || v == 0x9C { state = .ground }              // BEL 或 ST 结束
            else if v == 0x1B { state = .stringEscape }                // ESC \ 结束
        case .stringEscape:
            state = .ground
        }
    }
}

extension TerminalTextFilter {
    /// 当前行（全文最后一个换行之后的部分）的起点。
    private func lineStart(in text: String) -> String.Index {
        text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
    }

    /// 写一个可打印字符：光标在行内时覆盖，在行尾时追加。
    fileprivate mutating func put(_ character: Character, into text: inout String) {
        guard let current = column else { text.append(character); return }
        let start = lineStart(in: text)
        guard let position = text.index(start, offsetBy: current, limitedBy: text.endIndex), position < text.endIndex else {
            text.append(character)
            column = nil
            return
        }
        text.replaceSubrange(position...position, with: String(character))
        column = current + 1
    }

    /// CSI K：0 / 缺省 = 擦到行尾；1 = 擦到行首（不支持，忽略）；2 = 擦整行。
    fileprivate mutating func eraseInLine(mode: String, in text: inout String) {
        let start = lineStart(in: text)
        switch mode {
        case "", "0":
            guard let current = column,
                  let position = text.index(start, offsetBy: current, limitedBy: text.endIndex) else { return }
            text.removeSubrange(position..<text.endIndex)
            column = nil            // 光标现在就在行尾
        case "2":
            text.removeSubrange(start..<text.endIndex)
            column = nil
        default:
            break
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
