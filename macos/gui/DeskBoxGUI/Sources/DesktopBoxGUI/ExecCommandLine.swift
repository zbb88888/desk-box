import Foundation

/// M32：把 Exec 输入框里的一行命令拆成 argv（纯函数，可单元测试）。
///
/// 此前是 `split(separator: " ")`：任何带空格的参数都没法表达——连
/// `/bin/sh -c 'echo a b'` 都会被拆成 `["/bin/sh", "-c", "'echo", "a", "b'"]`。
///
/// 规则（POSIX shell 引号的一个子集，**只做分词**——不展开变量、通配符、命令替换；
/// 结果原样作为 argv 交给 daemon，不经过任何 shell）：
/// - 空白（空格 / Tab / 换行）分隔参数；
/// - 单引号内一切按字面量；
/// - 双引号内 `\"` `\\` 转义，其余按字面量；
/// - 引号外 `\x` 取字面量 x；
/// - 相邻片段拼接：`a"b c"'d'` → `ab cd`；`''` 是一个空参数；
/// - 引号未闭合 / 行尾悬空的反斜杠 → 报错（不猜测用户意图）。
enum ExecCommandLine {
    enum ParseError: Error, Equatable, LocalizedError {
        case unterminatedSingleQuote
        case unterminatedDoubleQuote
        case trailingBackslash

        var errorDescription: String? {
            switch self {
            case .unterminatedSingleQuote: return "单引号没有闭合"
            case .unterminatedDoubleQuote: return "双引号没有闭合"
            case .trailingBackslash: return "行尾有多余的反斜杠"
            }
        }
    }

    static func argv(from line: String) throws -> [String] {
        var args: [String] = []
        var current = ""
        var hasToken = false          // 区分「没有参数」与「空字符串参数」（'' / ""）
        enum Mode { case plain, single, double }
        var mode = Mode.plain
        var iterator = line.makeIterator()

        while let ch = iterator.next() {
            switch mode {
            case .plain:
                if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                    if hasToken { args.append(current); current = ""; hasToken = false }
                } else if ch == "'" {
                    mode = .single; hasToken = true
                } else if ch == "\"" {
                    mode = .double; hasToken = true
                } else if ch == "\\" {
                    guard let next = iterator.next() else { throw ParseError.trailingBackslash }
                    current.append(next); hasToken = true
                } else {
                    current.append(ch); hasToken = true
                }
            case .single:
                if ch == "'" { mode = .plain } else { current.append(ch) }
            case .double:
                if ch == "\"" {
                    mode = .plain
                } else if ch == "\\" {
                    guard let next = iterator.next() else { throw ParseError.unterminatedDoubleQuote }
                    // 只有 \" 与 \\ 是转义；其它情况反斜杠保留（与 POSIX 一致）。
                    if next == "\"" || next == "\\" { current.append(next) }
                    else { current.append("\\"); current.append(next) }
                } else {
                    current.append(ch)
                }
            }
        }
        switch mode {
        case .single: throw ParseError.unterminatedSingleQuote
        case .double: throw ParseError.unterminatedDoubleQuote
        case .plain: break
        }
        if hasToken { args.append(current) }
        return args
    }
}
