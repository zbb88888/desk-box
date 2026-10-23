import Foundation
import Virtualization
import DeskBoxCore

/// macOS VZ 垂直切片。
///
/// 重要边界：VZ 是 VM transport/设备 API，不是磁盘 COW、OCI runtime 或
/// guest attestation。COW、控制握手、工作区和 Broker 仍由上层实现。
/// 本首个切片只允许以显式只读 root disk 创建配置；未提供产品 COW 时拒绝
/// start，避免把基础盘误当作 sandbox 可写盘。
public final class VZRuntime: SandboxRuntime, @unchecked Sendable {
    public let platform: SandboxPlatform = .vz

    private final class Record {
        let request: SandboxCreateRequest
        let boot: BootContext
        let machine: VZVirtualMachine
        var lifecycle: LifecycleMachine
        var started = false
        var delegate: VZRuntimeDelegate?
        let cowLease: CowDiskManager.Lease

        init(request: SandboxCreateRequest, boot: BootContext, machine: VZVirtualMachine, cowLease: CowDiskManager.Lease) {
            self.request = request
            self.boot = boot
            self.machine = machine
            self.cowLease = cowLease
            self.lifecycle = LifecycleMachine(
                sandboxID: request.sandboxID,
                boot: boot,
                correlationID: request.correlationID
            )
        }
    }

    private let queue = DispatchQueue(label: "com.deskbox.vz-runtime", qos: .userInitiated)
    /// All records are accessed on `queue`; no blocking lock is used from async code.
    private var records: [SandboxID: Record] = [:]
    private let audit: AuditSink?
    private let cow: CowDiskManager

    public init(cowRoot: URL, audit: AuditSink? = nil) throws {
        self.cow = try CowDiskManager(root: cowRoot)
        self.audit = audit
    }

