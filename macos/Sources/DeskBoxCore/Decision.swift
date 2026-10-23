import Foundation

/// 稳定 reason code registry（docs/design/two-layer-security-model.md §3、§7.3）。
/// 新增 code 必须在此登记并递增兼容性说明；平台 adapter 可以补充
/// 平台 code（DBX-VZ-*/DBX-HV-*），但不能改变公共 code 的含义。
public struct ReasonCode: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Registry 语义版本；code 含义变化时必须递增。
    public static let registryVersion = 1

    public let value: String

    public init(_ value: String) { self.value = value }

    public var description: String { value }

    // MARK: 决策
    public static let policyAllowed = ReasonCode("DBX-POLICY-ALLOW")
    public static let policyStateUnknown = ReasonCode("DBX-POLICY-STATE-UNKNOWN")

    // MARK: WorkloadSpec 编译（架构 §5.2）
    public static let specUserRootDenied = ReasonCode("DBX-SPEC-USER-ROOT-DENIED")
    public static let specUserInvalid = ReasonCode("DBX-SPEC-USER-INVALID")
    public static let specEnvDropped = ReasonCode("DBX-SPEC-ENV-DROPPED")
    public static let specVolumeDropped = ReasonCode("DBX-SPEC-VOLUME-DROPPED")
    public static let specPortInvalid = ReasonCode("DBX-SPEC-PORT-INVALID")
    public static let specWorkdirInvalid = ReasonCode("DBX-SPEC-WORKDIR-INVALID")
    public static let specResourceClamped = ReasonCode("DBX-SPEC-RESOURCE-CLAMPED")

    // MARK: CredentialGrant（威胁模型 §6）
    public static let grantNotFound = ReasonCode("DBX-GRANT-NOT-FOUND")
    public static let grantAmbiguous = ReasonCode("DBX-GRANT-AMBIGUOUS")
    public static let grantExpired = ReasonCode("DBX-GRANT-EXPIRED")
    public static let grantNotYetValid = ReasonCode("DBX-GRANT-NOT-YET-VALID")
    public static let grantSubjectMismatch = ReasonCode("DBX-GRANT-SUBJECT-MISMATCH")
    public static let grantTargetMismatch = ReasonCode("DBX-GRANT-TARGET-MISMATCH")
    public static let grantInvalid = ReasonCode("DBX-GRANT-INVALID")

    // MARK: 生命周期（架构 §5.1）
    public static let lifecycleCreated = ReasonCode("DBX-LIFECYCLE-CREATED")
    public static let lifecycleBooted = ReasonCode("DBX-LIFECYCLE-BOOTED")
    public static let lifecycleRunningConfirmed = ReasonCode("DBX-LIFECYCLE-RUNNING-CONFIRMED")
    public static let lifecycleInvalidTransition = ReasonCode("DBX-LIFECYCLE-INVALID-TRANSITION")
    public static let lifecycleStopRequested = ReasonCode("DBX-LIFECYCLE-STOP-REQUESTED")
    public static let lifecycleStopped = ReasonCode("DBX-LIFECYCLE-STOPPED")
    public static let lifecycleSuspended = ReasonCode("DBX-LIFECYCLE-SUSPENDED")
    public static let lifecycleResuming = ReasonCode("DBX-LIFECYCLE-RESUMING")
    public static let lifecycleUnexpectedExit = ReasonCode("DBX-LIFECYCLE-UNEXPECTED-EXIT")
    public static let lifecycleDestroyCleanupFailed = ReasonCode("DBX-LIFECYCLE-DESTROY-CLEANUP-FAILED")
    public static let lifecycleDestroyed = ReasonCode("DBX-LIFECYCLE-DESTROYED")

    // MARK: 控制通道（design/control-channel-security.md）
    public static let bootstrapProofMissing = ReasonCode("DBX-BOOT-PROOF-MISSING")
    public static let bootstrapProofMismatch = ReasonCode("DBX-BOOT-PROOF-MISMATCH")
    public static let bootstrapProofAccepted = ReasonCode("DBX-BOOT-PROOF-ACCEPTED")
    public static let bootstrapHelloAccepted = ReasonCode("DBX-BOOT-HELLO-ACCEPTED")
    public static let bootstrapTLSRequired = ReasonCode("DBX-BOOT-TLS-REQUIRED")

    // MARK: 平台
    public static let platformCapabilityUnavailable = ReasonCode("DBX-PLATFORM-CAPABILITY-UNAVAILABLE")
    public static let platformSuspendDisabled = ReasonCode("DBX-PLATFORM-SUSPEND-DISABLED")
    public static let platformAssetDigestMismatch = ReasonCode("DBX-PLATFORM-ASSET-DIGEST-MISMATCH")
    public static let platformNetworkDeniedByDefault = ReasonCode("DBX-PLATFORM-NETWORK-DENIED-BY-DEFAULT")
    public static let platformCowUnavailable = ReasonCode("DBX-PLATFORM-COW-UNAVAILABLE")
    public static let platformCowCleanupFailed = ReasonCode("DBX-PLATFORM-COW-CLEANUP-FAILED")
}

/// 统一决策模型（docs/design/two-layer-security-model.md §3-4）。
/// 状态不明确时只能 deny/error；`isAllowed` 是对这一规则的硬性编码。
public enum Decision: Sendable, Codable, Equatable {
    case allow(reason: ReasonCode, message: String)
    case deny(ReasonCode, String)
    case error(ReasonCode, String)

    public var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }

    public var reasonCode: ReasonCode {
        switch self {
        case .allow(let reason, _): return reason
        case .deny(let reason, _): return reason
        case .error(let reason, _): return reason
        }
    }

    public var message: String {
        switch self {
        case .allow(_, let message): return message
        case .deny(_, let message): return message
        case .error(_, let message): return message
        }
    }

    public static func allow(_ message: String = "") -> Decision {
        .allow(reason: .policyAllowed, message: message)
    }
}

/// 所有运行时失败的统一形态：必须带稳定 reason code。
public struct SandboxFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public let reason: ReasonCode
    public let message: String

    public init(_ reason: ReasonCode, _ message: String) {
        self.reason = reason
        self.message = message
    }

    public var description: String { "\(reason.value): \(message)" }
}
