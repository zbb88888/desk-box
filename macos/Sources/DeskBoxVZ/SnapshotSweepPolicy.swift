import Foundation

/// M27：快照目录清扫策略（纯函数，可单元测试）。
///
/// 背景：suspend / resume 期间，VZ 状态先落到 `snapshots/` 下的临时文件。旧策略是
/// 「`tmp-*` 一律删除」。M24 用进程内登记表挡住了**同进程**的并发 sweep，但另一个进程
/// （`dbx-poc sweep`、或同一 cow-root 上的另一个 daemon）仍会把在途文件当孤儿删掉，
/// 导致正在进行的 suspend/resume 失败。
///
/// 现在临时文件名里带属主 PID：`tmp-p<pid>-<uuid>.vzstate` / `tmp-restore-p<pid>-<uuid>.vzstate`。
/// - 属主进程活着 → 在途，保留（跨进程成立，进程内登记表不再需要）；
/// - 属主已死 → 崩溃残留，删除；
/// - 旧格式（无 PID，由旧版本二进制产生）→ 无法判断属主：只删「足够老」的，
///   给可能仍在运行的旧版本 daemon 留出完成窗口；
/// - 任何临时文件超过 `maxAge` 一律删除（防 PID 复用导致永久残留）。
public enum SnapshotSweepPolicy {
    /// 旧格式临时文件的保留窗口。一次 suspend/resume 是秒级操作。
    public static let legacyGrace: TimeInterval = 10 * 60
    /// 任何临时文件的寿命上限。
    public static let maxAge: TimeInterval = 24 * 60 * 60

    public enum Verdict: Equatable, Sendable {
        case keep
        case remove
        /// 不是本策略管理的文件，原样不动。
        case ignore
    }

    public static func suspendTempName(pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                       uuid: UUID = UUID()) -> String {
        "tmp-p\(pid)-\(uuid.uuidString).vzstate"
    }

    public static func restoreTempName(pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                       uuid: UUID = UUID()) -> String {
        "tmp-restore-p\(pid)-\(uuid.uuidString).vzstate"
    }

    /// 解析临时文件名里的属主 PID；旧格式或非法 → nil。
    static func ownerPID(ofTempName name: String) -> Int32? {
        var rest: Substring
        if name.hasPrefix("tmp-restore-") { rest = name.dropFirst("tmp-restore-".count) }
        else if name.hasPrefix("tmp-") { rest = name.dropFirst("tmp-".count) }
        else { return nil }
        guard rest.hasPrefix("p") else { return nil }
        rest = rest.dropFirst()
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        // 必须是 `p<digits>-…`，且 PID 为正（kill(0)/kill(-1) 语义完全不同，绝不能喂进去）。
        guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix("-"),
              let pid = Int32(digits), pid > 0 else { return nil }
        return pid
    }

    /// - Parameters:
    ///   - liveSandboxIDs: registry 中属主进程仍存活的沙箱 ID（其 `.snap` 必须保留）。
    ///   - age: 文件年龄（秒）；取不到 mtime 时传 nil → 按「年轻」处理（宁可晚删）。
    public static func verdict(name: String, liveSandboxIDs: Set<String>, age: TimeInterval?,
                               isProcessAlive: (Int32) -> Bool) -> Verdict {
        if name.hasSuffix(".snap") {
            return liveSandboxIDs.contains(String(name.dropLast(5))) ? .keep : .remove
        }
        guard name.hasPrefix("tmp-") else { return .ignore }
        if let age, age > maxAge { return .remove }
        if let pid = ownerPID(ofTempName: name) {
            return isProcessAlive(pid) ? .keep : .remove
        }
        // 旧格式：属主未知。
        guard let age else { return .keep }
        return age > legacyGrace ? .remove : .keep
    }
}
