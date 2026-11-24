import Foundation

/// M37：是否允许把宿主目录同步进一台「已经运行过 workload」的沙箱（纯函数）。
///
/// 问题在 guest 一侧：旧的 workspace 接收端（版本 1）以 root 身份按路径打开 `/workspace/<rel>`，
/// 会跟随符号链接。沙箱内的 workload（uid 65534）无法直接写 /workspace 之外的地方，但它可以在
/// 自己创建的子目录里放一个符号链接；下一次同步时 root 就会把宿主 workspace 的文件内容写到它
/// 指定的任意 guest 路径，并把目标 chown 给它——由此越过 guest 内的第二道隔离
/// （uid / Landlock / seccomp）。VM 边界不受影响。真机复现见 docs/design/m37-workspace-sync-boundary.md。
///
/// 修复在 guest（接收端版本 2：逐级 O_NOFOLLOW）。但宿主不能假设 guest 已经更新，所以：
/// - workload 还没运行过：/workspace 里只有 bootstrap 自己放的东西，任何版本都可以同步；
/// - workload 运行过：只有 guest 上报的接收端版本 ≥ 2 才允许；
/// - 否则拒绝，除非调用方显式接受风险（`allowUnsafeResync`）。
enum WorkspaceResyncPolicy {
    static let safeReceiverVersion = 2
    static let refusalCode = "DBX-WS-RESYNC-UNSAFE"

    /// - Parameter guestReceiverVersion: guest 经 stats 上报的版本；旧 guest 不上报（nil → 按 1）。
    ///   查询失败同样传 nil（fail-closed）。
    /// - Returns: 拒绝原因；nil 表示允许。
    static func refusal(workloadStarted: Bool, guestReceiverVersion: Int?, allowUnsafe: Bool) -> String? {
        guard workloadStarted else { return nil }
        let version = guestReceiverVersion ?? 1
        if version >= safeReceiverVersion { return nil }
        if allowUnsafe { return nil }
        return "\(refusalCode): 这台沙箱已经运行过 workload，而它的 guest 资产较旧（workspace 接收端版本 \(version)，"
            + "需要 ≥ \(safeReceiverVersion)）：再次同步时 guest 会跟随 workload 放在 /workspace 里的符号链接，"
            + "以 root 身份写到 /workspace 之外。请新建沙箱后先同步再运行，或升级 guest 资产；"
            + "确需继续可显式加 --allow-unsafe-resync。"
    }
}
