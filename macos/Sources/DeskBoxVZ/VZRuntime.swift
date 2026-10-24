import Foundation
@preconcurrency import Virtualization
import DeskBoxCore

/// macOS VZ 垂直切片。
///
/// 重要边界：VZ 是 VM transport/设备 API，不是磁盘 COW、OCI runtime 或
/// guest attestation。COW、控制握手、工作区和 Broker 仍由上层实现。
/// 本首个切片只允许以显式只读 root disk 创建配置；未提供产品 COW 时拒绝
/// start，避免把基础盘误当作 sandbox 可写盘。
public final class VZRuntime: SandboxRuntime, @unchecked Sendable {
    public let platform: SandboxPlatform = .vz

    private final class Record: @unchecked Sendable {
        let request: SandboxCreateRequest
        let boot: BootContext
        let machine: VZVirtualMachine
        var lifecycle: LifecycleMachine
        var started = false
        var delegate: VZRuntimeDelegate?
        var socketDelegate: VZControlSocketDelegate?
        var controlSocket: VZControlSocket?
        var bootstrapState: BootstrapState = .notConnected
        let serialConsole: VZSerialConsole?
        let cowLease: CowDiskManager.Lease

        init(request: SandboxCreateRequest, boot: BootContext, machine: VZVirtualMachine, cowLease: CowDiskManager.Lease, serialConsole: VZSerialConsole?) {
            self.request = request
            self.boot = boot
            self.machine = machine
            self.cowLease = cowLease
            self.serialConsole = serialConsole
            self.lifecycle = LifecycleMachine(
                sandboxID: request.sandboxID,
                boot: boot,
                correlationID: request.correlationID
            )
        }
    }

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    /// All records are accessed on `queue`; no blocking lock is used from async code.
    private var records: [SandboxID: Record] = [:]
    private let audit: AuditSink?
    private let cow: CowDiskManager
    private let enableConsole: Bool
    private let enableControlSocket: Bool

