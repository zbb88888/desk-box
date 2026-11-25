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
        /// M39：当前 exec 的输出块汇总（只接受 requestID 与 pendingExecRequestID 相同的块）。
        var execAssembler: ExecOutputAssembler?
        /// M41：exec 请求已发出、应答尚未被取走。只有此时 cancelExec 才会发送取消帧。
        var execInFlight = false
        /// M43：guest 一侧关闭了**当前**控制连接（它的控制进程退出 / 崩溃 / 被杀）时的说明。
        /// 换上新连接（resume 之后的重连）时清空。等待应答的循环据此立刻失败，而不是等到超时。
        var controlLost: String?
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
        // M24b：O_APPEND 原子追加——并发 run 不会互相覆盖证据行。
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
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
        let now = Date()
        for entry in entries {
            // M27：判定下沉到 SnapshotSweepPolicy（属主 PID 存活 → 在途，跨进程成立）。
            let mtime = (try? fm.attributesOfItem(atPath: entry.path)[.modificationDate]) as? Date
            let verdict = SnapshotSweepPolicy.verdict(
                name: entry.lastPathComponent, liveSandboxIDs: keeping,
                age: mtime.map { now.timeIntervalSince($0) },
                isProcessAlive: SandboxRegistry.processIsAlive)
            if verdict == .remove { try? fm.removeItem(at: entry) }
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
        // 前置条件失败（状态不对 / 沙箱不存在）不改变任何东西，无需回滚。
        try await onQueue {
            let record = try self.require(handle)
            guard record.lifecycle.state == .running else {
                throw SandboxFailure(.lifecycleInvalidTransition,
                                     "suspend 仅允许 running 状态，当前 \(record.lifecycle.state)")
            }
            try record.lifecycle.transition(to: .suspending, reason: .lifecycleStopRequested)
        }
        do {
            try await self.performSuspend(handle, snapshotURL: snapshotURL)
        } catch {
            // M28：此前任何一步失败（pause / 保存 / 读回 / 加密落盘）都直接上抛——VM 停在 paused、
            // 状态停在 suspending：既不能 exec（不是 running），也不能 resume（不是 suspended），
            // 再 suspend 也被拒，只剩 rm。现在回滚到 running；回滚不了就明确进入 failed。
            let restored = await self.rollbackFailedSuspend(handle)
            if restored {
                throw SandboxFailure(.lifecycleSuspendAborted,
                                     "suspend 失败，已回滚到 running（沙箱可继续使用）| cause: \(error)")
            }
            throw SandboxFailure(.lifecycleSuspendFailed,
                                 "suspend 失败且无法回滚，沙箱已进入 failed（请 rm）| cause: \(error)")
        }
    }

    private func performSuspend(_ handle: SandboxHandle, snapshotURL: URL) async throws {
        try await onQueue {
            let record = try self.require(handle)
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
            .appendingPathComponent(SnapshotSweepPolicy.suspendTempName())
        // M35：这里随后会落一份**明文** VM 内存状态（VZ 的保存文件，权限由 VZ 决定）。
        // 目录必须先是 0700，保存期间才不会被同机其他用户读到。
        try PrivateDirectory.ensureOwned(snapshotURL.deletingLastPathComponent())
        // defer 必须在保存之前登记：保存中途失败留下的半截文件也要删。
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await self.vzOperation { completion in
            machine.saveMachineStateTo(url: tempURL) { error in completion(error) }
        }

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

    /// M28：suspend 失败后的回滚。返回 true = 沙箱已回到 running。
    ///
    /// 只处理「仍停在 suspending」的情况：已经走到 suspended（快照已加密落盘，只是收尾的
    /// registry 写入失败）不回滚——那一刻再把 VM 拉起来反而会让磁盘上留下一份与运行态分叉的快照。
    private func rollbackFailedSuspend(_ handle: SandboxHandle) async -> Bool {
        guard let machine = try? await onQueue({ try self.require(handle).machine }) else { return false }
        let vmState: VZVirtualMachine.State = await withCheckedContinuation { continuation in
            self.queue.async { continuation.resume(returning: machine.state) }
        }
        var vmRunning = (vmState == .running)
        if vmState == .paused {
            do {
                try await self.vzOperation { completion in
                    machine.resume { result in
                        switch result {
                        case .success: completion(nil)
                        case .failure(let error): completion(error)
                        }
                    }
                }
                vmRunning = true
            } catch {
                vmRunning = false
            }
        }
        let running = vmRunning
        let outcome = try? await onQueue { () -> Bool in
            let record = try self.require(handle)
            guard record.lifecycle.state == .suspending else {
                return record.lifecycle.state == .running
            }
            if running, let proof = record.lastAcceptedProof {
                do {
                    // 进入 running 仍然必须带与当前 boot 绑定的 proof：同一 boot、同一会话、未曾 restore。
                    try record.lifecycle.transition(to: .running, reason: .lifecycleSuspendAborted, proof: proof)
                    try? self.registry.upsert(RegisteredSandbox(
                        sandboxID: record.request.sandboxID, bootID: record.boot.bootID,
                        status: .running, clonePath: record.cowLease.cloneURL.standardizedFileURL.path,
                        hostPID: ProcessInfo.processInfo.processIdentifier,
                        domainID: record.domain.domainID))
                    self.recordAudit(record, action: .channelEvent,
                                     decision: .error(.lifecycleSuspendAborted, "suspend 失败，已回滚到 running"))
                    return true
                } catch {
                    // 落到下面的 forceFail。
                }
            }
            record.lifecycle.forceFail(reason: .lifecycleSuspendFailed)
            self.recordAudit(record, action: .channelEvent,
                             decision: .error(.lifecycleSuspendFailed, "suspend 失败且无法回滚"))
            return false
        }
        return outcome ?? false
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
            .appendingPathComponent(SnapshotSweepPolicy.restoreTempName())
        // M35：解密后的明文 VM 状态。此前按默认权限（0644）写入。
        try PrivateDirectory.ensureOwned(tempURL.deletingLastPathComponent())
        try SecureFile.write(payload, to: tempURL)
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

    /// M45：guest 一侧意外关闭控制连接的说明（供 daemon `ps` 使用）；没有则为 nil。
    public func cachedControlLoss(of handle: SandboxHandle) -> String? {
        queue.sync { records[handle.sandboxID]?.controlLost }
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
            // M27 fix（INV-10）：销毁必须连同快照一起清除。此前 destroy 不碰 `.snap`——对
            // suspended 沙箱执行 rm / shutdown 后，其加密 VM 状态仍留在磁盘上，直到之后某次
            // run 触发的 sweep 才被顺带清掉。之所以一直没暴露，是因为测试总是先 resume 再 rm
            //（resume 成功时会删快照）。
            let snapshot = self.snapshotURL(for: handle.sandboxID)
            do {
                try FileManager.default.removeItem(at: snapshot)
            } catch CocoaError.fileNoSuchFile {
                // 没有快照（从未 suspend，或已在 resume 时删除）。
            } catch {
                record.lifecycle.forceFail(reason: .platformCowCleanupFailed)
                self.recordAudit(record, action: .destroy,
                                 decision: .error(.platformCowCleanupFailed, "snapshot cleanup: \(error.localizedDescription)"))
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
        try await runExec(handle, request: request).response
    }

    /// M39：执行并取回完整输出。请求 guest 流式回传（新 guest：每路最多 `maxOutputBytes`，超出有标记；
    /// 旧 guest：忽略该请求，按老办法单帧应答，结果里会带「可能被截断」的提示）。
    public func executeCollectingOutput(_ handle: SandboxHandle, request: ControlRequest,
                                        maxOutputBytes: Int = ExecOutputPolicy.defaultMaxBytes) async throws -> ExecResult {
        var streaming = request
        streaming.streamOutput = true
        streaming.maxOutputBytes = maxOutputBytes
        let (response, assembler) = try await runExec(handle, request: streaming)
        return assembler.finish(response)
    }

    /// M43：等待 guest 应答的循环每一轮都调用。当前控制连接已被 guest 一侧关闭时，
    /// 把沙箱标为 failed 并抛出带原因码的错误。
    private func failIfControlLost(_ handle: SandboxHandle, waitingFor op: String) async throws {
        try await onQueue {
            let record = try self.require(handle)
            guard let reason = record.controlLost else { return }
            record.execInFlight = false
            if record.lifecycle.state == .running {
                record.lifecycle.forceFail(reason: .bootstrapProofMismatch)
            }
            throw SandboxFailure(.bootstrapProofMismatch, ControlLossPolicy.message(waitingFor: op, detail: reason))
        }
    }

    /// M41：请求 guest 取消在途的 exec（杀掉它的进程组并立刻应答）。
    /// - Returns: 是否发出了取消帧（没有在途 exec 时为 false）。发出不等于生效：旧 guest 会忽略它。
    @discardableResult
    public func cancelExec(_ handle: SandboxHandle) async throws -> Bool {
        try await onQueue {
            let record = try self.require(handle)
            guard record.execInFlight, let requestID = record.pendingExecRequestID,
                  record.lifecycle.state == .running, record.controlSocket != nil else { return false }
            let frame = try ControlFrame(kind: .execCancel, sequence: record.nextRequestSequence(),
                                         requestID: requestID, payload: Data("{}".utf8))
            try self.sendFrameOnQueue(record, frame: frame)
            return true
        }
    }

    private func runExec(_ handle: SandboxHandle, request: ControlRequest) async throws
        -> (response: ControlResponse, assembler: ExecOutputAssembler) {
        // M45：控制面已经没了就直说（此前这里会报「authenticated control session required」）。
        try await failIfControlLost(handle, waitingFor: "exec")
        // M2-2: 允许 echo/sh 诊断与 /workspace 下经策略同步的可执行面。
        guard let first = request.argv.first else {
            throw SandboxFailure(.bootstrapProofMissing, "exec argv 不可为空")
        }
        // M18：/bin/hardening-probe 是随签名 rootfs 一起下发的固定自检二进制
        // （只执行预置的测例，不接受任意代码），用于验证内核级加固是否生效。
        // M37：规范路径判断（此前是 hasPrefix，`/workspace/../bin/x` 能绕过）。
        let allowedFirst = ExecPathPolicy.allowsExecutable(first)
        let cwdOK = ExecPathPolicy.allowsWorkingDirectory(request.cwd)
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
            record.execAssembler = ExecOutputAssembler(maxBytes: request.maxOutputBytes ?? ExecOutputPolicy.defaultMaxBytes)
            // Drop the previous response so a new request can never read stale output.
            record.lastDecodedExecResponse = nil
            record.lastExecResponse = nil
            do {
                try self.sendFrameOnQueue(record, frame: frame)
                record.execInFlight = true
                self.recordAudit(record, action: .channelEvent, decision: .allow())
            } catch {
                record.lifecycle.forceFail(reason: .bootstrapProofMismatch)
                self.recordAudit(record, action: .channelEvent, decision: .error(.bootstrapProofMismatch, error.localizedDescription))
                throw error
            }
        }
        // M39：超时由 guest 执行（杀进程组并应答 exit -2）。宿主多等一会儿，让 guest 的结论先到；
        // 此前两边同时到点，用户看到的是含糊的「exec response timeout」而不是「命令超时」。
        let timeout = request.timeoutSeconds ?? 10
        let deadline = Date().addingTimeInterval(TimeInterval(timeout + ExecOutputPolicy.responseGraceSeconds))
        while true {
            let response = try await onQueue { () -> (ControlResponse, ExecOutputAssembler)? in
                let record = try self.require(handle)
                guard let decoded = record.lastDecodedExecResponse,
                      let responseFrame = record.lastExecResponse,
                      responseFrame.requestID == record.pendingExecRequestID else { return nil }
                let assembler = record.execAssembler ?? ExecOutputAssembler()
                record.execAssembler = nil
                record.execInFlight = false
                return (decoded, assembler)
            }
            if let response { return response }
            // M43：guest 的控制进程没了就不会再有应答——立刻失败，不等到超时。
            try await self.failIfControlLost(handle, waitingFor: "exec")
            if Date() >= deadline {
                _ = try? await onQueue { (try? self.require(handle))?.execInFlight = false }
                throw SandboxFailure(.bootstrapProofMismatch,
                                     "exec response timeout（guest 在命令超时 \(timeout)s 之后的 \(ExecOutputPolicy.responseGraceSeconds)s 内仍未应答）")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// M21：读取 guest cgroup v2 资源采样（诊断用途；不参与任何安全判定）。
    public func stats(_ handle: SandboxHandle, timeoutSeconds: Int = 5) async throws -> SandboxStats {
        try await failIfControlLost(handle, waitingFor: "stats")
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
            try await self.failIfControlLost(handle, waitingFor: "stats")
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
        try await failIfControlLost(handle, waitingFor: "ptyOpen")
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        let requestID = UUID()
        try await onQueue {
            let record = try self.require(handle)
            guard record.lifecycle.state == .running,
                  record.controlSocket != nil else {
                throw SandboxFailure(.bootstrapProofMissing, "PTY requires a running authenticated session")
            }
            record.pendingPtyOpenID = requestID
            // M33：丢弃上一会话遗留的事件（尤其是 close 产生的 exit）——否则新会话第一次 poll
            // 就会读到旧的 exit，看起来像「刚打开就退出了」。
            record.ptyEvents.removeAll { $0.ptyId == 0 }
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
            try await self.failIfControlLost(handle, waitingFor: "ptyOpen")
            if Date() >= deadline { throw SandboxFailure(.bootstrapProofMismatch, "ptyOpen timeout") }
            try await Task.sleep(for: .milliseconds(40))
        }
        return PtyStreamSession(requestID: requestID)
    }

    /// M33：关闭流式 PTY 会话——让 guest 杀掉 shell 并释放 pty。
    ///
    /// 协议里一直有 `ptyClose`（kind 12），guest 也实现了（SIGKILL + exit 事件），但宿主从不发送：
    /// daemon 的 `ptyClose` 只是把会话从自己的表里删掉，guest 里的 shell 照常运行。
    /// 而 guest 同一时刻只支持一个 pty（ptyId=0），于是「关掉终端再打开」永远失败（ptyOpen 超时）。
    ///
    /// - Returns: 是否在限时内看到了 guest 的 exit 事件。看不到也不抛错（尽力而为：沙箱可能
    ///   已经停了），但会把遗留事件清掉。
    @discardableResult
    public func ptyCloseSession(_ handle: SandboxHandle, session: PtyStreamSession,
                                timeoutMillis: Int = 2000) async throws -> Bool {
        try await onQueue {
            let record = try self.require(handle)
            guard record.lifecycle.state == .running, record.controlSocket != nil else {
                throw SandboxFailure(.bootstrapProofMissing, "PTY close requires a running authenticated session")
            }
            let frame = try ControlFrame(kind: .ptyClose, sequence: record.nextRequestSequence(),
                                         requestID: session.requestID, payload: Data("{}".utf8))
            try self.sendFrameOnQueue(record, frame: frame)
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMillis) / 1000.0)
        while true {
            let exited = try await onQueue { () -> Bool in
                let record = try self.require(handle)
                let sawExit = record.ptyEvents.contains { $0.ptyId == 0 && $0.type == .exit }
                // 关闭之后这些输出没有人会读了。
                record.ptyEvents.removeAll { $0.ptyId == 0 }
                return sawExit
            }
            if exited { return true }
            if Date() >= deadline { return false }
            try await Task.sleep(for: .milliseconds(40))
        }
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
            if !output.isEmpty {
                return PtyPollResult(output: output, running: true, exitCode: nil, signal: nil)
            }
            // M44：guest 的控制进程没了，终端不会再有输出——此前轮询会一直返回「还在运行、没有输出」。
            try await self.failIfControlLost(handle, waitingFor: "pty")
            if Date() >= deadline {
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
            // M33：丢弃上一会话遗留的事件（尤其是 close 产生的 exit）——否则新会话第一次 poll
            // 就会读到旧的 exit，看起来像「刚打开就退出了」。
            record.ptyEvents.removeAll { $0.ptyId == 0 }
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
        try await failIfControlLost(handle, waitingFor: "workspace sync")
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
            // M37：只推送快照构建时读入的字节。此前这里按路径重新 `Data(contentsOf:)`——跟随符号链接、
            // 不检查大小、也不与快照里的摘要比对：校验之后把文件换成指向别处的链接，就能把任意
            // 宿主文件送进 guest（INV-05 的 TOCTOU）。
            let data = file.contents
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
            try await self.failIfControlLost(handle, waitingFor: "workspace sync")
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
                    // 失败回调里要知道「出事的是不是当前这条连接」：resume / stop 会先把 controlSocket 置空，
                    // 旧连接随后报的 EOF 不算数。
                    let identity = ControlSocketIdentity()
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
                                if ControlLossPolicy.isUnexpected(
                                    failedSocketIsCurrent: identity.socket != nil && record.controlSocket === identity.socket,
                                    state: record.lifecycle.state) {
                                    record.controlLost = message
                                    // M45：立刻标为 failed。此前要等到下一条请求撞上去才变——在那之前 `ps` 和界面
                                    // 一直显示 running，而这台沙箱已经不会响应任何请求。
                                    record.execInFlight = false
                                    record.lifecycle.forceFail(reason: .bootstrapProofMismatch)
                                    fputs("vz: sandbox \(record.request.sandboxID) lost its guest control plane: \(message)\n", stderr)
                                }
                            }
                        }
                    )
                    identity.socket = socket
                    // Keep the first authenticated hello session. The guest may
                    // send a second hello from root init; a hello reset must not
                    // downgrade the proofed session or lose replay state.
                    if record.controlSocket != nil {
                        boxedConnection.value.close()
                        return
                    }
                    record.controlSocket = socket
                    record.controlLost = nil
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
                // M42：失败原因只回给 guest（而 guest 的 brokerreq 早已返回 OK）——宿主这边此前没有任何痕迹。
                // 只记录主机名，不记录完整 URL（查询串里可能有敏感内容）。
                fputs("broker: fetch failed host=\(url.host ?? "?") sandbox=\(handle.sandboxID): \(error)\n", stderr)
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
        if frame.kind == .execOutput {
            // 只接受当前在途 exec 的块；其它的（迟到的、伪造 requestID 的）丢弃。
            if frame.requestID == record.pendingExecRequestID,
               let chunk = try? JSONDecoder().decode(ExecOutputChunk.self, from: frame.payload) {
                record.execAssembler?.append(chunk)
            }
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

