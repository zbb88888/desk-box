import Foundation

/// M28：把 daemon 的原因码翻译成用户可读的提示（纯函数，可单元测试）。
///
/// daemon 的错误文本以稳定原因码开头（`DBX-…`），后面跟着面向排查的细节——其中可能包含
/// **guest 控制的内容**（如引导失败时的 console 片段）。GUI 展示前统一净化并限长。
struct PresentedDaemonError: Equatable {
    enum Severity: String { case info, warning, error }
    let code: String?
    let severity: Severity
    let title: String
    let hint: String?
    /// 净化后的原始细节（供展开查看 / 日志）。
    let detail: String

    /// 日志窗的一行摘要。
    var logLine: String {
        var line = title
        if let hint { line += " — \(hint)" }
        if let code { line += " [\(code)]" }
        return line
    }
}

enum DaemonErrorPresenter {
    private struct Rule {
        let needle: String
        let severity: PresentedDaemonError.Severity
        let title: String
        let hint: String?
    }

    /// 顺序即优先级：更具体的在前。
    private static let rules: [Rule] = [
        Rule(needle: "DBX-BOOT-FAILED(no-console-output)", severity: .error, title: "沙箱引导失败：guest 没有任何输出",
             hint: "多为内存不足或 kernel/initrd 损坏；详情里有估算的内存下限"),
        Rule(needle: "DBX-BOOT-FAILED(out-of-memory)", severity: .error, title: "沙箱引导失败：guest 内存不足", hint: "调大内存后重试"),
        Rule(needle: "DBX-BOOT-FAILED(root-mount-failed)", severity: .error, title: "沙箱引导失败：无法挂载根文件系统", hint: "检查 manifest 的 rootfs 与内核是否匹配"),
        Rule(needle: "DBX-BOOT-FAILED(init-failed)", severity: .error, title: "沙箱引导失败：guest init 无法启动", hint: "检查 rootfs 内的 /init"),
        Rule(needle: "DBX-BOOT-FAILED", severity: .error, title: "沙箱引导失败", hint: "查看详情中的 console 片段"),
        Rule(needle: "DBX-BOOT-TIMEOUT", severity: .error, title: "沙箱引导超时", hint: "查看详情中的 console 片段"),
        Rule(needle: "DBX-RESUME-HOST-LOCKED", severity: .warning, title: "无法恢复：Mac 处于锁屏状态", hint: "解锁后重试；沙箱仍为 suspended，快照已保留"),
        Rule(needle: "DBX-RESUME-VZ-RESTORE-FAILED", severity: .error, title: "无法恢复 VM 状态", hint: "沙箱仍为 suspended，快照已保留"),
        Rule(needle: "DBX-LIFECYCLE-SUSPEND-ABORTED", severity: .warning, title: "挂起失败，沙箱仍在运行", hint: "沙箱未受影响，可继续使用或重试"),
        Rule(needle: "DBX-LIFECYCLE-SUSPEND-FAILED", severity: .error, title: "挂起失败，沙箱已不可用", hint: "请移除该沙箱"),
        Rule(needle: "DBX-WS-RESYNC-UNSAFE", severity: .warning, title: "无法再次同步：沙箱已运行过程序且 guest 资产较旧",
             hint: "新建沙箱后先同步再运行，或升级 guest 资产"),
        Rule(needle: "DBX-EXEC-CANCEL-UNSUPPORTED", severity: .warning, title: "无法取消：guest 资产较旧，不支持取消在途命令",
             hint: "等它结束或超时，或停止 / 移除这台沙箱"),
        Rule(needle: "DBX-EXEC-NOT-RUNNING", severity: .info, title: "没有正在运行的命令", hint: nil),
        Rule(needle: "DBX-OP-CANCELLED", severity: .info, title: "操作已取消", hint: "沙箱正在被停止或移除"),
        Rule(needle: "DBX-DAEMON-ALREADY-RUNNING", severity: .info, title: "已有 daemon 在运行", hint: "将直接连接现有 daemon"),
        Rule(needle: "DBX-DOMAIN-SESSION-MISMATCH", severity: .error, title: "凭据域不匹配", hint: "该沙箱属于另一个凭据域"),
        Rule(needle: "DBX-LIFECYCLE-INVALID-TRANSITION", severity: .warning, title: "当前状态不允许此操作", hint: nil),
        Rule(needle: "daemon draining", severity: .info, title: "daemon 正在停机", hint: "停机完成后再试"),
        Rule(needle: "sandbox not found", severity: .warning, title: "沙箱不存在", hint: "可能已被移除；刷新列表"),
        Rule(needle: "sandbox is running; use --force", severity: .warning, title: "沙箱仍在运行", hint: "先停止，或使用强制移除"),
    ]

