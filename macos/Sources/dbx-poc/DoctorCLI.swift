import Foundation
import DeskBoxCore

/// M51：`dbx-poc doctor`——这台机器上正在运行的 daemon 与各沙箱的 guest 资产，相对于这个客户端的代码是否落后。
struct DoctorReport: Codable, Equatable {
    struct Sandbox: Codable, Equatable {
        let sandboxId: String
        let state: String
        /// nil = 没有查（沙箱不在 running）。
        var findings: [GuestFinding]?
        /// 查询失败的原因（例如控制面已丢失）。
        var statsError: String?
    }
    let clientRevision: Int
    /// nil = daemon 不认识 `info`（早于 M51）。
    var daemon: DaemonInfo?
    var daemonNote: String?
    var daemonMissingFixes: [String]
    var sandboxes: [Sandbox]

    /// 有任何需要处理的问题：daemon 较旧，或某台沙箱的 guest 有隔离 / 可靠性问题。
    var needsAttention: Bool {
        daemonNote != nil || sandboxes.contains { GuestCapabilityReport.needsAttention($0.findings ?? []) }
    }

    /// 人读的文本。
    func rendered() -> String {
        var lines: [String] = []
        lines.append("client     修订 \(clientRevision)")
        if let daemon {
            lines.append("daemon     修订 \(daemon.revision)  pid=\(daemon.pid)  启动于 \(daemon.startedAtUtc)  沙箱 \(daemon.sandboxCount) 台")
        } else {
            lines.append("daemon     不认识版本查询（早于修订 \(BuildRevision.current)）")
        }
        if let daemonNote {
            lines.append("  ! \(daemonNote)")
            for fix in daemonMissingFixes { lines.append("    - 缺少的修复：\(fix)") }
        } else {
            lines.append("  ok daemon 与客户端同一修订")
        }
        if sandboxes.isEmpty { lines.append("sandboxes  （没有）") }
        for sandbox in sandboxes {
            lines.append("sandbox    \(sandbox.sandboxId)  \(sandbox.state)")
            if let error = sandbox.statsError {
                lines.append("  ? 无法查询 guest 能力：\(error)")
            } else if let findings = sandbox.findings {
                if findings.isEmpty { lines.append("  ok guest 资产是最新的") }
                for finding in findings { lines.append("  ! [\(finding.severity.rawValue)] \(finding.summary)") }
            } else {
                lines.append("  - 不在 running，未检查 guest 能力")
            }
        }
        if sandboxes.contains(where: { !($0.findings ?? []).isEmpty }) {
            lines.append("")
            lines.append("guest 资产较旧的沙箱：重建 guest 资产（./scripts/build-alpine-guest.sh，或安装已验证的候选）后新建沙箱。")
        }
        return lines.joined(separator: "\n")
    }
}

enum DoctorCLI {
    /// 组装报告。`send` 是发请求的函数（测试里替换成假的 daemon）。
    static func gather(send: (DaemonRequest) throws -> DaemonResponse) throws -> DoctorReport {
        var report = DoctorReport(clientRevision: BuildRevision.current, daemon: nil, daemonNote: nil,
                                  daemonMissingFixes: [], sandboxes: [])
        // 先 ps：daemon 连不上就直接报错（由调用方决定退出码）。
        let listed = try send(DaemonRequest(kind: "ps"))
        do {
            report.daemon = try send(DaemonRequest(kind: "info")).info
        } catch {
            // 旧 daemon 以固定措辞拒绝不认识的请求；其它错误照常抛出。
            guard BuildRevision.isUnknownInfoRejection("\(error)") else { throw error }
        }
        let skew = BuildRevision.skew(daemonRevision: report.daemon?.revision)
        report.daemonNote = BuildRevision.note(for: skew)
        if case .daemonOlder(let revision) = skew { report.daemonMissingFixes = BuildRevision.missingFixes(daemonRevision: revision) }
        for info in listed.sandboxes ?? [] {
            var entry = DoctorReport.Sandbox(sandboxId: info.sandboxId, state: info.state, findings: nil, statsError: nil)
            if info.state == "running" {
                var request = DaemonRequest(kind: "stats")
                request.sandboxId = info.sandboxId
                do {
                    let stats = try send(request).stats
                    if let error = stats?.statsError, stats?.cpuUsageUsec == nil, stats?.workspaceSyncVersion == nil,
                       stats?.execOutputVersion == nil, stats?.childFdsVersion == nil {
                        // 软失败：没有拿到任何采样，也就没有能力字段可看。
                        entry.statsError = error
                    } else if let stats {
                        entry.findings = GuestCapabilityReport.findings(for: stats)
                    } else {
                        entry.statsError = "daemon 没有返回 stats"
                    }
                } catch {
                    entry.statsError = "\(error)"
                }
            }
            report.sandboxes.append(entry)
        }
        return report
    }

    static func run(args: [String]) throws {
        let p = try CLIArgs.parse(args, spec: DaemonCLISpecs.doctor)
        let sock = p.string("--daemon-sock")
        let report = try gather { try DaemonClient.send(request: $0, sockPath: sock) }
        if p.flag("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print(report.rendered())
        }
        // --strict：有需要处理的问题时以 3 退出（供脚本 / CI 用）；缺省只报告。
        if p.flag("--strict"), report.needsAttention { throw CLIError.exit(3) }
    }
}
