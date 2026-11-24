import Foundation

/// M26b：每沙箱的在途操作取消令牌。
///
/// 问题：同一沙箱的 VM 操作在 `opQueue` 上串行，长 exec（最长到其 timeout）会让随后的
/// `rm --force` / `stop` / `shutdown` 一直排队。
///
/// 做法：这些「拆除类」操作在排队**之前**先 `cancel()`——
/// - 正在执行的 guest 操作所在的 Swift Task 被取消，`VZRuntime` 轮询里的 `Task.sleep`
///   抛 `CancellationError`，操作立即以 `DBX-OP-CANCELLED` 返回，opQueue 随之腾空；
/// - 已排队但尚未开始的 guest 操作在入口处看到取消标记，直接拒绝。
///
/// 取消只发生在宿主侧：guest 里的进程不会被单独杀掉，它随 VM 一起消失。因此令牌只用于
/// 「VM 马上要停/销毁」的路径，不提供「取消一次 exec 但保留沙箱」的语义。
final class OpCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var reason = ""
    private var cancelCurrent: (() -> Void)?

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// 置取消标记并取消在途 Task。幂等。
    func cancel(reason: String) {
        lock.lock()
        // 后来者覆盖原因：升级只会朝「更彻底的拆除」方向发生（stop → rm/shutdown）。
        cancelled = true; self.reason = reason
        let current = cancelCurrent
        lock.unlock()
        current?()
    }

    /// `stop` 完成后解除**自己置的**标记（沙箱对象仍在，后续 `rm` 等操作要能继续）。
    /// 只在原因仍是 `ifReason` 时才解除：期间若有 `rm --force` / shutdown 接管了取消，不能被 stop 抹掉。
    func reset(ifReason expected: String) {
        lock.lock()
        if cancelled && reason == expected { cancelled = false; reason = "" }
        lock.unlock()
    }

    /// guest 操作入口：已取消则直接拒绝。
    func checkNotCancelled(op: String) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CLIError.usage(Self.message(op: op, reason: reason)) }
    }

    /// 登记在途 Task 的取消闭包；若此刻已取消，立即取消它（消除「先 cancel 后登记」的竞争窗）。
    func register(_ cancelTask: @escaping () -> Void) {
        lock.lock()
        cancelCurrent = cancelTask
        let already = cancelled
        lock.unlock()
        if already { cancelTask() }
    }

    func unregister() {
        lock.lock(); cancelCurrent = nil; lock.unlock()
    }

    func cancelledError(op: String) -> CLIError {
        lock.lock(); defer { lock.unlock() }
        return CLIError.usage(Self.message(op: op, reason: reason))
    }

    static func message(op: String, reason: String) -> String {
        "DBX-OP-CANCELLED: \(op) aborted (\(reason.isEmpty ? "sandbox is being torn down" : reason))"
    }
}
