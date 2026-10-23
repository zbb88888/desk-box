import Foundation

/// 统一身份模型（docs/design/two-layer-security-model.md §3、§7.1）。
/// 所有跨边界请求绑定：user -> workspace -> sandbox -> VM boot -> session。
/// 身份是强类型值，PID、端口或可复用名称不能单独作为身份。
public struct Identity<Domain>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }

    public static func new() -> Identity<Domain> { Identity(UUID().uuidString) }

    public var description: String { raw }
}

public enum SandboxDomain {}
public enum WorkspaceDomain {}
public enum UserDomain {}
public enum AgentDomain {}
public enum BootDomain {}
public enum GrantDomain {}
public enum SessionDomain {}

public typealias SandboxID = Identity<SandboxDomain>
public typealias WorkspaceID = Identity<WorkspaceDomain>
public typealias UserID = Identity<UserDomain>
public typealias AgentID = Identity<AgentDomain>
public typealias BootID = Identity<BootDomain>
public typealias GrantID = Identity<GrantDomain>
public typealias SessionID = Identity<SessionDomain>
