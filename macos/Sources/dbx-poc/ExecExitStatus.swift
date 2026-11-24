import Foundation

/// M39：guest 命令的退出码 → `dbx-poc exec` 进程的退出状态（纯函数）。
///
/// 与 shell 的约定一致：0–255 原样；guest 的内部负值按 8 位截断
///（-2「超时，进程组已被杀」→ 254；-1「未能启动」→ 255）；超出范围的值同样截断，但绝不把非零变成 0。
enum ExecExitStatus {
    static func processStatus(forGuestExitCode code: Int) -> Int32 {
        if code == 0 { return 0 }
        let truncated = Int32(truncatingIfNeeded: code) & 0xff
        return truncated == 0 ? 1 : truncated
    }
}
