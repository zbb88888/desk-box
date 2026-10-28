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
        /// M20：resume 需要从同一 configuration 重建 machine（VZ 要求 stopped 才能 restore）。
        var machine: VZVirtualMachine
        let configuration: VZVirtualMachineConfiguration
        var lifecycle: LifecycleMachine
        var started = false
        var delegate: VZRuntimeDelegate?
        var socketDelegate: VZControlSocketDelegate?
        var controlSocket: VZControlSocket?
        var secureSession: SecureRecordSession?
        var lastExecResponse: ControlFrame?
        var lastDecodedExecResponse: ControlResponse?
        var pendingExecRequestID: UUID?
        var lastStatsFrame: ControlFrame?
        var lastDecodedStats: SandboxStats?
        var pendingStatsRequestID: UUID?
        var pendingPtyOpenID: UUID?
        var ptyEvents: [PtyEvent] = []
        var wsAcks: [WsAckEvent] = []
        /// M23（INV-02）：该沙箱所属凭据域 + 本 VM 实例的唯一 ID（调度证据）。
        let domain: CredentialDomain
        let vmInstanceID: String
        var bootstrapState: BootstrapState = .notConnected
        /// M20：最近一次被接受的 bootstrap proof（resume 复用同一 boot 的 proof）。
        var lastAcceptedProof: BootstrapProof?
        var requestSequence: UInt64 = 1

        init(request: SandboxCreateRequest, boot: BootContext, machine: VZVirtualMachine,
             configuration: VZVirtualMachineConfiguration, cowLease: CowDiskManager.Lease,
             serialConsole: VZSerialConsole?, domain: CredentialDomain) {
            self.request = request
            self.boot = boot
            self.machine = machine
            self.configuration = configuration
            self.cowLease = cowLease
            self.serialConsole = serialConsole
            self.domain = domain
            self.vmInstanceID = UUID().uuidString
            self.lifecycle = LifecycleMachine(
                sandboxID: request.sandboxID,
                boot: boot,
                correlationID: request.correlationID
            )
        }

        func nextRequestSequence() -> UInt64 {
            let value = requestSequence
            requestSequence += 1
            return value
        }
        let serialConsole: VZSerialConsole?
        let cowLease: CowDiskManager.Lease


    }

    /// M23（INV-02）：凭据域注册表。缺省为内置单域 `default`（与 M23 之前行为一致），
    /// 但显式传入了别的域而注册表里没有它时必须拒绝。
    public var domainRegistry: DomainRegistry
    /// 调度决策记录（追加写，0600）：域 + VM 实例 + 内核摘要，作为 INV-02 证据。
    public let schedulerDecisionLogURL: URL

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    /// All records are accessed on `queue`; no blocking lock is used from async code.
    private var records: [SandboxID: Record] = [:]
    private let audit: AuditSink?
    private let cow: CowDiskManager
    /// M20：快照信封（加密 + 三道闸）。
    private let snapshots: SnapshotStore
    /// M20：release key 链（用于撤销检查）；nil 时跳过该闸（本地 dev）。
    public var releaseKeys: ReleaseKeysManifest?
    /// M20：快照目录（与 COW 同根）。
    private let snapshotRoot: URL
    private let registry: SandboxRegistry
    private let enableConsole: Bool
    /// M16：console tail 支持（daemon consoleLog）。对 GUI 由由URLSession tái.
    private var lastConsole: VZSerialConsole?

    /// 返回 guest serial console 的头部字节（diagnostic only, 不构成 readiness）。
    public func consoleTail(maxBytes: Int) -> Data {
        lastConsole?.tail(maxBytes: maxBytes) ?? Data()
    }
    private let enableControlSocket: Bool
    private let securityPolicy: ControlSecurityPolicy
    private let allowUnsignedManifest: Bool
    /// M2-3b：在线 broker 凭据/策略根目录（内含 broker-policy.json 与 broker-credentials.local，gitignored）。
    public var brokerConfigDir: URL?
    /// M14：启用 virtio-gpu 设备（guest 必须内置 virtio_gpu 驱动才会出现 framebuffer）。
    public var enableGraphics: Bool = false

    public init(
        cowRoot: URL,
        audit: AuditSink? = nil,
        enableConsole: Bool = true,
        enableControlSocket: Bool = true,
        securityPolicy: ControlSecurityPolicy = .strict,
        allowUnsignedManifest: Bool = false
    ) throws {
        self.queue = DispatchQueue(label: "com.deskbox.vz-runtime", qos: .userInitiated)
        self.queue.setSpecific(key: queueKey, value: 1)
        self.cow = try CowDiskManager(root: cowRoot)
        self.snapshotRoot = cowRoot.appendingPathComponent("snapshots", isDirectory: true)
        // 快照密钥固定在 Application Support，随宿主用户生命周期；不放进 COW 根（否则 rm 会连密钥一起删）。
        self.snapshots = SnapshotStore(keyURL: SnapshotStore.defaultKeyURL())
        self.registry = try SandboxRegistry(root: cowRoot)
        self.audit = audit
        self.enableConsole = enableConsole
        self.enableControlSocket = enableControlSocket
        self.securityPolicy = securityPolicy
        self.allowUnsignedManifest = allowUnsignedManifest
        self.brokerConfigDir = nil
        self.domainRegistry = DomainRegistry(
            manifest: .singleDefault,
            credentialRoot: cowRoot.deletingLastPathComponent()
        )
        self.schedulerDecisionLogURL = cowRoot.deletingLastPathComponent()
            .appendingPathComponent("scheduler-decisions.jsonl")
    }

    /// M23：把域注册表挂上（daemon 启动时按 `domains.json` 配置）。
    public func configureDomains(_ registry: DomainRegistry) {
        self.domainRegistry = registry
    }

    /// M23：解析并**校验**凭据域。未知域/非法 ID 一律拒绝（无「默认域」兜底）。
    public func resolveDomain(_ requested: CredentialDomainID) throws -> CredentialDomain {
        do {
            return try domainRegistry.resolve(requested)
        } catch let error as DomainResolutionError {
            throw SandboxFailure(.lifecycleInvalidTransition, "\(error.reasonCode): \(error)")
        }
    }

    /// M23：写一条调度决策记录。失败不阻断主流程（审计是旁路），但会打日志。
    private func recordSchedulerDecision(_ record: Record,
                                        decision: String,
                                        reason: String?) {
        let entry: [String: Any] = [
            "schema": "deskbox-scheduler-decision/v1",
            "at": ISO8601DateFormatter().string(from: Date()),
            "sandboxID": record.request.sandboxID.raw,
            "bootID": record.boot.bootID.raw,
            "vmInstanceID": record.vmInstanceID,
            "domainID": record.domain.domainID.raw,
            "manifestDigest": record.request.guestAssets.manifestDigest,
            "kernelPath": record.request.guestAssets.kernelURL.lastPathComponent,
            "cowClone": record.cowLease.cloneURL.lastPathComponent,
            "cowDomain": record.cowLease.domainID.raw,
            "hostPID": Int(ProcessInfo.processInfo.processIdentifier),
            "decision": decision,
            "reason": reason as Any? ?? NSNull()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = schedulerDecisionLogURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// Recover orphan resources left by SIGKILL/host crash before accepting
    /// new work. Fail-closed: a malformed registry stops startup.
    public func sweepOrphans() throws -> RegistrySweepReport {
        let report: RegistrySweepReport
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            report = try registry.sweep()
        } else {
            report = try queue.sync { try registry.sweep() }
        }
        // M20：崩溃后快照文件同样是孤儿资源，必须一并清理（否则磁盘上会留下
        // 可被 restore 的旧 VM 状态——正是 INV-10 要阻断的「复活」路径）。
        self.removeOrphanSnapshots(keeping: try registry.liveSandboxIDs())
        return report
    }

    /// 删除没有活跃注册项的沙箱快照。`keeping` 之外的 *.snap/*.vzstate 一律清除。
    private func removeOrphanSnapshots(keeping: Set<String>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: snapshotRoot, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries {
            let name = entry.lastPathComponent
            let sandboxID: String
            if name.hasSuffix(".snap") {
                sandboxID = String(name.dropLast(5))
            } else if name.hasPrefix("tmp-") || name.hasPrefix("tmp-restore-") {
                sandboxID = ""   // 崩溃残留的临时 VZ 状态文件：无条件删除
            } else {
                continue
            }
            if !sandboxID.isEmpty && keeping.contains(sandboxID) { continue }
            try? fm.removeItem(at: entry)
        }
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

            _ = try GuestAssetValidator.validate(request.guestAssets,
                                                 allowUnsignedManifest: self.allowUnsignedManifest)
            // M23（INV-02）：域必须是已声明域；未声明不得回退成「默认域」。
            let domain = try self.resolveDomain(request.domainID)
            let cowLease = try self.cow.createClone(source: request.guestAssets.rootDiskURL,
                                                    sandboxID: request.sandboxID,
                                                    domainID: domain.domainID)
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
            let record = Record(request: request, boot: boot, machine: machine,
                                configuration: configuration, cowLease: cowLease, serialConsole: serialConsole,
                                domain: domain)
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
            self.records[request.sandboxID] = record
            try self.registry.upsert(RegisteredSandbox(
                sandboxID: request.sandboxID,
                bootID: boot.bootID,
                status: .created,
                clonePath: cowLease.cloneURL.standardizedFileURL.path,
                hostPID: ProcessInfo.processInfo.processIdentifier,
                domainID: domain.domainID
            ))
            // 调度决策记录：这是 INV-02「不同域不共享 guest kernel」的可审计证据。
            self.recordSchedulerDecision(record, decision: "allow", reason: nil)
            if self.enableControlSocket {
                do {
                    try self.installControlListener(record)
                } catch {
                    self.records.removeValue(forKey: request.sandboxID)
                    try? self.cow.removeClone(cowLease)
                    throw error
                }
            }
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
                fputs("[vz-start] sandbox=\(record.request.sandboxID.description) machine.state=\(record.machine.state.rawValue)\n", stderr)
                fflush(stderr)
                try self.registry.upsert(RegisteredSandbox(
                    sandboxID: record.request.sandboxID,
                    bootID: record.boot.bootID,
                    status: .running,
                    clonePath: record.cowLease.cloneURL.standardizedFileURL.path,
                    hostPID: ProcessInfo.processInfo.processIdentifier,
                    domainID: record.domain.domainID
                ))
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
            self.closeSocketOnQueue(record)
            record.controlSocket = nil
            try self.registry.upsert(RegisteredSandbox(
                sandboxID: record.request.sandboxID,
                bootID: record.boot.bootID,
                status: .stopped,
                clonePath: record.cowLease.cloneURL.standardizedFileURL.path,
                hostPID: ProcessInfo.processInfo.processIdentifier,
                domainID: record.domain.domainID
            ))
            self.recordAudit(record, action: .stop, decision: .allow())
        }
    }

    /// M20：暂停并把 VZ 状态加密落盘（INV-10）。COW 盘保留，供 resume 使用。
    public func suspend(_ handle: SandboxHandle) async throws {
        let snapshotURL = snapshotURL(for: handle.sandboxID)
        try await onQueue {
            let record = try self.require(handle)
            guard record.lifecycle.state == .running else {
                throw SandboxFailure(.lifecycleInvalidTransition,
                                     "suspend 仅允许 running 状态，当前 \(record.lifecycle.state)")
            }
            try record.lifecycle.transition(to: .suspending, reason: .lifecycleStopRequested)
            try self.registry.upsert(RegisteredSandbox(
                sandboxID: record.request.sandboxID, bootID: record.boot.bootID,
                status: .stopped, clonePath: record.cowLease.cloneURL.standardizedFileURL.path,
                hostPID: ProcessInfo.processInfo.processIdentifier,
                domainID: record.domain.domainID))
        }

        // VZ save/restore 只支持 arm64 + macOS 14+，且必须先把机器暂停。
        let machine = try await onQueue { try self.require(handle).machine }
        try await self.vzOperation { completion in
            machine.pause { result in
                switch result {
                case .success: completion(nil)
                case .failure(let error): completion(error)
                }
            }
        }

        let tempURL = snapshotURL.deletingLastPathComponent()
            .appendingPathComponent("tmp-\(UUID().uuidString).vzstate")
        try? FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try await self.vzOperation { completion in
            machine.saveMachineStateTo(url: tempURL) { error in completion(error) }
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let payload = try Data(contentsOf: tempURL)
        let metadata = try await onQueue { () -> SnapshotMetadata in
            let record = try self.require(handle)
            return SnapshotMetadata(
                sandboxID: record.request.sandboxID.description,
                bootID: record.boot.bootID.raw,
                manifestDigest: record.request.guestAssets.manifestDigest,
                guestAssetVersion: record.request.guestAssets.guestAssetVersion,
                keyID: record.request.guestAssets.signature?.keyID ?? "unsigned",
                createdAtUtc: ISO8601DateFormatter().string(from: Date()),
                hostBuild: ProcessInfo.processInfo.operatingSystemVersionString,
                payloadSha256: "",
                domainID: record.domain.domainID.raw)
        }
        try self.snapshots.seal(payload: payload, metadata: metadata, to: snapshotURL)

        try await onQueue {
            let record = try self.require(handle)
            // 不关闭 control socket：guest 被冻结后同一 vsock 会话在 resume 时继续有效，
            // 因此不需要（guest 也不会）重新发 hello。proof 复用同一 boot。
            record.started = false
            if record.lifecycle.state != .suspended {
                try record.lifecycle.transition(to: .suspended, reason: .lifecycleStopped)
            }
            self.recordAudit(record, action: .channelEvent, decision: .allow())
            try self.registry.upsert(RegisteredSandbox(
                sandboxID: record.request.sandboxID, bootID: record.boot.bootID,
                status: .stopped, clonePath: record.cowLease.cloneURL.standardizedFileURL.path,
                hostPID: ProcessInfo.processInfo.processIdentifier,
                domainID: record.domain.domainID))
        }
    }

    /// M20：从快照恢复。三道闸（manifestDigest / assetVersion / key 撤销）先过，再交给 VZ。
    ///
    /// 状态机纪律：任何失败都必须让沙箱保持在 `.suspended`（可重试/可 rm），
    /// 只有在 VZ 真正恢复成功之后才进入 `.resuming`。
    public func resume(_ handle: SandboxHandle) async throws -> BootContext {
        let snapshotURL = snapshotURL(for: handle.sandboxID)

        // 1) 闸门（不改变任何状态）。
        let metadata = try self.snapshots.readMetadata(at: snapshotURL)
        let (configuration, assets, bootID, domain) = try await onQueue {
            () -> (VZVirtualMachineConfiguration, GuestAssetManifest, BootID, CredentialDomainID) in
            let record = try self.require(handle)
            guard record.lifecycle.state == .suspended else {
                throw SandboxFailure(.lifecycleInvalidTransition,
                                     "resume 仅允许 suspended 状态，当前 \(record.lifecycle.state)")
            }
            return (record.configuration, record.request.guestAssets, record.boot.bootID,
                    record.domain.domainID)
        }
        let gate = SnapshotGate(
            manifestDigest: assets.manifestDigest,
            guestAssetVersion: assets.guestAssetVersion,
            minimumAssetVersionFloor: assets.guestAssetVersion,
            releaseKeys: self.releaseKeys,
            domainID: domain
        )
        do {
            try gate.check(metadata)
            guard metadata.bootID == bootID.raw else {
                throw SnapshotError.malformed("bootID 与当前沙箱不符")
            }
        } catch {
            try await onQueue {
                let record = try self.require(handle)
                self.recordAudit(record, action: .channelEvent,
                                 decision: .deny(.bootstrapProofMismatch, "snapshot gate: \(error)"))
            }
            throw error
        }

        // 2) 解密 + VZ 恢复（这一步失败也只回到 suspended）。
        let payload = try self.snapshots.open(at: snapshotURL)
        let tempURL = snapshotURL.deletingLastPathComponent()
            .appendingPathComponent("tmp-restore-\(UUID().uuidString).vzstate")
        try payload.write(to: tempURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // VZ 要求 restore 目标 machine 处于 stopped：从同一 configuration 重建一台。
        let machine = try await onQueue { () -> VZVirtualMachine in
            let record = try self.require(handle)
            let rebuilt = VZVirtualMachine(configuration: configuration, queue: self.queue)
            rebuilt.delegate = record.delegate
            record.machine = rebuilt
            return rebuilt
        }
        try await self.vzOperation { completion in
            machine.restoreMachineStateFrom(url: tempURL) { error in completion(error) }
        }
        // 恢复后机器处于 paused，需要显式 resume。
        try await self.vzOperation { completion in
            machine.resume { result in
                switch result {
                case .success: completion(nil)
                case .failure(let error): completion(error)
                }
            }
        }

        // 3) VZ 成功后才推进状态机，并等待 guest 重连后的新握手。
        try? FileManager.default.removeItem(at: snapshotURL)
        return try await onQueue {
            let record = try self.require(handle)
            if record.lifecycle.state == .suspended {
                try record.lifecycle.transition(to: .resuming, reason: .lifecycleResuming)
            }
            record.started = true
            // VZ restore 会重置 vsock 连接：丢弃旧会话状态、重装监听，
            // 由 guest 重连发来的新 hello 完成 resuming -> running（带新 proof）。
            self.closeSocketOnQueue(record)
            record.controlSocket = nil
            record.secureSession = nil
            record.bootstrapState = .notConnected
            record.lastAcceptedProof = nil
            if self.enableControlSocket {
                try self.installControlListener(record)
            }
            self.recordAudit(record, action: .channelEvent, decision: .allow())
            return record.boot
        }
    }

    /// 同步读取生命周期状态（供 daemon `ps` 使用；不经 async 队列）。
    public func cachedLifecycleState(of handle: SandboxHandle) -> String? {
        queue.sync {
            guard let record = records[handle.sandboxID] else { return nil }
            return record.lifecycle.state.rawValue
        }
    }

    /// M20：VZ 的 pause/save/restore/resume 内部有 `dispatch_assert_queue`，
    /// 必须在 VM 自己的 queue 上调用，否则直接 SIGTRAP。这里统一桥接。
    private func vzOperation(_ body: @escaping (@escaping (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.queue.async {
                body { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
    }

    /// 快照路径：与 COW 同根，便于 sweep 一起清扫。
    private func snapshotURL(for sandboxID: SandboxID) -> URL {
        self.snapshotRoot.appendingPathComponent("\(sandboxID.description).snap")
    }

    public func destroy(_ handle: SandboxHandle) async throws {
        try await onQueue {
            let record = try self.require(handle)
            if record.lifecycle.state != .stopped {
                if record.lifecycle.state != .stopping {
                    try record.lifecycle.transition(to: .stopping, reason: .lifecycleStopRequested)
                }
                if self.machineCanStop(record.machine) { try await self.stopMachine(record.machine) }
                self.closeSocketOnQueue(record)
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
            try self.registry.markDestroyed(sandboxID: handle.sandboxID)
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

    public func execute(_ handle: SandboxHandle, request: ControlRequest) async throws -> ControlResponse {
        // M2-2: 允许 echo/sh 诊断与 /workspace 下经策略同步的可执行面。
        guard let first = request.argv.first else {
            throw SandboxFailure(.bootstrapProofMissing, "exec argv 不可为空")
        }
        // M18：/bin/hardening-probe 是随签名 rootfs 一起下发的固定自检二进制
        // （只执行预置的测例，不接受任意代码），用于验证内核级加固是否生效。
        let allowedFirst = first == "/bin/echo"
            || first == "/bin/sh"
            || first == "/bin/hardening-probe"
            || first.hasPrefix("/workspace/")
        let cwdOK = (request.cwd == nil)
            || request.cwd == "/workspace"
            || (request.cwd?.hasPrefix("/workspace/") ?? false)
        guard allowedFirst && cwdOK else {
            throw SandboxFailure(.bootstrapProofMissing, "MVP exec only accepts echo/sh or workspace-scoped argv")
        }
        try await onQueue {
            let record = try self.require(handle)
            guard record.bootstrapState == .authenticated || record.bootstrapState == .tlsAuthenticated else {
                throw SandboxFailure(.bootstrapProofMissing, "authenticated control session required before exec")
            }
            if self.securityPolicy.requiresTLSUpgrade && record.bootstrapState != .tlsAuthenticated {
                throw SandboxFailure(.bootstrapTLSRequired, "M1-2: exec requires an established TLS 1.3 session")
            }
        }
        try await onQueue {
            let record = try self.require(handle)
            guard record.lifecycle.state == .running,
                  record.controlSocket != nil else {
                throw SandboxFailure(.bootstrapProofMissing, "authenticated control session required before exec")
            }
            let payload = try JSONEncoder().encode(request)
            let requestID = UUID()
            let frame = try ControlFrame(kind: .request, sequence: record.nextRequestSequence(), requestID: requestID, payload: payload)
            record.pendingExecRequestID = requestID
            // Drop the previous response so a new request can never read stale output.
            record.lastDecodedExecResponse = nil
            record.lastExecResponse = nil
            do {
                try self.sendFrameOnQueue(record, frame: frame)
                self.recordAudit(record, action: .channelEvent, decision: .allow())
            } catch {
                record.lifecycle.forceFail(reason: .bootstrapProofMismatch)
                self.recordAudit(record, action: .channelEvent, decision: .error(.bootstrapProofMismatch, error.localizedDescription))
                throw error
            }
        }
        let deadline = Date().addingTimeInterval(TimeInterval(request.timeoutSeconds ?? 10))
        while true {
            let response = try await onQueue { () -> (payload: ControlResponse, requestID: UUID)? in
                let record = try self.require(handle)
                guard let decoded = record.lastDecodedExecResponse,
                      let responseFrame = record.lastExecResponse,
                      responseFrame.requestID == record.pendingExecRequestID else { return nil }
                return (decoded, responseFrame.requestID)
            }
            if let response { return response.payload }
            if Date() >= deadline {
                throw SandboxFailure(.bootstrapProofMismatch, "exec response timeout")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// M21：读取 guest cgroup v2 资源采样（诊断用途；不参与任何安全判定）。
    public func stats(_ handle: SandboxHandle, timeoutSeconds: Int = 5) async throws -> SandboxStats {
        try await onQueue {
            let record = try self.require(handle)
            guard record.lifecycle.state == .running, record.controlSocket != nil else {
                throw SandboxFailure(.bootstrapProofMissing, "authenticated control session required before stats")
            }
            let requestID = UUID()
            let payload = Data("{}".utf8)
            let frame = try ControlFrame(kind: .statsRequest, sequence: record.nextRequestSequence(), requestID: requestID, payload: payload)
            record.pendingStatsRequestID = requestID
            record.lastStatsFrame = nil
            record.lastDecodedStats = nil
            try self.sendFrameOnQueue(record, frame: frame)
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while true {
            let stats = try await onQueue { () -> SandboxStats? in
                let record = try self.require(handle)
                guard let decoded = record.lastDecodedStats,
                      let frame = record.lastStatsFrame,
                      frame.requestID == record.pendingStatsRequestID else { return nil }
                return decoded
            }
            if let stats { return stats }
            if Date() >= deadline {
                throw SandboxFailure(.bootstrapProofMismatch, "stats response timeout")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// M1-4: open a PTY, stream optional stdin, and collect output until the
    /// child exits. Encrypted channels are fully supported (record protection).
    public struct PtySessionResult: Sendable, Equatable {
        public let exitCode: Int32?
        public let signal: Int32?
        public let output: Data

        /// Output decoded as UTF-8, useful for driving demo commands like `tty`.
        public var stdoutText: String {
            String(decoding: output, as: UTF8.self)
        }
    }

    public struct PtyStreamSession: Sendable {
        public let requestID: UUID
        public init(requestID: UUID) { self.requestID = requestID }
    }

    public struct PtyPollResult: Sendable {
        public let output: Data
        public let running: Bool
        public let exitCode: Int32?
        public let signal: Int32?
    }

    /// M13b：流式 PTY 会话（同一负责 sandbox 只允许一个活跃会话，与客协议一致）。
    public func ptyOpenSession(_ handle: SandboxHandle, argv: [String], timeoutSeconds: Int = 10) async throws -> PtyStreamSession {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        let requestID = UUID()
        try await onQueue {
            let record = try self.require(handle)
            guard record.lifecycle.state == .running,
                  record.controlSocket != nil else {
                throw SandboxFailure(.bootstrapProofMissing, "PTY requires a running authenticated session")
            }
            record.pendingPtyOpenID = requestID
            let payload = try JSONEncoder().encode(PtyOpenRequest(argv: argv))
            let frame = try ControlFrame(kind: .ptyOpen, sequence: record.nextRequestSequence(), requestID: requestID, payload: payload)
            try self.sendFrameOnQueue(record, frame: frame)
        }
        while true {
            let opened = try await onQueue { () -> Bool in
                let record = try self.require(handle)
                guard let index = record.ptyEvents.firstIndex(where: {
                    $0.type == .opened && $0.ptyId == 0
                }) else { return false }
                record.ptyEvents.remove(at: index)
                return true
            }
            if opened { break }
            if Date() >= deadline { throw SandboxFailure(.bootstrapProofMismatch, "ptyOpen timeout") }
            try await Task.sleep(for: .milliseconds(40))
        }
        return PtyStreamSession(requestID: requestID)
    }

    public func ptyWriteSession(_ handle: SandboxHandle, session: PtyStreamSession, data: Data) async throws {
        try await onQueue {
            let record = try self.require(handle)
            let hex = data.map { String(format: "%02x", $0) }.joined()
            let payload = try JSONEncoder().encode(PtyInputRequest(ptyId: 0, dataHex: hex))
            let frame = try ControlFrame(kind: .ptyInput, sequence: record.nextRequestSequence(), requestID: session.requestID, payload: payload)
            try self.sendFrameOnQueue(record, frame: frame)
        }
    }

    public func ptyPollSession(_ handle: SandboxHandle, session: PtyStreamSession, waitMillis: Int = 50) async throws -> PtyPollResult {
        var output = Data()
        var exitCode: Int32?
        var signal: Int32?
        let deadline = Date().addingTimeInterval(TimeInterval(waitMillis) / 1000.0)
        while true {
            let events = try await onQueue { () -> [PtyEvent] in
                let record = try self.require(handle)
                let matched = record.ptyEvents.filter { $0.ptyId == 0 }
                record.ptyEvents.removeAll { $0.ptyId == 0 }
                return matched
            }
            for event in events {
                switch event.type {
                case .output:
                    if let bytes = HexCoder.decode(event.dataHex) { output.append(bytes) }
                case .exit:
                    exitCode = event.exitCode
                    signal = event.signal
                case .opened:
                    continue
                }
            }
            if exitCode != nil || signal != nil {
                try await Task.sleep(for: .milliseconds(60))
                let trailing = try await onQueue { () -> [PtyEvent] in
                    let record = try self.require(handle)
                    let matched = record.ptyEvents.filter { $0.ptyId == 0 }
                    record.ptyEvents.removeAll { $0.ptyId == 0 }
                    return matched
                }
                for event in trailing where event.type == .output {
                    if let bytes = HexCoder.decode(event.dataHex) { output.append(bytes) }
                }
                return PtyPollResult(output: output, running: false, exitCode: exitCode, signal: signal)
            }
            if !output.isEmpty || Date() >= deadline {
                return PtyPollResult(output: output, running: true, exitCode: nil, signal: nil)
            }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    public func ptyRoundTrip(
        _ handle: SandboxHandle,
        argv: [String],
        inputHex: String?,
        timeoutSeconds: Int
    ) async throws -> PtySessionResult {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        let requestID = UUID()
        try await onQueue {
            let record = try self.require(handle)
            guard record.lifecycle.state == .running,
                  record.controlSocket != nil else {
                throw SandboxFailure(.bootstrapProofMissing, "PTY requires a running authenticated session")
            }
            record.pendingPtyOpenID = requestID
            let payload = try JSONEncoder().encode(PtyOpenRequest(argv: argv))
            let frame = try ControlFrame(kind: .ptyOpen, sequence: record.nextRequestSequence(), requestID: requestID, payload: payload)
            try self.sendFrameOnQueue(record, frame: frame)
        }

        // 1) Wait for `opened`.
        while true {
            let opened = try await onQueue { [requestID] () -> Int? in
                let record = try self.require(handle)
                guard let index = record.ptyEvents.firstIndex(where: {
                    $0.type == .opened && $0.ptyId == 0
                }) else { return nil }
                let event = record.ptyEvents[index]
                record.ptyEvents.remove(at: index)
                _ = event
                return 0
            }
            if let _ = opened { break }
            if Date() >= deadline { throw SandboxFailure(.bootstrapProofMismatch, "ptyOpen timeout") }
            try await Task.sleep(for: .milliseconds(50))
        }

        // 2) Optional stdin injection.
        if let inputHex, !inputHex.isEmpty {
            try await onQueue {
                let record = try self.require(handle)
                let payload = try JSONEncoder().encode(PtyInputRequest(ptyId: 0, dataHex: inputHex))
                let frame = try ControlFrame(kind: .ptyInput, sequence: record.nextRequestSequence(), requestID: requestID, payload: payload)
                try self.sendFrameOnQueue(record, frame: frame)
            }
        }

        // 3) Collect outputs until `exit`；给予一个额外 drain 周期收集尾随输出。
        var output = Data()
        var exitCode: Int32?
        var signal: Int32?
        while true {
            let events = try await onQueue { () -> [PtyEvent] in
                let record = try self.require(handle)
                let matched = record.ptyEvents.filter { $0.ptyId == 0 }
                record.ptyEvents.removeAll { $0.ptyId == 0 }
                return matched
            }
            for event in events {
                switch event.type {
                case .output:
                    if let bytes = HexCoder.decode(event.dataHex) { output.append(bytes) }
                case .exit:
                    exitCode = event.exitCode
                    signal = event.signal
                    break
                case .opened:
                    continue
                }
            }
            if exitCode != nil || signal != nil {
                // 再扫一轮：exit 与最后一批 output 可能在同一 poll burst 。 
                try await Task.sleep(for: .milliseconds(120))
                let trailing = try await onQueue { () -> [PtyEvent] in
                    let record = try self.require(handle)
                    let matched = record.ptyEvents.filter { $0.ptyId == 0 }
                    record.ptyEvents.removeAll { $0.ptyId == 0 }
                    return matched
                }
                for event in trailing where event.type == .output {
                    if let bytes = HexCoder.decode(event.dataHex) { output.append(bytes) }
                }
                break
            }
            if Date() >= deadline { throw SandboxFailure(.bootstrapProofMismatch, "pty session timeout") }
            try await Task.sleep(for: .milliseconds(40))
        }
        return PtySessionResult(exitCode: exitCode, signal: signal, output: output)
    }

    /// Push an authorized workspace snapshot over the encrypted control
    /// channel and wait for the guest ack (M2-1, fail-closed).
    @discardableResult
    public func pushWorkspace(
        _ handle: SandboxHandle,
        snapshot: WorkspaceSnapshot,
        timeoutSeconds: Int = 120
    ) async throws -> WsAckEvent {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        try await onQueue {
            let record = try self.require(handle)
            guard record.lifecycle.state == .running, record.controlSocket != nil else {
                throw SandboxFailure(.bootstrapProofMissing, "workspace sync requires running session")
            }
            let payload = try JSONEncoder().encode(WsBeginRequest(wsId: snapshot.wsId,
                                                                  fileCount: snapshot.files.count,
                                                                  totalBytes: snapshot.totalBytes))
            let frame = try ControlFrame(kind: .wsBegin, sequence: record.nextRequestSequence(), requestID: UUID(), payload: payload)
            try self.sendFrameOnQueue(record, frame: frame)
        }
        for file in snapshot.files {
            let full = snapshot.rootURL.appendingPathComponent(file.relativePath)
            let data = try Data(contentsOf: full)
            var offset: UInt64 = 0
            if data.isEmpty {
                let payload = try JSONEncoder().encode(WsPutRequest(path: file.relativePath, offset: 0, mode: file.mode, dataHex: ""))
                try await onQueue {
                    let record = try self.require(handle)
                    let frame = try ControlFrame(kind: .wsPut, sequence: record.nextRequestSequence(), requestID: UUID(), payload: payload)
                    try self.sendFrameOnQueue(record, frame: frame)
                }
            } else {
                let chunkSize = 512
                while offset < UInt64(data.count) {
                    let end = min(offset + UInt64(chunkSize), UInt64(data.count))
                    let slice = data[Int(offset)..<Int(end)]
                    let payload = try JSONEncoder().encode(WsPutRequest(path: file.relativePath,
                                                                        offset: offset,
                                                                        mode: file.mode,
                                                                        dataHex: HexCoder.encode(Data(slice))))
                    try await onQueue {
                        let record = try self.require(handle)
                        let frame = try ControlFrame(kind: .wsPut, sequence: record.nextRequestSequence(), requestID: UUID(), payload: payload)
                        try self.sendFrameOnQueue(record, frame: frame)
                    }
                    offset = end
                }
            }
        }
        try await onQueue {
            let record = try self.require(handle)
            let payload = try JSONEncoder().encode(WsEndRequest(wsId: snapshot.wsId))
            let frame = try ControlFrame(kind: .wsEnd, sequence: record.nextRequestSequence(), requestID: UUID(), payload: payload)
            try self.sendFrameOnQueue(record, frame: frame)
        }
        while true {
            let ack = try await onQueue { () -> WsAckEvent? in
                let record = try self.require(handle)
                guard let index = record.wsAcks.firstIndex(where: { $0.wsId == snapshot.wsId }) else { return nil }
                let event = record.wsAcks[index]
                record.wsAcks.remove(at: index)
                return event
            }
            if let ack {
                guard ack.ok else {
                    throw SandboxFailure(.platformAssetDigestMismatch, "workspace sync rejected by guest: \(ack.error ?? "unknown")")
                }
                return ack
            }
            if Date() >= deadline { throw SandboxFailure(.bootstrapProofMismatch, "workspace sync timeout") }
            try await Task.sleep(for: .milliseconds(40))
        }
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
        bootLoader.commandLine = assets.kernelCommandLine + " init=/init rdinit=/init console=hvc0 earlycon=hvc0 loglevel=7 panic=10 dbx.sandbox=\(boot.sandboxID.raw) dbx.boot=\(boot.bootID.raw) dbx.nonce=\(boot.bootNonce.uuidString) dbx.manifest=\(boot.guestManifestDigest) dbx.port=\(request.controlChannelPort)"

        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = bootLoader
        fputs("[vz-cfg] kernel=\(assets.kernelURL.standardizedFileURL.path) cmdline='\(assets.kernelCommandLine)' gfx=\(self.enableGraphics) console=\(self.enableConsole) ctrl=\(self.enableControlSocket)\n", stderr)
        fflush(stderr)
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
                // Keep diagnostic output visible even when the parent process is
                // line-buffered or the VM emits binary/partial lines.
                FileHandle.standardError.write(data)
                try? FileHandle.standardError.synchronize()
                fflush(stderr)
            }
            self.lastConsole = serialConsole
            let serial = VZVirtioConsoleDeviceConfiguration()
            let consolePort = VZVirtioConsolePortConfiguration()
            // Match Apple's Linux VZ console example. The console port name is
            // guest-visible metadata; isConsole makes it the hvc0 console.
            consolePort.name = "org.linux.console"
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

        // M14：可选 virtio-gpu。此阶段无 host 视频窗；配置与 guest 探测模式仅作 spike。
        if self.enableGraphics {
            let gfx = VZVirtioGraphicsDeviceConfiguration()
            gfx.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 800)]
            configuration.graphicsDevices = [gfx]
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

    /// VZ objects and their connection/file descriptor accessors must be used
    /// on the VM queue. `onQueue` resumes async work on a cooperative thread,
    /// which is not guaranteed to still be `queue`, so dispatch explicitly.
    private func closeSocketOnQueue(_ record: Record) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            record.controlSocket?.close()
        } else {
            queue.sync { record.controlSocket?.close() }
        }
    }

    private func sendFrameOnQueue(_ record: Record, frame: ControlFrame) throws {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            try record.controlSocket?.send(frame)
        } else {
            try queue.sync { try record.controlSocket?.send(frame) }
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
                            for frame in frames {
                                self.handleControlFrame(frame, record: record)
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
                    // Keep the first authenticated hello session. The guest may
                    // send a second hello from root init; a hello reset must not
                    // downgrade the proofed session or lose replay state.
                    if record.controlSocket != nil {
                        boxedConnection.value.close()
                        return
                    }
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

    private func handleBrokerFetch(_ request: BrokerFetchRequest, record: Record) {
        guard let configDir = brokerConfigDir else {
            self.sendBrokerEnd(record, request: request, status: 0, ok: false, error: "broker not configured")
            return
        }
        guard let url = URL(string: request.url) else {
            self.sendBrokerEnd(record, request: request, status: 0, ok: false, error: "bad url")
            return
        }
        // M23（INV-02）：出口策略与凭据**按域解析**。
        // 域有 brokerPolicyFile 就只读该文件；域没有 → 该域禁止出站（不给「全局兜底策略」）。
        // 凭据同理：域 A 的凭据永远不会被域 B 的沙箱取到。
        let domain = record.domain
        let policyURL: URL
        let credsURL: URL? 
        if domain.brokerPolicyFile != nil || domain.brokerCredentialsFile != nil {
            let credentialRoot = configDir
            do {
                let resolved = try DomainRegistry(
                    manifest: CredentialDomainsManifest(defaultDomain: domain.domainID, domains: [domain]),
                    credentialRoot: credentialRoot
                ).resolveForBroker(domain.domainID)
                guard let resolvedPolicy = resolved.policyURL else {
                    self.sendBrokerEnd(record, request: request, status: 0, ok: false,
                                       error: "DBX-DOMAIN-NO-EGRESS: 域 \(domain.domainID) 未配置出口策略")
                    return
                }
                policyURL = resolvedPolicy
                credsURL = resolved.credentialsURL
            } catch {
                self.sendBrokerEnd(record, request: request, status: 0, ok: false,
                                   error: "DBX-DOMAIN-POLICY: \(error)")
                return
            }
        } else {
            policyURL = configDir.appendingPathComponent("broker-policy.json")
            credsURL = configDir.appendingPathComponent("broker-credentials.local")
        }
        let handle = SandboxHandle(sandboxID: record.request.sandboxID, bootID: record.boot.bootID,
                                   domainID: domain.domainID)
        Task {
            do {
                let policy = try BrokerPolicy.load(from: policyURL)
                let credentials = credsURL.map { CredentialBroker.load(from: $0) }
                    ?? CredentialBroker(tokenByHost: [:])
                let broker = BrokerService(policy: policy, credentials: credentials)
                let (data, report) = try await broker.fetch(url)
                try await self.pushBrokerChunks(handle: handle, request: request, data: data,
                                                status: Int32(report.statusCode))
            } catch {
                try? await self.sendBrokerEndAsync(handle: handle, request: request,
                                                   status: 0, ok: false,
                                                   error: String(describing: error))
            }
        }
    }

    private func sendBrokerEnd(_ record: Record, request: BrokerFetchRequest, status: Int32, ok: Bool, error: String?) {
        do {
            let payload = try JSONEncoder().encode(BrokerFetchEnd(reqId: request.reqId, status: status, ok: ok, error: error))
            let frame = try ControlFrame(kind: .brokerEnd, sequence: record.nextRequestSequence(), requestID: UUID(), payload: payload)
            try self.sendFrameOnQueue(record, frame: frame)
        } catch { _ = () }
    }

    private func sendBrokerEndAsync(handle: SandboxHandle, request: BrokerFetchRequest, status: Int32, ok: Bool, error: String?) async throws {
        try await onQueue {
            let record = try self.require(handle)
            self.sendBrokerEnd(record, request: request, status: status, ok: ok, error: error)
        }
    }

    private func pushBrokerChunks(handle: SandboxHandle, request: BrokerFetchRequest, data: Data, status: Int32) async throws {
        let chunkSize = 512
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let slice = data[offset..<end]
            let payload = try JSONEncoder().encode(BrokerDataChunk(reqId: request.reqId, dataHex: HexCoder.encode(Data(slice))))
            try await onQueue {
                let record = try self.require(handle)
                let frame = try ControlFrame(kind: .brokerData, sequence: record.nextRequestSequence(), requestID: UUID(), payload: payload)
                try self.sendFrameOnQueue(record, frame: frame)
            }
            offset = end
        }
        try await self.sendBrokerEndAsync(handle: handle, request: request, status: status, ok: true, error: nil)
    }

    private func handleControlFrame(_ frame: ControlFrame, record: Record) {
        // Response frames carry the guest exec result; decode and retain the
        // structured value for `execute` callers.
        if frame.kind == .response {
            if let response = try? JSONDecoder().decode(ControlResponse.self, from: frame.payload) {
                record.lastExecResponse = frame
                record.lastDecodedExecResponse = response
            }
            self.recordAudit(record, action: .channelEvent, decision: .allow())
            return
        }
        if frame.kind == .statsResponse {
            if let stats = try? JSONDecoder().decode(SandboxStats.self, from: frame.payload) {
                record.lastStatsFrame = frame
                record.lastDecodedStats = stats
            }
            recordAudit(record, action: .channelEvent, decision: .allow())
            return
        }
        if frame.kind == .ptyEvent {
            if let event = try? JSONDecoder().decode(PtyEvent.self, from: frame.payload) {
                record.ptyEvents.append(event)
            } else {
                recordAudit(record, action: .channelEvent, decision: .error(.bootstrapProofMismatch, "ptyEvent payload decode failed"))
            }
            self.recordAudit(record, action: .channelEvent, decision: .allow())
            return
        }
        if frame.kind == .wsAck {
            if let ack = try? JSONDecoder().decode(WsAckEvent.self, from: frame.payload) {
                record.wsAcks.append(ack)
            } else {
                recordAudit(record, action: .channelEvent, decision: .error(.bootstrapProofMismatch, "wsAck payload decode failed"))
            }
            self.recordAudit(record, action: .channelEvent, decision: .allow())
            return
        }
        if frame.kind == .brokerFetch {
            do {
                let request = try JSONDecoder().decode(BrokerFetchRequest.self, from: frame.payload)
                self.handleBrokerFetch(request, record: record)
            } catch {
                recordAudit(record, action: .channelEvent, decision: .error(.bootstrapProofMismatch, "brokerFetch decode failed"))
            }
            return
        }
        if frame.kind == .keyExchange {
            handleKeyExchange(frame: frame, record: record)
            return
        }
        guard frame.kind == .hello else {
            recordAudit(record, action: .channelEvent, decision: .deny(.bootstrapProofMissing, "TLS/bootstrap 完成前只接受 hello"))
            return
        }
        if record.bootstrapState == .authenticated || record.bootstrapState == .tlsAuthenticated {
            recordAudit(record, action: .channelEvent, decision: .deny(.bootstrapProofMismatch, "duplicate hello after authenticated session"))
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
            var ack = BootstrapHelloAck(sessionID: .new(), requiresTLS: true)
            if self.securityPolicy.requiresTLSUpgrade {
                // M1-2: arm the ephemeral X25519 host key share into the ACK;
                // the session is only established once the guest replies with
                // its own ephemeral key as a keyExchange frame.
                let session = SecureRecordSession(context: record.boot)
                record.secureSession = session
                ack = BootstrapHelloAck(
                    sessionID: .new(), requiresTLS: true,
                    hostKeyPublicHex: session.hostPublicHex
                )
            }
            let payload = try BootstrapCodec.encodeAck(ack)
            let response = try ControlFrame(kind: .helloAck, sequence: frame.sequence + 1, requestID: frame.requestID, payload: payload)
            try self.sendFrameOnQueue(record, frame: response)
            if self.securityPolicy.requiresTLSUpgrade {
                record.bootstrapState = .helloAcceptedTLSRequired
                self.recordAudit(record, action: .channelEvent, decision: .error(.bootstrapTLSRequired, "hello 绑定成功；等待 guest keyExchange 完成 TLS 升级"))
                return
            }
            recordAudit(record, action: .channelEvent, decision: .error(.bootstrapTLSRequired, "hello 绑定成功；仍需 TLS 1.3 双向认证后才能建立 session"))
            // MVP transport readiness: a bound hello/ack over the VSOCK control
            // channel proves this boot's guest agent is live. The TLS layer is
            // still required for authorization; workload execution remains
            // disabled until the authenticated session proof lands.
            let proof = BootstrapProof(
                sandboxID: hello.sandboxID,
                bootID: hello.bootID,
                bootNonce: hello.bootNonce,
                protocolMajor: hello.protocolMajor,
                guestManifestDigest: hello.guestManifestDigest,
                sessionID: ack.sessionID
            )
            try record.lifecycle.transition(to: .running, reason: .bootstrapProofAccepted, proof: proof)
            record.lastAcceptedProof = proof
            record.bootstrapState = .authenticated
            self.recordAudit(record, action: .channelEvent, decision: .allow())
        } catch {
            recordAudit(record, action: .channelEvent, decision: .error(.bootstrapProofMismatch, error.localizedDescription))
            self.closeSocketOnQueue(record)
        }
    }

    /// M1-2: complete the ephemeral X25519 key exchange, upgrade the transport
    /// to record protection, then transition to `running` with the TLS-derived
    /// session ID as proof material.
    private func handleKeyExchange(frame: ControlFrame, record: Record) {
        guard self.securityPolicy.requiresTLSUpgrade,
              record.bootstrapState == .helloAcceptedTLSRequired,
              let session = record.secureSession,
              let socket = record.controlSocket else {
            recordAudit(record, action: .channelEvent, decision: .deny(.bootstrapTLSRequired, "keyExchange 在 TLS 升级窗口外到达"))
            return
        }
        do {
            try session.completeKeyExchange(guestPublicData: frame.payload, boot: record.boot)
            guard let binding = session.sessionBinding else {
                throw SandboxFailure(.bootstrapTLSRequired, "key exchange did not yield a session binding")
            }
            socket.upgradeTransport(to: session)
            record.bootstrapState = .tlsAuthenticating
            let proof = BootstrapProof(
                sandboxID: record.request.sandboxID,
                bootID: record.boot.bootID,
                bootNonce: record.boot.bootNonce,
                protocolMajor: record.boot.protocolMajor,
                guestManifestDigest: record.boot.guestManifestDigest,
                sessionID: binding.sessionID
            )
            try record.lifecycle.transition(to: .running, reason: .bootstrapProofAccepted, proof: proof)
            record.lastAcceptedProof = proof
            record.bootstrapState = .tlsAuthenticated
            self.recordAudit(record, action: .channelEvent, decision: .allow())
        } catch {
            record.lifecycle.forceFail(reason: .bootstrapTLSRequired)
            self.recordAudit(record, action: .channelEvent, decision: .error(.bootstrapTLSRequired, "keyExchange failed: \(error.localizedDescription)"))
            self.closeSocketOnQueue(record)
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
        // M23（INV-02）：声明了域就必须与会话域一致——跨域 exec/pty/stats/stop/rm 全部拒绝。
        if let declared = handle.domainID, declared != record.domain.domainID {
            recordSchedulerDecision(record, decision: "deny",
                                    reason: "session-domain-mismatch \(declared.raw) != \(record.domain.domainID.raw)")
            throw SandboxFailure(.domainSessionMismatch,
                                 "DBX-DOMAIN-SESSION-MISMATCH: 请求域 \(declared.raw) 与沙箱域 \(record.domain.domainID.raw) 不一致")
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