    public func create(_ request: SandboxCreateRequest) async throws -> SandboxHandle {
        try await onQueue { [weak self] in
            guard let self else {
                throw SandboxFailure(.lifecycleInvalidTransition, "VZ runtime 已释放")
            }
            guard VZVirtualMachine.isSupported else {
                throw SandboxFailure(.platformCapabilityUnavailable, "Virtualization.framework 不受当前 Mac 支持")
            }
            guard request.networking == .none else {
                throw SandboxFailure(.platformNetworkDeniedByDefault, "首个 macOS 切片只允许无网卡模式")
            }
            guard self.record(for: request.sandboxID) == nil else {
                throw SandboxFailure(.lifecycleInvalidTransition, "sandbox 已存在：\(request.sandboxID)")
            }

            _ = try GuestAssetValidator.validate(request.guestAssets)
            let cowLease = try self.cow.createClone(source: request.guestAssets.rootDiskURL, sandboxID: request.sandboxID)
            let configuration: VZVirtualMachineConfiguration
            do {
                configuration = try self.makeConfiguration(request, diskURL: cowLease.cloneURL)
            } catch {
                try? self.cow.removeClone(cowLease)
                throw error
            }
            let machine = VZVirtualMachine(configuration: configuration, queue: self.queue)
            let boot = BootContext(
                sandboxID: request.sandboxID,
                protocolMajor: ControlChannelProtocol.currentMajor,
                guestManifestDigest: request.guestAssets.manifestDigest
            )
            let record = Record(request: request, boot: boot, machine: machine, cowLease: cowLease)
            let sandboxID = request.sandboxID
            let delegate = VZRuntimeDelegate { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard let record = self.record(for: sandboxID), record.lifecycle.state != .stopped else { return }
                    let reason = error == nil ? ReasonCode.lifecycleUnexpectedExit : ReasonCode.platformCapabilityUnavailable
                    record.lifecycle.forceFail(reason: reason)
                    self.recordAudit(record, action: .channelEvent, decision: .error(reason, error?.localizedDescription ?? "guest 意外停止"))
                }
            }
            record.delegate = delegate
            machine.delegate = delegate
            self.records[request.sandboxID] = record
            self.recordAudit(record, action: .create, decision: .allow())
            return SandboxHandle(sandboxID: request.sandboxID, bootID: boot.bootID)
        }
    }

    public func start(_ handle: SandboxHandle) async throws -> BootContext {
        try await onQueue {
            let record = try self.require(handle)
            guard record.boot.bootID == handle.bootID else {
                throw SandboxFailure(.bootstrapProofMismatch, "boot identity 不匹配")
            }
            guard !record.started else { return record.boot }
            do {
                try await record.machine.start()
                record.started = true
                self.recordAudit(record, action: .start, decision: .allow())
                return record.boot
            } catch {
                record.lifecycle.forceFail(reason: .platformCapabilityUnavailable)
                let failure = SandboxFailure(.platformCapabilityUnavailable, "VZ VM 启动失败：\(error.localizedDescription)")
                self.recordAudit(record, action: .start, decision: .error(failure.reason, failure.message))
                throw failure
            }
        }
    }

    public func confirmRunning(_ handle: SandboxHandle, proof: BootstrapProof) async throws {
        try await onQueue {
            let record = try self.require(handle)
            guard record.boot.bootID == handle.bootID else {
                throw SandboxFailure(.bootstrapProofMismatch, "boot identity 不匹配")
            }
            guard record.started else {
                let failure = SandboxFailure(.lifecycleInvalidTransition, "VM 尚未由 start 标记为已启动，不能确认 Running")
                self.recordAudit(record, action: .confirmRunning, decision: .error(failure.reason, failure.message))
                throw failure
            }
            try record.lifecycle.transition(
                to: .running,
                reason: .lifecycleRunningConfirmed,
                proof: proof
            )
            self.recordAudit(record, action: .confirmRunning, decision: .allow())
        }
    }

    public func stop(_ handle: SandboxHandle) async throws {
        try await onQueue {
            let record = try self.require(handle)
            guard record.machine.canStop else {
                try? record.lifecycle.transition(to: .stopped, reason: .lifecycleStopped)
                return
            }
            if record.lifecycle.state != .stopping && record.lifecycle.state != .stopped {
                try record.lifecycle.transition(to: .stopping, reason: .lifecycleStopRequested)
            }
            try await record.machine.stop()
            if record.lifecycle.state != .stopped {
                try record.lifecycle.transition(to: .stopped, reason: .lifecycleStopped)
            }
            record.started = false
            self.recordAudit(record, action: .stop, decision: .allow())
        }
    }

    public func suspend(_ handle: SandboxHandle) async throws {
        _ = try await inspect(handle)
        throw SandboxFailure(.platformSuspendDisabled, "suspend/resume 尚未完成真实平台 POC，首版关闭")
    }

    public func resume(_ handle: SandboxHandle) async throws -> BootContext {
        _ = try await inspect(handle)
        throw SandboxFailure(.platformSuspendDisabled, "suspend/resume 尚未完成真实平台 POC，首版关闭")
    }

    public func destroy(_ handle: SandboxHandle) async throws {
        try await onQueue {
            let record = try self.require(handle)
            if record.lifecycle.state != .stopped {
                if record.lifecycle.state != .stopping {
                    try record.lifecycle.transition(to: .stopping, reason: .lifecycleStopRequested)
                }
                if record.machine.canStop { try await record.machine.stop() }
                if record.lifecycle.state != .stopped {
                    try record.lifecycle.transition(to: .stopped, reason: .lifecycleStopped)
                }
            }
            do {
                try self.cow.removeClone(record.cowLease)
            } catch {
                record.lifecycle.forceFail(reason: .platformCowCleanupFailed)
                self.recordAudit(record, action: .destroy, decision: .error(.platformCowCleanupFailed, error.localizedDescription))
                throw error
            }
            self.recordAudit(record, action: .destroy, decision: .allow())
            self.records.removeValue(forKey: handle.sandboxID)
        }
    }

    public func inspect(_ handle: SandboxHandle) async throws -> SandboxStatus {
        try await onQueue {
            let record = try self.require(handle)
            return SandboxStatus(
                sandboxID: record.request.sandboxID,
                bootID: record.boot.bootID,
                platform: .vz,
                state: record.lifecycle.state,
                correlationID: record.request.correlationID,
                history: record.lifecycle.history,
                endpoints: [EndpointDescriptor(
                    name: "control",
                    transport: .vsock(port: record.request.controlChannelPort)
                )]
            )
        }
    }

    public func resolveEndpoint(_ handle: SandboxHandle, name: String) async throws -> EndpointDescriptor? {
        let status = try await inspect(handle)
        return status.endpoints.first { $0.name == name }
    }

    // MARK: - Configuration

    private func makeConfiguration(_ request: SandboxCreateRequest, diskURL: URL) throws -> VZVirtualMachineConfiguration {
        let assets = request.guestAssets
        let bootLoader = VZLinuxBootLoader(kernelURL: assets.kernelURL)
        bootLoader.initialRamdiskURL = assets.initrdURL
        bootLoader.commandLine = assets.kernelCommandLine

        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = bootLoader
        configuration.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, min(request.resources.cpuCount ?? 2, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        configuration.memorySize = UInt64(max(Int(VZVirtualMachineConfiguration.minimumAllowedMemorySize), request.resources.memoryMiB ?? 2048) * 1024 * 1024)
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // 管理通道设备存在，但没有普通网络设备；网络默认拒绝。
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        let attachment = try VZDiskImageStorageDeviceAttachment(
            url: diskURL,
            readOnly: false
        )
        let block = VZVirtioBlockDeviceConfiguration(attachment: attachment)
        configuration.storageDevices = [block]

        try configuration.validate()
        return configuration
    }

    private func record(for sandboxID: SandboxID) -> Record? {
        records[sandboxID]
    }

    private func recordAudit(_ record: Record, action: AuditAction, decision: Decision) {
        audit?.record(AuditEvent(
            platform: .vz,
            sandboxID: record.request.sandboxID,
            bootID: record.boot.bootID,
            workloadDigest: record.request.workloadDigest,
            action: action,
            decision: decision,
            correlationID: record.request.correlationID
        ))
    }

    private func require(_ handle: SandboxHandle) throws -> Record {
        guard let record = record(for: handle.sandboxID) else {
            throw SandboxFailure(.lifecycleInvalidTransition, "sandbox 不存在：\(handle.sandboxID)")
        }
        guard record.boot.bootID == handle.bootID else {
            throw SandboxFailure(.bootstrapProofMismatch, "handle 不属于当前 boot")
        }
        return record
    }

    private func onQueue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                Task {
                    do { continuation.resume(returning: try await operation()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
    }
}
