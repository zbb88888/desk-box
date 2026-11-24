import Foundation

/// M41：一台沙箱里「正在 guest 上执行」的那条 exec（线程安全；纯状态，不做 I/O）。
///
/// 同一沙箱的 guest 操作由 opQueue 串行，所以任一时刻最多一条在途。排队中的 exec 不算在途
///（`begin` 在轮到它、即将发给 guest 时才调用）。`execCancel` 用它回答三个问题：
/// 现在有没有在途的 exec？我发出取消之后，**那一条**结束了没有？它是被取消的还是自己跑完的？
final class ExecTracker: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        case running
        case finished(cancelled: Bool)
    }

    private let lock = NSLock()
    private var nextToken: UInt64 = 1
    private var currentToken: UInt64?
    /// 最近结束的若干条的结果（取消方在它结束之后来查询）。
    private var finished: [UInt64: Bool] = [:]
    private var finishedOrder: [UInt64] = []
    private static let remembered = 16

    func begin() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let token = nextToken
        nextToken += 1
        currentToken = token
        return token
    }

    func end(_ token: UInt64, cancelled: Bool) {
        lock.lock(); defer { lock.unlock() }
        if currentToken == token { currentToken = nil }
        finished[token] = cancelled
        finishedOrder.append(token)
        if finishedOrder.count > Self.remembered {
            finished.removeValue(forKey: finishedOrder.removeFirst())
        }
    }

    /// 当前在途 exec 的令牌；没有则为 nil。
    var current: UInt64? {
        lock.lock(); defer { lock.unlock() }
        return currentToken
    }

    /// 某条 exec 的状态。太久以前结束、已被遗忘的令牌按「已结束、未被取消」处理。
    func outcome(of token: UInt64) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        if currentToken == token { return .running }
        return .finished(cancelled: finished[token] ?? false)
    }
}

/// M41：`execCancel` 的结论（纯函数）。按**实际结果**分类，不预测 guest 是否支持取消。
enum ExecCancelVerdict: Equatable {
    case cancelled
    /// 取消到达之前它已经自己结束了。
    case alreadyFinished
    /// 取消帧发出后，在等待时间内 exec 仍未结束——guest 不支持取消（旧资产）。
    case unsupported
    case notRunning

    static let waitSeconds = 3.0
    static let unsupportedCode = "DBX-EXEC-CANCEL-UNSUPPORTED"
    static let notRunningCode = "DBX-EXEC-NOT-RUNNING"

    static func classify(hadInFlight: Bool, outcomeAfterWait: ExecTracker.Outcome) -> ExecCancelVerdict {
        guard hadInFlight else { return .notRunning }
        switch outcomeAfterWait {
        case .running: return .unsupported
        case .finished(cancelled: true): return .cancelled
        case .finished(cancelled: false): return .alreadyFinished
        }
    }

    /// 成功时给调用方的一行说明；失败时为 nil（见 `refusal`）。
    var message: String? {
        switch self {
        case .cancelled: return "exec cancelled"
        case .alreadyFinished: return "exec already finished"
        case .unsupported, .notRunning: return nil
        }
    }

    var refusal: String? {
        switch self {
        case .cancelled, .alreadyFinished: return nil
        case .notRunning:
            return "\(Self.notRunningCode): 这台沙箱当前没有在途的 exec"
        case .unsupported:
            return "\(Self.unsupportedCode): 取消请求已发出，但命令在 \(Int(Self.waitSeconds))s 内没有结束——"
                + "这台沙箱的 guest 资产较旧，不支持取消在途的 exec。可以等它结束或超时，"
                + "或用 stop / rm --force 结束整个沙箱。"
        }
    }
}
