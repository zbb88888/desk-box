import Foundation

public enum SandboxPlatform: String, Sendable, Codable {
    case vz
    case hyperv
    case mock
}

/// VM 网络模式。默认无任意出口（威胁模型不变量 4）：
/// Broker 数据面通过独立 vsock 通道（Broker 设计 §2）而非 NIC。
/// diagnosticNAT 仅供诊断，必须显式开启并在审计中留痕。
public enum SandboxNetworkMode: String, Sendable, Codable {
    case none
    case diagnosticNAT
}

/// 签名的 guest asset 清单（控制通道设计 §3：宿主启动前校验 digest）。
public struct GuestAssetManifest: Sendable, Equatable, Codable {
    public let kernelURL: URL
    public let initrdURL: URL?
    public let rootDiskURL: URL
    public let kernelCommandLine: String
    /// 预期安全最低版本（防降级）；与宿主记录的最低版本比较后决定。
    public let guestAssetVersion: Int
    /// manifest 自身的 digest（BootContext 绑定字段）。
    public let manifestDigest: String
    /// 文件绝对路径 -> sha256 hex；kernel/initrd/rootDisk 必须在内。
    public let fileDigests: [String: String]

    public init(
        kernelURL: URL,
        initrdURL: URL?,
        rootDiskURL: URL,
        kernelCommandLine: String,
        guestAssetVersion: Int,
        manifestDigest: String,
        fileDigests: [String: String]
    ) {
        self.kernelURL = kernelURL
        self.initrdURL = initrdURL
        self.rootDiskURL = rootDiskURL
        self.kernelCommandLine = kernelCommandLine
        self.guestAssetVersion = guestAssetVersion
        self.manifestDigest = manifestDigest
        self.fileDigests = fileDigests
    }
}

public struct SandboxCreateRequest: Sendable, Codable {
    public var sandboxID: SandboxID
    public var workspaceID: WorkspaceID
    public var correlationID: UUID
    public var workloadDigest: String
    public var workload: WorkloadSpec
    public var guestAssets: GuestAssetManifest
    public var resources: ResourceHints
    public var networking: SandboxNetworkMode
    public var controlChannelPort: UInt32

    public init(
        sandboxID: SandboxID,
        workspaceID: WorkspaceID,
        correlationID: UUID,
        workloadDigest: String,
        workload: WorkloadSpec,
        guestAssets: GuestAssetManifest,
        resources: ResourceHints,
        networking: SandboxNetworkMode = .none,
        controlChannelPort: UInt32 = 1024
    ) {
        self.sandboxID = sandboxID
        self.workspaceID = workspaceID
        self.correlationID = correlationID
        self.workloadDigest = workloadDigest
        self.workload = workload
        self.guestAssets = guestAssets
        self.resources = resources
        self.networking = networking
        self.controlChannelPort = controlChannelPort
    }
}

public struct SandboxHandle: Sendable, Hashable, Codable {
    public let sandboxID: SandboxID
    public let bootID: BootID

    public init(sandboxID: SandboxID, bootID: BootID) {
        self.sandboxID = sandboxID
        self.bootID = bootID
    }
}

public enum EndpointTransport: Sendable, Codable, Equatable {
    case vsock(port: UInt32)
}

public struct EndpointDescriptor: Sendable, Codable, Equatable {
    public let name: String
    public let transport: EndpointTransport

    public init(name: String, transport: EndpointTransport) {
        self.name = name
        self.transport = transport
    }
}

public struct SandboxStatus: Sendable, Equatable {
    public let sandboxID: SandboxID
    public let bootID: BootID?
    public let platform: SandboxPlatform
    public let state: SandboxState
    public let correlationID: UUID
    public let history: [LifecycleMachine.Transition]
    public let endpoints: [EndpointDescriptor]

    public init(
        sandboxID: SandboxID,
        bootID: BootID?,
        platform: SandboxPlatform,
        state: SandboxState,
        correlationID: UUID,
        history: [LifecycleMachine.Transition],
        endpoints: [EndpointDescriptor]
    ) {
        self.sandboxID = sandboxID
        self.bootID = bootID
        self.platform = platform
        self.state = state
        self.correlationID = correlationID
        self.history = history
        self.endpoints = endpoints
    }
}

/// 平台无关生命周期接口（架构 §5.1）。
///
/// 语义契约（两平台必须一致，由 ConformanceTests 强制）：
/// - create 只做配置与资产检查，VM 未运行，状态 pending；
/// - start 启动 VM 并返回本次 BootContext；状态仍为 pending，
///   直到 confirmRunning 携带绑定 proof 通过（控制通道设计 §5）；
/// - stop/destroy 幂等；destroy 失败必须抛错且状态保持
///   .stopping/.failed，不得乐观报告已销毁（架构 §8.3）；
/// - suspend/resume 属于平台可选能力：不可用必须抛
///   platformSuspendDisabled / platformCapabilityUnavailable，
///   不允许静默降级（平台矩阵 §7）。
public protocol SandboxRuntime: Sendable {
    var platform: SandboxPlatform { get }

    func create(_ request: SandboxCreateRequest) async throws -> SandboxHandle
    func start(_ handle: SandboxHandle) async throws -> BootContext
    func confirmRunning(_ handle: SandboxHandle, proof: BootstrapProof) async throws
    func stop(_ handle: SandboxHandle) async throws
    func suspend(_ handle: SandboxHandle) async throws
    func resume(_ handle: SandboxHandle) async throws -> BootContext
    func destroy(_ handle: SandboxHandle) async throws
    func inspect(_ handle: SandboxHandle) async throws -> SandboxStatus
    func resolveEndpoint(_ handle: SandboxHandle, name: String) async throws -> EndpointDescriptor?
}
