import Foundation

/// M37：exec 的 argv[0] / cwd 白名单（纯函数）。
///
/// 此前的判断是 `hasPrefix("/workspace/")`：`/workspace/../bin/busybox` 被当成「workspace 里的
/// 可执行文件」，`--cwd /workspace/../etc` 被当成「workspace 里的目录」。由于 `/bin/sh` 本来就在
/// 白名单里，这不构成越权，但白名单表达的意图（只运行固定工具或 workspace 内的东西、只在
/// workspace 内工作）是可以被绕过的——修掉它，让策略说的和做的一致。
public enum ExecPathPolicy {
    /// 允许直接执行的固定二进制。
    public static let allowedBinaries: Set<String> = ["/bin/echo", "/bin/sh", "/bin/hardening-probe"]

    /// 是否是 `/workspace` 之下的规范绝对路径：不含 `.` / `..` / 空组件（`//`）/ NUL。
    public static func isBeneathWorkspace(_ path: String, allowRoot: Bool) -> Bool {
        if path == "/workspace" { return allowRoot }
        guard path.hasPrefix("/workspace/"), !path.utf8.contains(0) else { return false }
        let components = path.dropFirst("/workspace/".count).split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    public static func allowsExecutable(_ argv0: String) -> Bool {
        allowedBinaries.contains(argv0) || isBeneathWorkspace(argv0, allowRoot: false)
    }

    public static func allowsWorkingDirectory(_ cwd: String?) -> Bool {
        guard let cwd else { return true }
        return isBeneathWorkspace(cwd, allowRoot: true)
    }
}
