import Foundation

/// 审计事件（docs/security/threat-model.md §8，security-verification-matrix §5）。
/// 只允许安全 metadata；协议上不存在携带 secret 的字段——
/// Authorization/Cookie/body/prompt/模型响应/token 派生值无处存放。
public enum AuditAction: String, Sendable, Codable {
    case create
    case start
    case confirmRunning
    case stop
    case suspend
    case resume
    case destroy
    case specCompile
    case grantDecision
    case lifecycleTransition
    case networkDecision
    case endpointResolve
    case channelEvent
}

public struct AuditEvent: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let platform: SandboxPlatform
    public let sandboxID: SandboxID
    public let bootID: BootID?
    public let workloadDigest: String?
    public let grantID: GrantID?
    public let action: AuditAction
    public let decision: Decision
    public let correlationID: UUID

    public init(
        platform: SandboxPlatform,
        sandboxID: SandboxID,
        bootID: BootID? = nil,
        workloadDigest: String? = nil,
        grantID: GrantID? = nil,
        action: AuditAction,
        decision: Decision,
        correlationID: UUID,
        timestamp: Date = Date()
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.platform = platform
        self.sandboxID = sandboxID
        self.bootID = bootID
        self.workloadDigest = workloadDigest
        self.grantID = grantID
        self.action = action
        self.decision = decision
        self.correlationID = correlationID
    }
}

/// 审计汇。同步接口保证 adapter 串行队列上的顺序。
public protocol AuditSink: Sendable {
    func record(_ event: AuditEvent)
}

/// 测试与 POC 用的内存汇；发布实现需满足矩阵 §5 的证据格式。
public final class InMemoryAuditSink: AuditSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AuditEvent] = []

    public init() {}

    public func record(_ event: AuditEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    public var events: [AuditEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
