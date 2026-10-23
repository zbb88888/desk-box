import Foundation
import Virtualization

/// 平台能力探测结果（docs/design/platform-capability-matrix.md §2-3）。
/// 能力缺失必须显式失败，不允许静默降级到容器/WSL2 等价物。
public struct VZCapabilityReport: Sendable, Codable, Equatable {
    public var osVersion: String
    public var hardwareModel: String
    public var virtualizationSupported: Bool
    public var virtioSocketSupported: Bool
    public var entropyDeviceSupported: Bool
    public var balloonDeviceSupported: Bool
    public var saveRestoreSupported: Bool
    /// entitlement 只能在真实签名启动时最终确认；此处给出探测提示。
    public var entitlementNote: String
    /// 产品最低版本冻结前，suspend/resume 默认必须关闭（矩阵 §7）。
    public var suspendFeatureDefault: Bool

    public init(
        osVersion: String,
        hardwareModel: String,
        virtualizationSupported: Bool,
        virtioSocketSupported: Bool,
        entropyDeviceSupported: Bool,
        balloonDeviceSupported: Bool,
        saveRestoreSupported: Bool,
        entitlementNote: String,
        suspendFeatureDefault: Bool
    ) {
        self.osVersion = osVersion
        self.hardwareModel = hardwareModel
        self.virtualizationSupported = virtualizationSupported
        self.virtioSocketSupported = virtioSocketSupported
        self.entropyDeviceSupported = entropyDeviceSupported
        self.balloonDeviceSupported = balloonDeviceSupported
        self.saveRestoreSupported = saveRestoreSupported
        self.entitlementNote = entitlementNote
        self.suspendFeatureDefault = suspendFeatureDefault
    }
}

public enum VZCapabilityProbe {
    public static func probe() -> VZCapabilityReport {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var model = "unknown"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &buffer, &size, nil, 0)
            model = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        return VZCapabilityReport(
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            hardwareModel: model,
            virtualizationSupported: VZVirtualMachine.isSupported,
            virtioSocketSupported: true, // macOS 11+，构建基线已满足
            entropyDeviceSupported: true, // macOS 12+，构建基线已满足
            balloonDeviceSupported: true, // macOS 11+
            saveRestoreSupported: true, // macOS 14+，构建基线已满足；不代表 POC 已通过
            entitlementNote: "com.apple.security.virtualization 需在签名后真机验证（矩阵 §4 POC 1）",
            suspendFeatureDefault: false
        )
    }
}
