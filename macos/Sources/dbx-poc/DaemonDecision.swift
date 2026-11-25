import Foundation

/// M24a：daemon 协议决策表（纯函数层，可单元测试）。
///
/// 只做「路由 + 必备参数 + 会话存在性 + 凭据域前置比对 + draining」判定，
/// 不触达 VZ / 文件系统。effect 层（SandboxDaemon.dispatch*）在执行前仍保留
/// 自己的 guard（防 TOCTOU：validate 与执行之间状态可能变化）。
///
/// 错误文案保持与 M12–M23 兼容（e2e 脚本 grep 依赖）：
/// - `unknown kind=…`
/// - `<op>: sandbox not found: …`
/// - `DBX-DOMAIN-SESSION-MISMATCH: …`
/// - `ptyOpen: sandbox already has an active pty session`
enum DaemonRoute: String, CaseIterable, Sendable {
    case run, ps, info, exec, execCancel, stop, rm
    case ptyOpen, ptyInput, ptyPoll, ptyClose
    case wsSync, consoleLog, stats, suspend, resume, restart, shutdown
}

/// 决策所需的最小状态快照（由 SandboxDaemon 在 stateQueue 上构造）。
struct DaemonStateSnapshot: Sendable {
    /// sandboxId → 凭据域 raw 值
    var sessionDomains: [String: String] = [:]
    /// ptySessionId → sandboxId
    var ptySandbox: [String: String] = [:]
    /// M33：已被客户端遗弃的 pty 会话（长时间没有 poll / input）。它们不阻止新的 ptyOpen。
    var stalePtySessions: Set<String> = []
    /// shutdown 已开始：除 shutdown 外全部拒收
    var draining: Bool = false
}

enum DaemonDecision {
    static func route(_ kind: String) throws -> DaemonRoute {
        guard let route = DaemonRoute(rawValue: kind) else {
            throw CLIError.usage("unknown kind=\(kind)")
        }
        return route
    }

    /// 决策表入口：返回路由或抛结构化拒绝。
    static func validate(_ request: DaemonRequest, state: DaemonStateSnapshot) throws -> DaemonRoute {
        let route = try route(request.kind)
        if state.draining && route != .shutdown {
            throw CLIError.usage("daemon draining: kind=\(request.kind) rejected (shutdown in progress)")
        }
        switch route {
        case .ps, .info, .shutdown:
            break
        case .run:
            guard request.manifestPath != nil else { throw CLIError.usage("run: --manifestPath required") }
        case .exec:
            try requireSession(request, op: "exec", state: state)
            guard let argv = request.argv, !argv.isEmpty else { throw CLIError.usage("exec: argv required") }
        case .execCancel:
            try requireSession(request, op: "execCancel", state: state)
        case .stop:
            try requireSession(request, op: "stop", state: state)
        case .rm:
            guard request.sandboxId != nil else { throw CLIError.usage("rm: sandboxId required") }
            // M27：rm 与其它会话级操作一致——声明了 domain 就必须匹配（此前唯独 rm 不比对）。
            try requireSession(request, op: "rm", state: state)
        case .suspend:
            try requireSession(request, op: "suspend", state: state)
        case .resume:
            try requireSession(request, op: "resume", state: state)
        case .stats:
            try requireSession(request, op: "stats", state: state)
        case .consoleLog:
            try requireSession(request, op: "consoleLog", state: state)
        case .restart:
            try requireSession(request, op: "restart", state: state)
        case .wsSync:
            try requireSession(request, op: "wsSync", state: state)
            guard request.workspaceDir != nil else { throw CLIError.usage("wsSync: workspaceDir required") }
        case .ptyOpen:
            try requireSession(request, op: "ptyOpen", state: state)
            guard let argv = request.argv, !argv.isEmpty else { throw CLIError.usage("ptyOpen: argv required") }
            // 只有「还活着」的会话才阻止新的打开；被遗弃的会话会在 effect 层被抢占并关闭。
            if let id = request.sandboxId,
               state.ptySandbox.contains(where: { $0.value == id && !state.stalePtySessions.contains($0.key) }) {
                throw CLIError.usage("ptyOpen: sandbox already has an active pty session")
            }
        case .ptyInput:
            try requirePty(request, op: "ptyInput", state: state, needsLiveSandbox: true)
        case .ptyPoll:
            try requirePty(request, op: "ptyPoll", state: state, needsLiveSandbox: true)
        case .ptyClose:
            try requirePty(request, op: "ptyClose", state: state, needsLiveSandbox: false)
        }
        return route
    }

    /// M23（INV-02）：会话存在 + 域比对（声明了 domain 就必须一致；未声明放行）。
    private static func requireSession(_ request: DaemonRequest, op: String, state: DaemonStateSnapshot) throws {
        guard let id = request.sandboxId, let domain = state.sessionDomains[id] else {
            throw CLIError.usage("\(op): sandbox not found: \(request.sandboxId ?? "nil")")
        }
        if let declared = request.domain, !declared.isEmpty, declared != domain {
            throw CLIError.usage("DBX-DOMAIN-SESSION-MISMATCH: \(op) 请求域 \(declared) 与沙箱域 \(domain) 不一致")
        }
    }

    private static func requirePty(_ request: DaemonRequest, op: String,
                                   state: DaemonStateSnapshot, needsLiveSandbox: Bool) throws {
        guard let sid = request.ptySessionId, let sandboxId = state.ptySandbox[sid] else {
            throw CLIError.usage("\(op): pty session not found")
        }
        if needsLiveSandbox && state.sessionDomains[sandboxId] == nil {
            throw CLIError.usage("\(op): sandbox no longer alive")
        }
    }
}
