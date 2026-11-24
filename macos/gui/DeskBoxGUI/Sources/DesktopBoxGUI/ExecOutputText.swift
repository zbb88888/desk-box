import Foundation

/// M39：Exec 面板里显示的文本（纯函数）。
/// 截断 / 不完整的说明放在最前面——输出可能很长，放在末尾会被滚出视野。
enum ExecOutputText {
    static func render(exitCode: Int32?, stdout: String?, stderr: String?, notices: [String]?) -> String {
        var text = "exit=\(exitCode ?? 0)\n"
        for notice in notices ?? [] { text += "⚠︎ \(notice)\n" }
        text += "---stdout---\n\(stdout ?? "")\n---stderr---\n\(stderr ?? "")"
        return text
    }
}