    static func present(_ error: Error) -> PresentedDaemonError {
        if let clientError = error as? DaemonClientError {
            switch clientError {
            case .socketFailed, .connectFailed:
                return PresentedDaemonError(code: nil, severity: .error, title: "无法连接 daemon",
                                            hint: "daemon 未运行或 socket 不可达", detail: sanitize(clientError.localizedDescription))
            case .weird(let message):
                return PresentedDaemonError(code: nil, severity: .warning, title: "daemon 没有给出有效响应",
                                            hint: "可能正忙；稍后重试", detail: sanitize(message))
            case .rejected(let message):
                return present(rejection: message)
            }
        }
        return PresentedDaemonError(code: nil, severity: .error, title: "请求失败", hint: nil,
                                    detail: sanitize(error.localizedDescription))
    }

    /// daemon 明确拒绝了请求（daemon 本身是活的）。
    static func present(rejection raw: String) -> PresentedDaemonError {
        let detail = sanitize(raw)
        for rule in rules where raw.contains(rule.needle) {
            return PresentedDaemonError(code: extractCode(from: raw), severity: rule.severity,
                                        title: rule.title, hint: rule.hint, detail: detail)
        }
        return PresentedDaemonError(code: extractCode(from: raw), severity: .error, title: "请求被 daemon 拒绝",
                                    hint: nil, detail: detail)
    }

    /// 取第一个形如 `DBX-AAA-BBB` 或 `DBX-AAA(kind)` 的原因码。
    static func extractCode(from raw: String) -> String? {
        guard let start = raw.range(of: "DBX-") else { return nil }
        var code = ""
        var depth = 0
        for ch in raw[start.lowerBound...] {
            if ch == "(" { depth += 1; code.append(ch); continue }
            if ch == ")" { guard depth > 0 else { break }; depth -= 1; code.append(ch); if depth == 0 { break }; continue }
            let ok = ch.isASCII && (ch.isUppercase || ch.isNumber || ch == "-" || (depth > 0 && (ch.isLowercase)))
            guard ok else { break }
            code.append(ch)
        }
        while code.hasSuffix("-") { code.removeLast() }
        return code.count > 4 ? code : nil
    }

    /// 去掉 ANSI 序列与控制字符，折叠空白，限长。
    static func sanitize(_ raw: String, limit: Int = 600) -> String {
        var out = String.UnicodeScalarView()
        var it = raw.unicodeScalars.makeIterator()
        var pendingSpace = false
        while let s = it.next() {
            if s == "\u{1B}" {
                guard let next = it.next() else { break }
                if next == "[" { while let c = it.next() { if c.value >= 0x40 && c.value <= 0x7E { break } } }
                continue
            }
            let isControl = s.value < 0x20 || s.value == 0x7F || (s.value >= 0x80 && s.value < 0xA0)
            if isControl || s == " " { pendingSpace = !out.isEmpty; continue }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(s)
        }
        var result = String(out)
        if result.count > limit { result = String(result.prefix(limit)) + "…" }
        return result
    }
}

extension DaemonClientError {
    /// 这个错误是否说明 **daemon 不可达**。
    /// `rejected` 恰恰相反——daemon 活着并且回了话；`weird`（超时 / 响应不完整）不足以下结论，
    /// 交给周期性探活判断。此前任何失败都会把状态置为 stopped。
    var indicatesDaemonUnreachable: Bool {
        switch self {
        case .socketFailed, .connectFailed: return true
        case .rejected, .weird: return false
        }
    }
}
