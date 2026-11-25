import Foundation

/// M51：让「正在运行的东西比当前代码旧」由产品自己说出来。
///
/// 这个项目里同时在跑的有三层：客户端（CLI / GUI）、常驻的 daemon、每台沙箱里的 guest 资产。
/// daemon 可以连续运行几个星期，guest 资产要显式重建——它们落后于代码时，缺的可能是崩溃修复或安全修复，
/// 而此前没有任何界面会告诉你。

// MARK: - daemon

/// daemon 对 `info` 请求的应答。
public struct DaemonInfo: Sendable, Codable, Equatable {
    /// 构建修订号（见 BuildRevision.current）。
    public let revision: Int
    public let pid: Int32
    public let startedAtUtc: String
    public let sandboxCount: Int

    public init(revision: Int, pid: Int32, startedAtUtc: String, sandboxCount: Int) {
        self.revision = revision
        self.pid = pid
        self.startedAtUtc = startedAtUtc
        self.sandboxCount = sandboxCount
    }
}

public enum BuildRevision {
    /// 这份代码的修订号。**每个改动了 daemon 行为的里程碑加一**（数值取里程碑编号）。
    public static let current = 51

    /// 值得在「daemon 较旧」的提示里点名的修复：(引入它的修订号, 一句话)。
    /// 只列用户能感受到的——崩溃、挂死、数据或隔离问题。
    public static let notableDaemonFixes: [(revision: Int, summary: String)] = [
        (24, "一个卡住的客户端会阻塞所有请求"),
        (33, "终端关闭后无法再次打开"),
        (37, "workspace 同步在校验与推送之间可被替换成符号链接"),
        (43, "guest 控制进程退出后请求要等到超时才失败"),
        (46, "终端大量输出时 daemon 可能崩溃，名下所有沙箱一起丢失"),
        (49, "监听 socket 失效时 daemon 以 100% CPU 空转"),
    ]

    public enum Skew: Equatable, Sendable {
        case same
        /// daemon 比客户端旧。`daemonRevision == nil`：它连 `info` 请求都不认识（早于 M51）。
        case daemonOlder(daemonRevision: Int?)
        case daemonNewer(daemonRevision: Int)
    }

    public static func skew(daemonRevision: Int?, clientRevision: Int = current) -> Skew {
        guard let daemonRevision else { return .daemonOlder(daemonRevision: nil) }
        if daemonRevision == clientRevision { return .same }
        return daemonRevision < clientRevision ? .daemonOlder(daemonRevision: daemonRevision)
                                               : .daemonNewer(daemonRevision: daemonRevision)
    }

    /// daemon 缺少的、值得点名的修复。daemon 不认识 `info` 时无从知道它具体多旧：列出全部。
    public static func missingFixes(daemonRevision: Int?) -> [String] {
        notableDaemonFixes.filter { daemonRevision == nil || $0.revision > daemonRevision! }.map(\.summary)
    }

    /// 给人看的一句话；没有偏差时为 nil。
    public static func note(for skew: Skew) -> String? {
        switch skew {
        case .same:
            return nil
        case .daemonOlder(let revision):
            let which = revision.map { "修订 \($0)" } ?? "早于修订 \(current)，不认识版本查询"
            return "正在运行的 daemon 比这个客户端旧（\(which)；客户端是修订 \(current)）。"
                + "新的修复要重启 daemon 才生效——重启会结束它名下的所有沙箱。"
        case .daemonNewer(let revision):
            return "正在运行的 daemon（修订 \(revision)）比这个客户端（修订 \(current)）新；请更新客户端。"
        }
    }

    /// daemon 的拒绝文本是不是「不认识 info 这个请求」（旧 daemon 的固定措辞）。
    public static func isUnknownInfoRejection(_ message: String) -> Bool {
        message.contains("unknown kind=info")
    }
}

// MARK: - guest

/// 这台沙箱的 guest 资产缺少的一项修复 / 能力。
public struct GuestFinding: Sendable, Equatable, Codable {
    public enum Severity: String, Sendable, Codable {
        /// 沙箱内的程序可以借此破坏隔离或让沙箱失去响应。
        case isolation
        /// 结果不正确 / 会挂住。
        case reliability
        /// 少一个功能。
        case feature
        /// 这是测试夹具。
        case testOnly
    }
    public let id: String
    public let severity: Severity
    public let summary: String

    public init(id: String, severity: Severity, summary: String) {
        self.id = id
        self.severity = severity
        self.summary = summary
    }
}

public enum GuestCapabilityReport {
    /// 由 guest 经 stats 上报的能力字段推断它缺什么。旧 guest 不上报的字段按「没有」处理。
    public static func findings(for stats: SandboxStats) -> [GuestFinding] {
        var findings: [GuestFinding] = []
        if (stats.childFdsVersion ?? 0) < 1 {
            findings.append(.init(id: "child-fds", severity: .isolation,
                summary: "沙箱里的程序的 stdin 就是控制通道：读 stdin 的命令会挂住，一行 `echo x >&0` 就能让这台沙箱 failed（M46）"))
        }
        if (stats.brokerVersion ?? 1) < 2 {
            findings.append(.init(id: "broker-control-plane", severity: .isolation,
                summary: "沙箱里的程序可以经 broker 入口杀掉 guest 的控制进程；在 exec 里调用 brokerreq 会卡到超时（M42）"))
        }
        if (stats.workspaceSyncVersion ?? 1) < 2 {
            findings.append(.init(id: "workspace-receiver", severity: .isolation,
                summary: "workspace 接收端会跟随沙箱里预置的符号链接（guest 内提权）；宿主因此拒绝「运行过程序之后」的再次同步（M37）"))
        }
        if (stats.execOutputVersion ?? 1) < 2 {
            findings.append(.init(id: "exec-output", severity: .reliability,
                summary: "exec 的输出被截到 1023 字节；输出超过 64KB 时命令卡到超时（M39）"))
        }
        if (stats.brokerVersion ?? 1) < 3 {
            findings.append(.init(id: "broker-result", severity: .reliability,
                summary: "brokerreq 在下载被拒绝 / 失败时仍然返回 0（M43）"))
        }
        if (stats.execCancelVersion ?? 0) < 1 {
            findings.append(.init(id: "exec-cancel", severity: .feature,
                summary: "不支持取消在途的 exec（Ctrl-C / Cancel 只会让客户端退出）（M41）"))
        }
        if stats.testFaults == true {
            findings.append(.init(id: "test-faults", severity: .testOnly,
                summary: "这是带故障注入的测试夹具，不要用于正式用途（M46）"))
        }
        return findings
    }

    /// 是否有需要用户尽快处理的问题（隔离 / 可靠性）。
    public static func needsAttention(_ findings: [GuestFinding]) -> Bool {
        findings.contains { $0.severity == .isolation || $0.severity == .reliability || $0.severity == .testOnly }
    }
}
