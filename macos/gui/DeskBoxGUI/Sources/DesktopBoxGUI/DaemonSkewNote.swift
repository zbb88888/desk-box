import Foundation
import DeskBoxCore

/// GUI 有自己的一套线上类型（与 DeskBoxCore 里的同名类型不是同一个），所以别处不整体 import DeskBoxCore；
/// 需要共用的类型在这里起别名。
typealias DaemonInfo = DeskBoxCore.DaemonInfo
typealias GuestFinding = DeskBoxCore.GuestFinding

/// M52：Stats 面板里「这台沙箱的 guest 资产缺什么」。
enum GuestFindingsNote {
    /// nil = 这次采样没有拿到 guest 的应答（软失败），无从判断；空数组 = guest 是最新的。
    static func findings(for stats: SandboxStats) -> [GuestFinding]? {
        if stats.statsError != nil, stats.cpuUsageUsec == nil, stats.memoryCurrentBytes == nil { return nil }
        return GuestCapabilityReport.findings(for: GuestCapabilities(
            workspaceSyncVersion: stats.workspaceSyncVersion, execOutputVersion: stats.execOutputVersion,
            execCancelVersion: stats.execCancelVersion, brokerVersion: stats.brokerVersion,
            childFdsVersion: stats.childFdsVersion, testFaults: stats.testFaults))
    }

    static func needsAttention(_ findings: [GuestFinding]) -> Bool { GuestCapabilityReport.needsAttention(findings) }

    /// 面板上的标题行。
    static func headline(_ findings: [GuestFinding]) -> String {
        let serious = findings.filter { $0.severity == .isolation }.count
        if serious > 0 { return "这台沙箱的 guest 资产较旧：缺 \(findings.count) 项修复，其中 \(serious) 项涉及隔离" }
        return "这台沙箱的 guest 资产较旧：缺 \(findings.count) 项"
    }
}

/// M51：把 `info` 请求的结果变成界面顶部的提示（纯函数）。
enum DaemonSkewNote {
    enum Outcome: Equatable {
        /// 查到了：有偏差时是提示文字，没有偏差是 nil。
        case note(String?)
        /// 这次没问成（连接问题）：下次刷新再问。
        case retryLater
    }

    /// 这个 App 的修订号。
    static var clientRevision: Int { BuildRevision.current }

    static func evaluate(_ result: Result<DaemonResponse, Error>) -> Outcome {
        switch result {
        case .success(let response):
            guard let info = response.info else {
                // 应答成功却没有 info 字段：按「不认识版本查询」处理。
                return .note(text(daemonRevision: nil))
            }
            return .note(text(daemonRevision: info.revision))
        case .failure(let error):
            // 旧 daemon 以固定措辞拒绝不认识的请求。
            if BuildRevision.isUnknownInfoRejection("\(error)") || BuildRevision.isUnknownInfoRejection(error.localizedDescription) {
                return .note(text(daemonRevision: nil))
            }
            return .retryLater
        }
    }

    private static func text(daemonRevision: Int?) -> String? {
        let skew = BuildRevision.skew(daemonRevision: daemonRevision)
        guard var note = BuildRevision.note(for: skew) else { return nil }
        if case .daemonOlder(let revision) = skew {
            let missing = BuildRevision.missingFixes(daemonRevision: revision)
            if !missing.isEmpty { note += " 它缺少的修复包括：" + missing.suffix(3).joined(separator: "；") + "。" }
        }
        return note
    }
}
