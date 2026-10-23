import Foundation

/// 固定生命周期状态集（docs/architecture/desktop-vm-sandbox.md §5.1）。
public enum SandboxState: String, Sendable, Codable, CaseIterable {
    case pending
    case running
    case suspending
    case suspended
    case resuming
    case stopping
    case stopped
    case failed

    /// 终态仅表示宿主已完成逆序回收（双层模型 §7.4）。
    public var isTerminal: Bool { self == .stopped }
}

/// 生命周期状态机。
/// 关键不变量：
/// - 进入 .running 必须持与当前 boot 绑定的 BootstrapProof
///   （控制通道设计 §5：handshake 全部满足后才允许发布 Running）；
/// - 非法转换一律失败关闭；
/// - 清理失败保持 .stopping/.failed，不得乐观报告已销毁（架构 §8.3）；
/// - resume 必须轮换 boot 上下文（旧会话/旧 token 不可复活）。
public struct LifecycleMachine: Sendable, Equatable {
    public struct Transition: Sendable, Codable, Equatable {
        public let from: SandboxState
        public let to: SandboxState
        public let reason: ReasonCode
        public let at: Date
        public let correlationID: UUID
    }

    private struct Edge: Hashable {
        let from: SandboxState
        let to: SandboxState
    }

    private static let allowed: Set<Edge> = [
        Edge(from: .pending, to: .running),
        Edge(from: .pending, to: .stopping),
        Edge(from: .pending, to: .failed),
        Edge(from: .running, to: .suspending),
        Edge(from: .running, to: .stopping),
        Edge(from: .running, to: .failed),
        Edge(from: .suspending, to: .suspended),
        Edge(from: .suspending, to: .stopping),
        Edge(from: .suspending, to: .failed),
        Edge(from: .suspended, to: .resuming),
        Edge(from: .suspended, to: .stopping),
        Edge(from: .suspended, to: .failed),
        Edge(from: .resuming, to: .running),
        Edge(from: .resuming, to: .stopping),
        Edge(from: .resuming, to: .failed),
        Edge(from: .stopping, to: .stopped),
        Edge(from: .stopping, to: .failed),
        Edge(from: .failed, to: .stopping),
    ]

    public let sandboxID: SandboxID
    public let correlationID: UUID
    public private(set) var state: SandboxState
    public private(set) var currentBoot: BootContext
    public private(set) var history: [Transition]

    public init(sandboxID: SandboxID, boot: BootContext, correlationID: UUID) {
        self.sandboxID = sandboxID
        self.correlationID = correlationID
        self.state = .pending
        self.currentBoot = boot
        self.history = []
    }

    /// resume 前由宿主轮换 boot 上下文（新 bootID/nonce），
    /// 使旧 snapshot/旧会话材料失效（架构 §8.2、威胁模型不变量 10）。
    public mutating func rotateBoot(_ context: BootContext) {
        currentBoot = context
    }

    public mutating func transition(
        to target: SandboxState,
        reason: ReasonCode,
        proof: BootstrapProof? = nil,
        now: Date = Date()
    ) throws {
        guard Self.allowed.contains(Edge(from: state, to: target)) else {
            throw SandboxFailure(.lifecycleInvalidTransition, "\(state.rawValue) -> \(target.rawValue) 不是合法转换")
        }
        if target == .running {
            guard let proof else {
                throw SandboxFailure(.bootstrapProofMissing, "进入 running 必须提供与 boot 绑定的 proof")
            }
            let decision = BootstrapProof.verify(
                proof,
                against: currentBoot,
                expectedProtocolMajor: ControlChannelProtocol.currentMajor
            )
            guard decision.isAllowed else {
                throw SandboxFailure(.bootstrapProofMismatch, decision.message)
            }
        }
        history.append(Transition(from: state, to: target, reason: reason, at: now, correlationID: correlationID))
        state = target
    }

    /// VM 失控退出等不可恢复事件：不受转换表约束地收紧到 failed，
    /// 再经 destroy 收敛（失败规则，双层模型 §9）。
    public mutating func forceFail(reason: ReasonCode, now: Date = Date()) {
        guard state != .stopped, state != .failed else { return }
        history.append(Transition(from: state, to: .failed, reason: reason, at: now, correlationID: correlationID))
        state = .failed
    }
}