    public init(
        cowRoot: URL,
        audit: AuditSink? = nil,
        enableConsole: Bool = true,
        enableControlSocket: Bool = true
    ) throws {
        self.queue = DispatchQueue(label: "com.deskbox.vz-runtime", qos: .userInitiated)
        self.queue.setSpecific(key: queueKey, value: 1)
        self.cow = try CowDiskManager(root: cowRoot)
        self.audit = audit
        self.enableConsole = enableConsole
        self.enableControlSocket = enableControlSocket
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
            let boot = BootContext(
                sandboxID: request.sandboxID,
                protocolMajor: ControlChannelProtocol.currentMajor,
                guestManifestDigest: request.guestAssets.manifestDigest
            )
            let configuration: VZVirtualMachineConfiguration
            let serialConsole: VZSerialConsole?
            do {
                let result = try self.makeConfiguration(request, diskURL: cowLease.cloneURL, boot: boot)
                configuration = result.configuration
                serialConsole = result.console
            } catch {
                try? self.cow.removeClone(cowLease)
                throw error
            }
            let machine = VZVirtualMachine(configuration: configuration, queue: self.queue)
            let record = Record(request: request, boot: boot, machine: machine, cowLease: cowLease, serialConsole: serialConsole)
            let sandboxID = request.sandboxID
            let delegate = VZRuntimeDelegate(
                onGuestStopped: { [weak self] error in
                    guard let self else { return }
                    self.queue.async {
                    guard let record = self.record(for: sandboxID), record.lifecycle.state != .stopped else { return }
                    let reason = error == nil ? ReasonCode.lifecycleUnexpectedExit : ReasonCode.platformCapabilityUnavailable
                    record.lifecycle.forceFail(reason: reason)
                        self.recordAudit(record, action: .channelEvent, decision: .error(reason, error?.localizedDescription ?? "guest 意外停止"))
                    }
                },
                onState: { [weak self] state in
                    guard let self else { return }
                    self.queue.async {
                        guard let record = self.record(for: sandboxID) else { return }
                        self.recordAudit(record, action: .channelEvent, decision: .error(.lifecycleUnexpectedExit, "VZ state=\(state.rawValue)"))
                    }
                }
            )
            record.delegate = delegate
            machine.delegate = delegate
            if self.enableControlSocket {
                do {
                    try self.installControlListener(record)
                } catch {
                    try? self.cow.removeClone(cowLease)
                    throw error
                }
            }
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
            if record.started { return record.boot }
            do {
                try await self.startMachine(record.machine)
                record.started = true
                self.recordAudit(record, action: .start, decision: .allow())
                return record.boot
            } catch {
                record.lifecycle.forceFail(reason: .platformCapabilityUnavailable)
                let failure = SandboxFailure(
                    .platformCapabilityUnavailable,
                    "VZ VM 启动失败：\(error.localizedDescription)"
                )
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
            guard self.machineCanStop(record.machine) else {
                try? record.lifecycle.transition(to: .stopped, reason: .lifecycleStopped)
                return
            }
            if record.lifecycle.state != .stopping && record.lifecycle.state != .stopped {
                try record.lifecycle.transition(to: .stopping, reason: .lifecycleStopRequested)
            }
            try await self.stopMachine(record.machine)
            if record.lifecycle.state != .stopped {
                try record.lifecycle.transition(to: .stopped, reason: .lifecycleStopped)
            }
            record.started = false
            record.controlSocket?.close()
            record.controlSocket = nil
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
                if self.machineCanStop(record.machine) { try await self.stopMachine(record.machine) }
                record.controlSocket?.close()
                record.controlSocket = nil
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
                )],
                bootstrap: record.bootstrapState
            )
        }
    }

    public func resolveEndpoint(_ handle: SandboxHandle, name: String) async throws -> EndpointDescriptor? {
        let status = try await inspect(handle)
        return status.endpoints.first { $0.name == name }
    }

    /// Diagnostic-only serial input. It is intentionally not part of the
    /// trusted control plane and must never be used for authorization.
    public func sendConsoleInput(_ handle: SandboxHandle, data: Data) async throws {
        try await onQueue {
            let record = try self.require(handle)
            guard record.started, let console = record.serialConsole else {
                throw SandboxFailure(.platformCapabilityUnavailable, "guest serial console 不可用")
            }
            try console.hostWriteHandle.write(contentsOf: data)
        }
    }

    // MARK: - Configuration

    private func makeConfiguration(_ request: SandboxCreateRequest, diskURL: URL, boot: BootContext) throws -> (configuration: VZVirtualMachineConfiguration, console: VZSerialConsole?) {
        let assets = request.guestAssets
        let bootLoader = VZLinuxBootLoader(kernelURL: assets.kernelURL)
        bootLoader.initialRamdiskURL = assets.initrdURL
        // These values are guest-visible bootstrap inputs, not attestation.
        // The host still validates the hello against its in-memory BootContext.
        bootLoader.commandLine = assets.kernelCommandLine + " init=/init rdinit=/init console=hvc0 earlycon=hvc0 loglevel=7 panic=10 dbx.sandbox=\(boot.sandboxID.raw) dbx.boot=\(boot.bootID.raw) dbx.nonce=\(boot.bootNonce.uuidString) dbx.manifest=\(boot.guestManifestDigest) dbx.port=1024"

        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = bootLoader
        let requestedCPUs = request.resources.cpuCount ?? 2
        configuration.cpuCount = max(
            VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            min(requestedCPUs, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        )
        let requestedMemory = UInt64(max(request.resources.memoryMiB ?? 2048, 1)) * 1024 * 1024
        let minimumMemory = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let maximumMemory = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        configuration.memorySize = min(max(requestedMemory, minimumMemory), maximumMemory)
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Guest `console=hvc0` 输出只用于诊断，不用于 readiness/attestation。
        let console: VZSerialConsole?
        if enableConsole {
            let serialConsole = VZSerialConsole { data in
                FileHandle.standardError.write(data)
                fflush(stderr)
            }
            let serial = VZVirtioConsoleDeviceConfiguration()
            let consolePort = VZVirtioConsolePortConfiguration()
            // The primary VZ virtio console port is exposed as hvc0. A named
            // non-console port would not receive Linux kernel console output.
            consolePort.name = nil
            consolePort.isConsole = true
            consolePort.attachment = serialConsole.attachment
            serial.ports[0] = consolePort
            configuration.consoleDevices = [serial]
            console = serialConsole
        } else {
            console = nil
        }

        // 管理通道设备存在，但没有普通网络设备；网络默认拒绝。
        if enableControlSocket {
            configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        }

        let attachment = try VZDiskImageStorageDeviceAttachment(
            url: diskURL,
            readOnly: false
        )
        let block = VZVirtioBlockDeviceConfiguration(attachment: attachment)
        configuration.storageDevices = [block]

        try configuration.validate()
        return (configuration, console)
    }

    private func machineCanStop(_ machine: VZVirtualMachine) -> Bool {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return machine.canStop
        }
        return queue.sync { machine.canStop }
    }

    private func startMachine(_ machine: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                machine.start { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func stopMachine(_ machine: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                machine.stop { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: ()) }
                }
            }
        }
    }

    private func installControlListener(_ record: Record) throws {
        guard let socketDevice = record.machine.socketDevices.first as? VZVirtioSocketDevice else {
            throw SandboxFailure(.platformCapabilityUnavailable, "VZ virtio socket device 未创建")
        }
        let delegate = VZControlSocketDelegate(
            onConnection: { [weak self, weak record] connection in
                guard let self, let record else { connection.close(); return }
                let boxedConnection = UnsafeSendableBox(value: connection)
                self.queue.async { [weak self, weak record] in
                    guard let self, let record else {
                        boxedConnection.value.close()
                        return
                    }
                    let socket = VZControlSocket(
                        connection: boxedConnection.value,
                        queue: self.queue,
                        onFrames: { [weak self, weak record] frames in
                            guard let self, let record else { return }
                            self.queue.async { [weak self, weak record] in
                                guard let self, let record else { return }
                                for frame in frames {
                                    self.handleControlFrame(frame, record: record)
                                }
                            }
                        },
                        onFailure: { [weak self, weak record] message in
                            guard let self, let record else { return }
                            self.queue.async { [weak self, weak record] in
                                guard let self, let record else { return }
                                self.recordAudit(record, action: .channelEvent, decision: .error(.bootstrapProofMismatch, message))
                            }
                        }
                    )
                    record.controlSocket?.close()
                    record.controlSocket = socket
                }
            },
            onReject: { [weak self, weak record] message in
                guard let self, let record else { return }
                self.recordAudit(record, action: .channelEvent, decision: .deny(.bootstrapProofMismatch, message))
            }
        )
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        // VZ device mutations must execute on the queue passed to
        // VZVirtualMachine. `Task` resumption is not guaranteed to remain on
        // that DispatchQueue, so explicitly hop for the API call.
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            socketDevice.setSocketListener(listener, forPort: record.request.controlChannelPort)
        } else {
            queue.sync {
                socketDevice.setSocketListener(listener, forPort: record.request.controlChannelPort)
            }
        }
        record.socketDelegate = delegate
    }

    private func handleControlFrame(_ frame: ControlFrame, record: Record) {
        guard frame.kind == .hello else {
            recordAudit(record, action: .channelEvent, decision: .deny(.bootstrapProofMissing, "TLS/bootstrap 完成前只接受 hello"))
            return
        }
        do {
            let hello = try BootstrapCodec.decodeHello(frame.payload)
            let decision = hello.bindingDecision(against: record.boot)
            guard decision.isAllowed else {
                recordAudit(record, action: .channelEvent, decision: decision)
                record.controlSocket?.close()
                return
            }
            record.bootstrapState = .helloAcceptedTLSRequired
            let ack = BootstrapHelloAck(sessionID: .new(), requiresTLS: true)
            let payload = try BootstrapCodec.encodeAck(ack)
            let response = try ControlFrame(kind: .helloAck, sequence: frame.sequence + 1, requestID: frame.requestID, payload: payload)
            try record.controlSocket?.send(response)
            recordAudit(record, action: .channelEvent, decision: .error(.bootstrapTLSRequired, "hello 绑定成功；仍需 TLS 1.3 双向认证后才能建立 session"))
        } catch {
            recordAudit(record, action: .channelEvent, decision: .error(.bootstrapProofMismatch, error.localizedDescription))
            record.controlSocket?.close()
        }
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
