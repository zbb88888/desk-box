import CoreGraphics
import Foundation

/// M27：宿主登录会话状态。
enum HostSession {
    /// 当前登录会话是否锁屏。拿不到会话字典（如无 GUI 会话的 ssh/CI 环境）返回 nil。
    static func isScreenLocked() -> Bool? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

/// M27：resume 失败的可读诊断（纯函数，可单元测试）。
///
/// 事实依据（2026-11，macOS 27 / Apple Silicon 实测）：登录会话锁屏期间，
/// `VZVirtualMachine.restoreMachineStateFrom` 以 `VZErrorDomain Code=12 … "permission denied"`
/// 失败；同一份、此前在未锁屏时工作正常的旧版本二进制在锁屏时同样失败。suspend（保存）不受影响。
/// 用户看到的只有一句 `permission denied`，完全看不出与锁屏有关。
///
/// 这里只做**解释**，不改变行为：resume 失败后沙箱仍是 suspended、快照保留，解锁后可重试。
enum ResumeDiagnostics {
    static let lockedCode = "DBX-RESUME-HOST-LOCKED"
    static let restoreFailedCode = "DBX-RESUME-VZ-RESTORE-FAILED"

    /// VZ 的 restore 错误（VZError.Code.restore == 12）。
    static func isVZRestoreError(_ description: String) -> Bool {
        description.contains("VZErrorDomain") && description.contains("Code=12")
    }

    /// - Returns: 需要改写的错误消息；不是 VZ restore 错误时返回 nil（保持原错误）。
    static func explain(errorDescription: String, screenLocked: Bool?) -> String? {
        guard isVZRestoreError(errorDescription) else { return nil }
        let underlying = BootDiagnostics.sanitize(errorDescription, limit: 240)
        let kept = "沙箱仍为 suspended，快照已保留"
        switch screenLocked {
        case true?:
            return "\(lockedCode): Virtualization.framework 拒绝恢复 VM 状态，当前登录会话处于锁屏状态"
                + "（锁屏期间无法恢复已保存的 VM 状态）。请解锁后重试 resume；\(kept) | underlying: \(underlying)"
        case false?:
            return "\(restoreFailedCode): Virtualization.framework 无法恢复 VM 状态（会话未锁屏）；\(kept) | underlying: \(underlying)"
        case nil:
            return "\(restoreFailedCode): Virtualization.framework 无法恢复 VM 状态（无法判断会话是否锁屏；"
                + "若宿主处于锁屏状态，请解锁后重试）；\(kept) | underlying: \(underlying)"
        }
    }
}
