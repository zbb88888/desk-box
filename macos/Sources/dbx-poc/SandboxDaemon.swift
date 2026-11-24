import Darwin
import DeskBoxCore
import DeskBoxVZ
import Foundation

/// M12：UNIX 域 socket 型 daemon 协议（JSON lines）。
/// 请求一行 JSON；响应一行 JSON；每连接一个 request/response。
struct DaemonRequest: Codable {
    let kind: String
    var sandboxId: String? = nil
    var manifestPath: String? = nil
    var workspaceDir: String? = nil
    var ociBundlePath: String? = nil
    var allowPlaintext: Bool? = nil
    var allowUnsignedManifest: Bool? = nil
    var releaseKeysPath: String? = nil
    var memoryMiB: Int? = nil
    var cpus: Int? = nil
    var cowRoot: String? = nil
    var argv: [String]? = nil
    var env: [String: String]? = nil
    var cwd: String? = nil
    var timeoutSeconds: Int? = nil
    var force: Bool? = nil
    var ptySessionId: String? = nil
    var dataHex: String? = nil
    var waitMillis: Int? = nil
    var graphics: Bool? = nil
    /// M23（INV-02）：凭据域。run 用它定域；其余操作用它做会话比对。
    var domain: String? = nil
}

struct DaemonResponse: Codable {
    let ok: Bool
    var ptySessionId: String? = nil
    var outputHex: String? = nil
    var running: Bool? = nil
    var error: String? = nil
    var sandboxId: String? = nil
    var state: String? = nil
    var exitCode: Int32? = nil
    var stdout: String? = nil
    var stderr: String? = nil
    var sandboxes: [SandboxInfo]? = nil
    var pid: Int32? = nil
    /// M21：资源采样（诊断）。
    var stats: SandboxStats? = nil
}

struct SandboxInfo: Codable {
    let sandboxId: String
    let state: String
    let bootedAtUtc: String
    let manifestPath: String
    var uptimeSeconds: Int? = nil
    var workspaceId: String? = nil
    /// M23（INV-02）：凭据域（`ps` 可审计）。
    var domain: String? = nil
}

struct SandboxRunOptions: Codable {
    var manifestPath: String
    var cpus: Int?
    var memoryMiB: Int?
    var graphics: Bool?
    var cowRoot: String?
    var allowUnsignedManifest: Bool?
    var allowPlaintext: Bool?
}

final class SandboxSession: @unchecked Sendable {
    let id: String
    let runtime: VZRuntime
    let handle: SandboxHandle
    let manifestPath: String
    let bootedAt: Date
    /// M23（INV-02）：会话所属凭据域；所有后续操作必须带同域标签。
    let domainID: CredentialDomainID
    /// M16：保留 run 参数以便 `restart` 恢复工作流。
    let runOptions: SandboxRunOptions
    /// M24b：每沙箱串行操作队列（跨沙箱并行；同沙箱 VM 操作串行）。
    let opQueue: DispatchQueue
    /// M26b：拆除类操作用它打断在途/排队中的 guest 操作。
    let cancellation = OpCancellation()
    init(id: String, runtime: VZRuntime, handle: SandboxHandle, manifestPath: String,
         runOptions: SandboxRunOptions, domainID: CredentialDomainID) {
        self.id = id
        self.runtime = runtime
        self.handle = handle
        self.manifestPath = manifestPath
        self.runOptions = runOptions
        self.domainID = domainID
        self.bootedAt = Date()
        self.opQueue = DispatchQueue(label: "deskbox.daemon.sandbox.\(id)")
    }
}

/// M24b：并发 daemon。
/// - 连接处理并发（handlerQueue）；`run` 等长操作不再阻塞 `ps`/`shutdown`；
/// - 状态（sessions/ptySessions/draining）收口到串行 stateQueue；
/// - VM 操作按沙箱串行（SandboxSession.opQueue）；VZ 自身 queue 纪律由 VZRuntime 内部保证。
final class SandboxDaemon: @unchecked Sendable {
    private let sockPath: String
    private var sessions: [String: SandboxSession] = [:]
    private let stateQueue = DispatchQueue(label: "deskbox.daemon.state")
    private let handlerQueue = DispatchQueue(label: "deskbox.daemon.handlers", attributes: .concurrent)
    private var shouldStop = false
    private var draining = false
    private var serverFD: Int32 = -1

    static func defaultSockPath() -> String {
        DeskBoxPaths.ensureSupportRootExists()
        return DeskBoxPaths.daemonSocketURL.path
    }

    /// DeskBox 支持目录（domains.json 所在）。测试注入临时目录，避免读写用户真实配置。
    private let supportRoot: URL
    /// M24c：在途连接处理计数；serveLoop 返回前等它们写完响应。
    private let handlerGroup = DispatchGroup()

    init(sockPath: String, supportRoot: URL? = nil) {
        self.sockPath = sockPath
        self.supportRoot = supportRoot
            ?? DeskBoxPaths.supportRoot
    }

    /// M23：把 `domains.json` 挂到 runtime（缺失时保持内置单域 `default`）。
    private func configureDomainsIfPresent(runtime: VZRuntime) {
        let root = self.supportRoot
        let manifestURL = root.appendingPathComponent("domains.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            fputs("daemon domains: domains.json 不存在，使用内置单域 default\n", stderr)
            return
        }
        do {
            let registry = try DomainRegistry.load(from: manifestURL, credentialRoot: root)
            runtime.configureDomains(registry)
            fputs("daemon domains: loaded \(registry.domains.map(\.domainID.raw).joined(separator: ",")) default=\(registry.defaultDomain?.raw ?? "nil")\n", stderr)
        } catch {
            // fail-closed：domains.json 存在但非法 → 拒绝启动（不能带着错配置跑沙箱）。
            fputs("daemon domains: FATAL \(error)\n", stderr)
            exit(2)
        }
    }

    /// 启动期校验：domains.json 存在但非法时直接拒绝启动（不带错配置接单）。
    private func validateDomainsAtStartup() {
        let root = self.supportRoot
        let manifestURL = root.appendingPathComponent("domains.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        do {
            let registry = try DomainRegistry.load(from: manifestURL, credentialRoot: root)
            fputs("daemon domains: loaded \(registry.domains.map(\.domainID.raw).joined(separator: ",")) default=\(registry.defaultDomain?.raw ?? "nil")\n", stderr)
        } catch {
            fputs("daemon domains: FATAL \(error)\n", stderr)
            exit(2)
        }
    }

    func serve() throws -> Never {
        try serveLoop()
        Foundation.exit(0)
    }

    /// M24c：可测试的主循环（shutdown 后返回而不 exit 进程）；退出时 unlink sock 清残留。
    func serveLoop() throws {
        validateDomainsAtStartup()
        // M27：单实例守卫。此前这里无条件 unlink(sockPath) 再 bind——第二个 daemon 会把
        // 正在运行的 daemon 的 socket 抢走，旧 daemon 连同它的 VM 变成不可达的孤儿。
        let instanceLock = try DaemonInstanceGuard.acquire(sockPath: sockPath)
        defer { instanceLock.release() }
        // M17 hotfix：GUIspawn 怕 stderr fd 被释放后 serial 写造不被 SIGPIPE 同杀同。
        signal(SIGPIPE, SIG_IGN)
        unlink(sockPath)
        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { throw CLIError.usage("socket() failed: errno=\(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(sockPath.utf8)
        guard pathBytes.count < 104 else { throw CLIError.usage("socket path too long") }
        withUnsafeMutablePointer(to: &addr.sun_path) { buf in
            buf.withMemoryRebound(to: CChar.self, capacity: 104) { p in
                for (i, b) in pathBytes.enumerated() { p[i] = CChar(bitPattern: b) }
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(serverFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(serverFD)
            throw CLIError.usage("bind() failed: errno=\(errno) path=\(self.sockPath)")
        }
        chmod(self.sockPath, 0o600)
        guard listen(serverFD, 16) == 0 else {
            Darwin.close(serverFD)
            throw CLIError.usage("listen() failed")
        }
        print("daemon ready pid=\(ProcessInfo.processInfo.processIdentifier) sock=\(self.sockPath)")
        fflush(stdout)
        self.serverFD = serverFD
        while true {
            let clientFD = accept(serverFD, nil, nil)
            let stopping = stateQueue.sync { self.shouldStop }
            if stopping {
                if clientFD >= 0 { Darwin.close(clientFD) }
                break
            }
            if clientFD < 0 { continue }
            // M24b：并发处理；状态互斥下沉到 stateQueue / 每沙箱 opQueue。
            handlerGroup.enter()
            handlerQueue.async {
                autoreleasepool { self.handleClient(fd: clientFD) }
                self.handlerGroup.leave()
            }
        }
        // 在途响应写完再退出（有界等待：不让一个卡住的客户端拖死停机）。
        _ = handlerGroup.wait(timeout: .now() + 5)
        Darwin.close(serverFD)
        self.serverFD = -1
        // M24c：daemon 退出时清掉 socket 残留（GUI 侧 stale-sock workaround 的根因）。
        unlink(self.sockPath)
    }

    /// 唤醒阻塞在 accept 的主循环（shutdown 响应写完后调用）。
    private func wakeAcceptLoop() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(self.sockPath.utf8)
        guard pathBytes.count < 104 else { return }
        withUnsafeMutablePointer(to: &addr.sun_path) { buf in
            buf.withMemoryRebound(to: CChar.self, capacity: 104) { p in
                for (i, b) in pathBytes.enumerated() { p[i] = CChar(bitPattern: b) }
            }
        }
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private func handleClient(fd: Int32) {
        defer { Darwin.close(fd) }
        // M24b：请求读取有界——半开/不发数据的客户端只占一个 handler，10s 后被回收。
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.contains(0x0A) { break }
            if data.count > 1_048_576 { break }
        }
        // 唤醒连接 / 探活连接（connect 后立刻关闭）：无请求体，不回错误、不记日志。
        if data.isEmpty { return }
        var response: DaemonResponse
        var requestKind = "?"
        do {
            let request = try JSONDecoder().decode(DaemonRequest.self, from: data)
            requestKind = request.kind
            response = try self.dispatch(request)
        } catch {
            response = DaemonResponse(ok: false, error: "request rejected (kind=\(requestKind)): \(error)")
            fputs("daemon error (kind=\(requestKind)): \(error)\n", stderr)
        }
        if let out = try? JSONEncoder().encode(response) {
            _ = out.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    Darwin.write(fd, base, raw.count)
                    Darwin.write(fd, "\n", 1)
                }
            }
        }
        // M24c：shutdown 响应写完后才唤醒 accept 循环（保证客户端收到 ack 再退出）。
        if requestKind == "shutdown" && response.ok {
            self.wakeAcceptLoop()
        }
    }

    /// M24a：stateQueue 上构造决策快照。
    private func stateSnapshot() -> DaemonStateSnapshot {
        stateQueue.sync {
            DaemonStateSnapshot(
                sessionDomains: self.sessions.mapValues { $0.domainID.raw },
                ptySandbox: self.ptySessions.mapValues { $0.sandboxId },
                stalePtySessions: Set(self.ptySessions.filter { $0.value.isStale() }.keys),
                draining: self.draining
            )
        }
    }

    private func dispatch(_ request: DaemonRequest) throws -> DaemonResponse {
        // M24a：纯决策层先行拒绝（unknown kind / 缺参 / 域不匹配 / draining）；
        // 各 dispatch* 内保留自身 guard 防 TOCTOU。
        let route = try DaemonDecision.validate(request, state: self.stateSnapshot())
        switch route {
        case .run:
            return try self.dispatchRun(request)
        case .ps:
            return try self.dispatchPs(request)
        case .exec:
            return try self.dispatchExec(request)
        case .stop:
            return try self.dispatchStop(request)
        case .rm:
            return try self.dispatchRm(request)
        case .ptyOpen:
            return try self.dispatchPtyOpen(request)
        case .ptyInput:
            return try self.dispatchPtyInput(request)
        case .ptyPoll:
            return try self.dispatchPtyPoll(request)
        case .ptyClose:
            return try self.dispatchPtyClose(request)
        case .wsSync:
            return try self.dispatchWsSync(request)
        case .consoleLog:
            return try self.dispatchConsoleLog(request)
        case .stats:
            return try self.dispatchStats(request)
        case .suspend:
            return try self.dispatchSuspend(request)
        case .resume:
            return try self.dispatchResume(request)
        case .restart:
            return try self.dispatchRestart(request)
        case .shutdown:
            return self.dispatchShutdown()
        }
    }

    /// M24c：draining 闸 → 逐沙箱销毁 → 标记停机（accept 唤醒在响应写完后）。
    private func dispatchShutdown() -> DaemonResponse {
        stateQueue.sync { self.draining = true }
        // 在途 run 会在 boot-watch 轮询里看到 draining 并自行 destroy；等它们收尾。
        runGroup.wait()
        let doomed: [SandboxSession] = stateQueue.sync {
            let list = Array(self.sessions.values)
            self.sessions.removeAll()
            self.ptySessions.removeAll()
            return list
        }
        // M26b：先统一打断所有沙箱的在途 guest 操作，再逐个销毁（停机不再等 exec 超时）。
        for session in doomed { session.cancellation.cancel(reason: "daemon is shutting down") }
        for session in doomed {
            session.opQueue.sync {
                try? runBlocking { try await session.runtime.destroy(session.handle) }
            }
        }
        stateQueue.sync { self.shouldStop = true }
        return DaemonResponse(ok: true, pid: ProcessInfo.processInfo.processIdentifier)
    }

    /// M33：PTY 会话表项。`lastActivity` 用来识别「客户端已经不在了」的会话。
    struct PtyEntry {
        let session: VZRuntime.PtyStreamSession
        let sandboxId: String
        var lastActivity: Date

        /// 客户端在这段时间内没有任何 poll / input：视为已被遗弃（GUI 崩溃、CLI 被杀）。
        /// GUI 每 150ms poll 一次，所以这个阈值很宽松。
        static let staleAfter: TimeInterval = 5

        func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince(lastActivity) > Self.staleAfter }
    }

    private var ptySessions: [String: PtyEntry] = [:]

    /// stateQueue 上原子取出 pty 会话及其所属沙箱。
    private func ptyEntry(_ sid: String) -> (session: VZRuntime.PtyStreamSession, sandboxId: String, sandbox: SandboxSession?)? {
        stateQueue.sync {
            guard var entry = self.ptySessions[sid] else { return nil }
            // 任何 poll / input 都算活动。
            entry.lastActivity = Date()
            self.ptySessions[sid] = entry
            return (entry.session, entry.sandboxId, self.sessions[entry.sandboxId])
        }
    }

    /// M24c：在途 run 计数；shutdown 等它们归零，避免留下正在引导的 VM / COW 残留。
    private let runGroup = DispatchGroup()

    private func isDraining() -> Bool { stateQueue.sync { self.draining } }

    private func dispatchRun(_ request: DaemonRequest) throws -> DaemonResponse {
        runGroup.enter()
        defer { runGroup.leave() }
        guard let manifestPath = request.manifestPath else {
            throw CLIError.usage("run: --manifestPath required")
        }
        let manifestURL = URL(fileURLWithPath: manifestPath).standardizedFileURL
        let manifest = try DBXPOC.loadManifest(at: manifestURL)
        let unsignedAllowed = request.allowUnsignedManifest ?? false
        let plaintextAllowed = request.allowPlaintext ?? false
        let manifestDir = manifestURL.deletingLastPathComponent()
        let sandboxID = SandboxID.new()
        let audit = InMemoryAuditSink()
        let auditFlush: () -> Void = { }

        let runtime = try VZRuntime(
            cowRoot: request.cowRoot.map { URL(fileURLWithPath: $0) }
                ?? self.supportRoot.appendingPathComponent("cows", isDirectory: true),
            audit: audit,
            enableConsole: true,
            enableControlSocket: true,
            securityPolicy: plaintextAllowed ? ControlSecurityPolicy() : .strict,
            allowUnsignedManifest: unsignedAllowed
        )
        self.configureDomainsIfPresent(runtime: runtime)
        runtime.brokerConfigDir = manifestDir
        runtime.enableGraphics = request.graphics ?? false  // M14：virtio-gpu（对应额外 spike 配置）
        let sweep = try runtime.sweepOrphans()
        if !sweep.isEmpty {
            fputs("daemon: swept orphaned sandboxes=\(sweep.orphanedSandboxes.count)\n", stderr)
        }
        let workload = WorkloadSpec(
            entrypoint: ["/bin/sh"], args: [],
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/home/sandbox"],
            workingDirectory: "/", declaredPorts: [], uid: 65_534, gid: 65_534,
            volumes: [], resources: ResourceHints(cpuCount: request.cpus ?? 2, memoryMiB: request.memoryMiB ?? 2048)
        )
        // M23（INV-02）：创建时定域。显式 --domain 优先，否则用 domains.json 的 defaultDomain；
        // 两者都没有 → 拒绝（不静默落回 "default"）。
        let requestedDomain = (request.domain.flatMap { $0.isEmpty ? nil : CredentialDomainID($0) })
            ?? runtime.domainRegistry.defaultDomain
            ?? CredentialDomainID("default")
        let domain = try runtime.resolveDomain(requestedDomain)
        let create = SandboxCreateRequest(
            sandboxID: sandboxID, workspaceID: .new(), correlationID: UUID(),
            workloadDigest: "sha256:local-poc", workload: workload,
            guestAssets: manifest.asManifest,
            resources: ResourceHints(cpuCount: request.cpus ?? 2, memoryMiB: request.memoryMiB ?? 2048),
            networking: .none,
            domainID: domain.domainID
        )
        fputs("daemon create manifest=\(manifestPath) kernel=\(manifest.asManifest.kernelURL.lastPathComponent) digest=\(manifest.asManifest.manifestDigest.prefix(16)) gfx=\(runtime.enableGraphics)\n", stderr)
        let handle = try runBlocking { try await runtime.create(create) }
        do {
            _ = try runBlocking { try await runtime.start(handle) }
            fputs("daemon: VM started sandbox=\(sandboxID.description) waiting for bootstrap...\n", stderr)
            let watch = BootWatch(
                memoryMiB: request.memoryMiB ?? 2048,
                estimate: BootMemoryEstimate.measure(kernelURL: manifest.asManifest.kernelURL,
                                                     initrdURL: manifest.asManifest.initrdURL))
            try self.waitForRunning(runtime: runtime, handle: handle, sandboxID: sandboxID, boot: watch)
            let session = SandboxSession(
                id: sandboxID.description, runtime: runtime, handle: handle,
                manifestPath: manifestPath,
                runOptions: SandboxRunOptions(
                    manifestPath: manifestPath, cpus: request.cpus,
                    memoryMiB: request.memoryMiB, graphics: request.graphics,
                    cowRoot: request.cowRoot,
                    allowUnsignedManifest: request.allowUnsignedManifest,
                    allowPlaintext: request.allowPlaintext
                ),
                domainID: domain.domainID)
            // M24c：登记与 draining 判定在同一临界区——shutdown 之后不允许再长出新会话。
            let accepted: Bool = stateQueue.sync {
                if self.draining { return false }
                self.sessions[sandboxID.description] = session
                return true
            }
            guard accepted else {
                throw CLIError.usage("daemon draining: run aborted (shutdown in progress)")
            }
            return DaemonResponse(ok: true, sandboxId: session.id, state: "running")
        } catch {
            _ = try? runBlocking { try await runtime.destroy(handle) }
            auditFlush()
            throw error
        }
    }

    /// 引导等待上限。测试可经 `DBX_BOOT_TIMEOUT_SECONDS` 缩短（仅接受 5…600 的整数）。
    static func bootTimeoutSeconds(environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval {
        if let raw = environment["DBX_BOOT_TIMEOUT_SECONDS"], let v = Int(raw), (5...600).contains(v) {
            return TimeInterval(v)
        }
        return 90
    }

    /// 「静默引导」阈值。`DBX_BOOT_SILENCE_SECONDS`（2…120 的整数）可调，供慢宿主放宽。
    static func bootSilenceSeconds(environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval {
        if let raw = environment["DBX_BOOT_SILENCE_SECONDS"], let v = Int(raw), (2...120).contains(v) {
            return TimeInterval(v)
        }
        return 10
    }

    /// 首次引导的诊断上下文（resume 不带）。
    struct BootWatch {
        let memoryMiB: Int
        let estimate: BootMemoryEstimate?
    }

    /// 等待沙箱进入 running 且 bootstrap 已认证（run 与 resume 共用）。
    ///
    /// M26a：不再一律干等到超时——
    /// - VM 已 failed/stopped（VZ 报告 guest 停机/出错）→ 立即失败；
    /// - `boot`（仅首次引导）：console 出现已知的引导失败特征（OOM / 根挂载失败 / init 失败 /
    ///   panic）→ 立即失败并给出原因码 `DBX-BOOT-FAILED(<kind>)`；console 在静默阈值内一个字节
    ///   都没有 → `DBX-BOOT-FAILED(no-console-output)`，并在内存低于估算下限时点明；
    /// - 超时：错误里附带最后几行 console。
    /// console 只能让引导**更早失败**，readiness 仍只认已认证握手。
    /// resume 不看 console：缓冲里还留着上一段运行期间 guest 自己写的内容。
    private func waitForRunning(runtime: VZRuntime, handle: SandboxHandle, sandboxID: SandboxID,
                                boot: BootWatch? = nil,
                                isCancelled: () -> Bool = { false }) throws {
        let diagnoseConsole = boot != nil
        let silence = Self.bootSilenceSeconds()
        let timeout = Self.bootTimeoutSeconds()
        let deadline = Date().addingTimeInterval(timeout)
        var lastBootstrapPrinted = ""
        var lastConsoleScan = Date.distantPast
        let startedAt = Date()
        var sawConsole = false
        while Date() < deadline {
            // M24c：shutdown 期间尽快放弃引导（调用方负责 destroy）。
            if self.isDraining() {
                throw CLIError.usage("daemon draining: boot wait aborted (shutdown in progress)")
            }
            if isCancelled() {
                throw CLIError.usage("DBX-OP-CANCELLED: boot wait aborted (sandbox is being removed)")
            }
            let status = try runBlocking { try await runtime.inspect(handle) }
            let bstr = "\(status.state)/\(status.bootstrap)"
            if bstr != lastBootstrapPrinted {
                fputs("daemon boot-watch sandbox=\(sandboxID.description) status=\(bstr)\n", stderr)
                lastBootstrapPrinted = bstr
            }
            if status.state == .running && (status.bootstrap == .authenticated || status.bootstrap == .tlsAuthenticated) {
                return
            }
            if status.state == .failed || status.state == .stopped {
                let tail = BootDiagnostics.tailSummary(console: runtime.consoleTail(maxBytes: 4096))
                let known = diagnoseConsole ? BootDiagnostics.classify(console: runtime.consoleTail(maxBytes: 65536)) : nil
                if let known { throw CLIError.usage(known.message) }
                throw CLIError.usage("DBX-BOOT-FAILED(vm-\(status.state)): VM 在引导完成前停止 | console: \(tail)")
            }
            if diagnoseConsole && !sawConsole && !runtime.consoleTail(maxBytes: 1).isEmpty {
                sawConsole = true
                fputs("daemon boot-watch sandbox=\(sandboxID.description) first-console-ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))\n", stderr)
            }
            if let boot, !sawConsole,
               let silent = BootDiagnostics.diagnoseSilence(
                   elapsed: Date().timeIntervalSince(startedAt), silenceSeconds: silence,
                   memoryMiB: boot.memoryMiB, estimate: boot.estimate) {
                fputs("daemon boot-watch sandbox=\(sandboxID.description) diagnosed=\(silent.kind.rawValue)\n", stderr)
                throw CLIError.usage(silent.message)
            }
            if diagnoseConsole, Date().timeIntervalSince(lastConsoleScan) >= 0.5 {
                lastConsoleScan = Date()
                if let known = BootDiagnostics.classify(console: runtime.consoleTail(maxBytes: 65536)) {
                    fputs("daemon boot-watch sandbox=\(sandboxID.description) diagnosed=\(known.kind.rawValue)\n", stderr)
                    throw CLIError.usage(known.message)
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let tail = BootDiagnostics.tailSummary(console: runtime.consoleTail(maxBytes: 4096))
        throw CLIError.usage("DBX-BOOT-TIMEOUT: bootstrap did not reach running within \(Int(timeout))s | console: \(tail)")
    }

    private func dispatchPs(_ request: DaemonRequest) throws -> DaemonResponse {
        let live = stateQueue.sync { Array(self.sessions.values) }
        let infos: [SandboxInfo] = live.map {
            SandboxInfo(
                sandboxId: $0.id,
                state: ($0.runtime.cachedLifecycleState(of: $0.handle) ?? "running"),
                bootedAtUtc: ISO8601DateFormatter().string(from: $0.bootedAt),
                manifestPath: $0.manifestPath,
                uptimeSeconds: Int(Date().timeIntervalSince($0.bootedAt)),
                domain: $0.domainID.raw
            )
        }
        return DaemonResponse(ok: true, sandboxes: infos)
    }

    private func dispatchExec(_ request: DaemonRequest) throws -> DaemonResponse {
        let (session, sessionHandle) = try self.sessionFor(request, op: "exec")
        let sandboxId = session.id
        guard let argv = request.argv, !argv.isEmpty else {
            throw CLIError.usage("exec: argv required")
        }
        let controlRequest = ControlRequest(
            kind: .exec, argv: argv,
            env: request.env, cwd: request.cwd,
            timeoutSeconds: request.timeoutSeconds ?? 30
        )
        let response = try self.guestOp(session, op: "exec") {
            try await session.runtime.execute(session.handle, request: controlRequest)
        }
        return DaemonResponse(ok: true, sandboxId: sandboxId, state: "running",
                              exitCode: response.exitCode, stdout: response.stdout, stderr: response.stderr)
    }


    /// M26b：在沙箱 opQueue 上执行一个可被拆除类操作打断的 guest 操作。
    private func guestOp<T>(_ session: SandboxSession, op: String,
                            _ body: @Sendable @escaping () async throws -> T) throws -> T {
        try session.opQueue.sync {
            try session.cancellation.checkNotCancelled(op: op)
            do {
                return try runBlocking(cancellation: session.cancellation, body)
            } catch is CancellationError {
                throw session.cancellation.cancelledError(op: op)
            } catch {
                // VM 被并发拆除时，底层往往先报 "not found"/通道错误；对调用方统一成取消。
                if session.cancellation.isCancelled { throw session.cancellation.cancelledError(op: op) }
                throw error
            }
        }
    }

    /// M23（INV-02）：查找会话并强制域比对。
    ///
    /// 规则：
    /// - 请求声明了 `domain` → 必须与会话域一致（跨域一律拒绝）；
    /// - 请求未声明 → 允许（CLI/GUI 单用户场景），但仍返回绑定了会话域的 handle，
    ///   由 `VZRuntime.require` 再做一层校验。
    private func sessionFor(_ request: DaemonRequest, op: String) throws -> (SandboxSession, SandboxHandle) {
        let found: SandboxSession? = stateQueue.sync {
            request.sandboxId.flatMap { self.sessions[$0] }
        }
        guard let session = found else {
            throw CLIError.usage("\(op): sandbox not found: \(request.sandboxId ?? "nil")")
        }
        if let declaredRaw = request.domain, !declaredRaw.isEmpty {
            let declared = CredentialDomainID(declaredRaw)
            guard declared == session.domainID else {
                throw CLIError.usage("DBX-DOMAIN-SESSION-MISMATCH: \(op) 请求域 \(declaredRaw) 与沙箱域 \(session.domainID) 不一致")
            }
        }
        let handle = SandboxHandle(sandboxID: session.handle.sandboxID,
                                   bootID: session.handle.bootID,
                                   domainID: session.domainID)
        return (session, handle)
    }

    /// M20：暂停并加密落盘（INV-10）。
    private func dispatchSuspend(_ request: DaemonRequest) throws -> DaemonResponse {
        let (session, sessionHandle) = try self.sessionFor(request, op: "suspend")
        let sandboxId = session.id
        // M33：suspend 之前把该沙箱的 pty 在 **guest 里**关掉。此前只删宿主侧的表项，guest 里的 shell
        // 被一起冻进快照，resume 之后它仍占着唯一的 pty 槽位，终端再也打不开。
        let doomedPtys: [PtyEntry] = stateQueue.sync {
            let hits = self.ptySessions.filter { $0.value.sandboxId == sandboxId }
            for sid in hits.keys { self.ptySessions.removeValue(forKey: sid) }
            return Array(hits.values)
        }
        try session.opQueue.sync {
            for entry in doomedPtys {
                _ = try? runBlocking { try await session.runtime.ptyCloseSession(session.handle, session: entry.session) }
            }
            try runBlocking { try await session.runtime.suspend(session.handle) }
        }
        return DaemonResponse(ok: true, sandboxId: sandboxId, state: "suspended")
    }

    /// M20：从加密快照恢复（三道闸 fail-closed）。
    private func dispatchResume(_ request: DaemonRequest) throws -> DaemonResponse {
        let (session, sessionHandle) = try self.sessionFor(request, op: "resume")
        let sandboxId = session.id
        try session.opQueue.sync {
            try session.cancellation.checkNotCancelled(op: "resume")
            do {
                _ = try runBlocking { try await session.runtime.resume(session.handle) }
            } catch {
                // M27：锁屏期间 VZ 拒绝 restore，原始报错只有 "permission denied"。只改写消息，不改变行为。
                if let explained = ResumeDiagnostics.explain(errorDescription: "\(error)",
                                                             screenLocked: HostSession.isScreenLocked()) {
                    throw CLIError.usage(explained)
                }
                throw error
            }
            try self.waitForRunning(runtime: session.runtime, handle: session.handle,
                                    sandboxID: session.handle.sandboxID,
                                    isCancelled: { session.cancellation.isCancelled })
        }
        return DaemonResponse(ok: true, sandboxId: sandboxId, state: "running")
    }

    /// M21：资源统计。观测面 fail-soft：失败时 stats.statsError 有值但不抛错。
    private func dispatchStats(_ request: DaemonRequest) throws -> DaemonResponse {
        let (session, sessionHandle) = try self.sessionFor(request, op: "stats")
        let sandboxId = session.id
        do {
            let stats = try self.guestOp(session, op: "stats") {
                try await session.runtime.stats(session.handle)
            }
            return DaemonResponse(ok: true, sandboxId: sandboxId, state: "running", stats: stats)
        } catch {
            let soft = SandboxStats(cpuUsageUsec: nil, memoryCurrentBytes: nil, memoryMaxBytes: nil,
                                    pidsCurrent: nil, pidsMax: nil,
                                    statsError: error.localizedDescription)
            return DaemonResponse(ok: true, sandboxId: sandboxId, state: "running", stats: soft)
        }
    }

    /// M16:consoleLog——返回 guest serial 的母/落到界 健康/联系 read 的置或。不构 Staging。
    private func dispatchConsoleLog(_ request: DaemonRequest) throws -> DaemonResponse {
        let (session, sessionHandle) = try self.sessionFor(request, op: "consoleLog")
        let sandboxId = session.id
        let maxBytes = request.waitMillis ?? 16384
        let data = session.runtime.consoleTail(maxBytes: maxBytes)
        return DaemonResponse(ok: true, outputHex: data.map { String(format: "%02x", $0) }.joined(),
                              sandboxId: sandboxId, state: "running")
    }

    /// M16:restart——stop+rm+按保留参数重建沙箱（新 sandboxId）。
    private func dispatchRestart(_ request: DaemonRequest) throws -> DaemonResponse {
        let (session, sessionHandle) = try self.sessionFor(request, op: "restart")
        let sandboxId = session.id
        let opts = session.runOptions
        // 强 rm（践可精确零 tryStop 开筛）
        var rmReq = DaemonRequest(kind: "rm")
        rmReq.sandboxId = sandboxId
        rmReq.force = true
        _ = try? self.dispatchRm(rmReq)
        var runReq = DaemonRequest(kind: "run")
        runReq.manifestPath = opts.manifestPath
        runReq.cpus = opts.cpus
        runReq.memoryMiB = opts.memoryMiB
        runReq.graphics = opts.graphics
        runReq.cowRoot = opts.cowRoot
        runReq.allowUnsignedManifest = opts.allowUnsignedManifest
        runReq.allowPlaintext = opts.allowPlaintext
        return try self.dispatchRun(runReq)
    }

    private func dispatchPtyOpen(_ request: DaemonRequest) throws -> DaemonResponse {
        let (session, sessionHandle) = try self.sessionFor(request, op: "ptyOpen")
        let sandboxId = session.id
        // 单沙箱一次只能一个流式 pty 会话（协议 ptyId=0）
        guard let argv = request.argv, !argv.isEmpty else {
            throw CLIError.usage("ptyOpen: argv required")
        }
        // opQueue 内「查重 → 打开 → 登记」：同沙箱并发 ptyOpen 只会成功一个。
        let sid: String = try session.opQueue.sync {
            // 已有会话：还活着（客户端在 poll）就拒绝；已被遗弃（客户端没关就消失了）就先在 guest 里
            // 关掉它再开新的——否则一次 GUI 崩溃会让这个沙箱的终端永久打不开。
            let existing: [(sid: String, entry: PtyEntry)] = stateQueue.sync {
                self.ptySessions.filter { $0.value.sandboxId == sandboxId }.map { ($0.key, $0.value) }
            }
            if existing.contains(where: { !$0.entry.isStale() }) {
                throw CLIError.usage("ptyOpen: sandbox already has an active pty session")
            }
            for stale in existing {
                fputs("daemon: preempting abandoned pty session \(stale.sid) on sandbox \(sandboxId)\n", stderr)
                _ = try? runBlocking { try await session.runtime.ptyCloseSession(session.handle, session: stale.entry.session) }
                _ = stateQueue.sync { self.ptySessions.removeValue(forKey: stale.sid) }
            }
            let opened = try runBlocking { try await session.runtime.ptyOpenSession(session.handle, argv: argv) }
            let sid = opened.requestID.uuidString
            stateQueue.sync { self.ptySessions[sid] = PtyEntry(session: opened, sandboxId: sandboxId, lastActivity: Date()) }
            return sid
        }
        return DaemonResponse(ok: true, ptySessionId: sid, running: true, sandboxId: sandboxId, state: "running")
    }

    private func dispatchPtyInput(_ request: DaemonRequest) throws -> DaemonResponse {
        guard let sid = request.ptySessionId, let entry = self.ptyEntry(sid) else {
            throw CLIError.usage("ptyInput: pty session not found")
        }
        guard let sandbox = entry.sandbox else {
            throw CLIError.usage("ptyInput: sandbox no longer alive")
        }
        let hex = request.dataHex ?? ""
        var bytes = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let pair = hex[i..<hex.index(i, offsetBy: 2)]
            if let b = UInt8(pair, radix: 16) { bytes.append(b) }
            i = hex.index(i, offsetBy: 2)
        }
        let input = bytes
        // pty 读写不进 opQueue：流式会话必须能与长 exec 并行（VZRuntime 内部自有 queue 纪律）。
        let ptySession = entry.session
        try runBlocking { try await sandbox.runtime.ptyWriteSession(sandbox.handle, session: ptySession, data: input) }
        return DaemonResponse(ok: true)
    }

    private func dispatchPtyPoll(_ request: DaemonRequest) throws -> DaemonResponse {
        guard let sid = request.ptySessionId, let entry = self.ptyEntry(sid) else {
            throw CLIError.usage("ptyPoll: pty session not found")
        }
        guard let sandbox = entry.sandbox else {
            _ = stateQueue.sync { self.ptySessions.removeValue(forKey: sid) }
            throw CLIError.usage("ptyPoll: sandbox no longer alive")
        }
        let ptySession = entry.session
        let waitMillis = request.waitMillis ?? 200
        let result = try runBlocking {
            try await sandbox.runtime.ptyPollSession(sandbox.handle, session: ptySession, waitMillis: waitMillis)
        }
        var response = DaemonResponse(ok: true, ptySessionId: sid, running: result.running, sandboxId: entry.sandboxId, exitCode: result.exitCode)
        response.outputHex = result.output.map { String(format: "%02x", $0) }.joined()
        if !result.running { _ = stateQueue.sync { self.ptySessions.removeValue(forKey: sid) } }
        return response
    }

    private func dispatchPtyClose(_ request: DaemonRequest) throws -> DaemonResponse {
        let removed: PtyEntry? = stateQueue.sync {
            guard let sid = request.ptySessionId else { return nil }
            return self.ptySessions.removeValue(forKey: sid)
        }
        guard let entry = removed else { throw CLIError.usage("ptyClose: pty session not found") }
        // M33：真正在 guest 里关闭（杀掉 shell、释放唯一的 pty 槽位）。此前这里只删表项，
        // 注释写着「客端进程不可控制关闭」——其实协议和 guest 一直支持 ptyClose，只是宿主从不发送。
        // 尽力而为：沙箱已停 / 已移除时关闭失败不算错（会话本来就没了）。
        var exited = false
        if let sandbox = stateQueue.sync(execute: { self.sessions[entry.sandboxId] }) {
            // 必须与 ptyOpen 在同一个串行队列上：关闭过程会清掉 ptyId=0 的遗留事件，若与紧接着的
            // ptyOpen 并发，就会把**新会话**的输出也吃掉（GUI 关掉终端立刻再开时实际发生过）。
            exited = sandbox.opQueue.sync {
                (try? runBlocking {
                    try await sandbox.runtime.ptyCloseSession(sandbox.handle, session: entry.session)
                }) ?? false
            }
        }
        return DaemonResponse(ok: true, running: false, sandboxId: entry.sandboxId, state: exited ? "closed" : "detached")
    }

    private func dispatchWsSync(_ request: DaemonRequest) throws -> DaemonResponse {
        let (session, sessionHandle) = try self.sessionFor(request, op: "wsSync")
        let sandboxId = session.id
        guard let workspacePath = request.workspaceDir else {
            throw CLIError.usage("wsSync: workspaceDir required")
        }
        let root = URL(fileURLWithPath: workspacePath).standardizedFileURL
        let snapshot = try WorkspaceSyncService.buildSnapshot(root: root)
        let ack = try self.guestOp(session, op: "wsSync") {
            try await session.runtime.pushWorkspace(session.handle, snapshot: snapshot)
        }
        var response = DaemonResponse(ok: true, sandboxId: sandboxId, state: "running")
        response.stdout = "ws-sync ok wsId=\(ack.wsId) files=\(snapshot.files.count) bytes=\(snapshot.totalBytes)"
        return response
    }

    private func dispatchStop(_ request: DaemonRequest) throws -> DaemonResponse {
        let (session, sessionHandle) = try self.sessionFor(request, op: "stop")
        let sandboxId = session.id
        // M26b：先打断在途 guest 操作，stop 不再等长 exec 跑完。
        let stopReason = "sandbox is being stopped"
        session.cancellation.cancel(reason: stopReason)
        defer { session.cancellation.reset(ifReason: stopReason) }
        try session.opQueue.sync {
            try runBlocking { try await session.runtime.stop(session.handle) }
        }
        return DaemonResponse(ok: true, sandboxId: sandboxId, state: "stopped")
    }

    private func dispatchRm(_ request: DaemonRequest) throws -> DaemonResponse {
        guard let sandboxId = request.sandboxId else { throw CLIError.usage("rm: sandboxId required") }
        let force = request.force ?? false
        // M27：经 sessionFor 做域比对（effect 层自己的 guard，不只依赖决策表）。
        let (session, _) = try self.sessionFor(request, op: "rm")
        // M26b：--force 表示「无论在做什么都拆掉」→ 先打断在途 guest 操作。
        // 非 force 的 rm 对 running 沙箱本来就会被拒绝，不能因为一次注定失败的 rm 打断 exec。
        if force { session.cancellation.cancel(reason: "sandbox is being removed") }
        try session.opQueue.sync {
            // 并发 rm 去重：排到队首时会话可能已被另一个 rm 移除。
            let stillThere = stateQueue.sync { self.sessions[sandboxId] === session }
            guard stillThere else { throw CLIError.usage("rm: sandbox not found: \(sandboxId)") }
            if !force {
                let status = try? runBlocking { try await session.runtime.inspect(session.handle) }
                if status?.state == .running { throw CLIError.usage("rm: sandbox is running; use --force") }
            }
            try runBlocking { try await session.runtime.destroy(session.handle) }
            stateQueue.sync {
                self.sessions.removeValue(forKey: sandboxId)
                // 沙箱没了，其 pty 会话一并失效（此前会残留到下一次 ptyPoll）。
                for (sid, entry) in self.ptySessions where entry.sandboxId == sandboxId {
                    self.ptySessions.removeValue(forKey: sid)
                }
            }
        }
        return DaemonResponse(ok: true, sandboxId: sandboxId, state: "removed")
    }
}

/// runBlocking：将 async 环境包会同步 queue 所用 semaphore，避免 daemon 嵌合 loop。
private final class RunBlockingBox<T>: @unchecked Sendable { var result: Result<T, Error>? }
func runBlocking<T>(cancellation: OpCancellation? = nil,
                    _ body: @Sendable @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = RunBlockingBox<T>()
    let task = Task { @Sendable in
        do {
            let value = try await body()
            box.result = .success(value)
        }            catch {
            box.result = .failure(error)
        }
        sem.signal()
    }
    // M26b：把 Task 的取消句柄交给令牌；body 内的 Task.sleep / checkCancellation 会据此抛出。
    cancellation?.register { task.cancel() }
    sem.wait()
    cancellation?.unregister()
    return try box.result!.get()
}

enum DaemonClient {
    static func send(request: DaemonRequest, sockPath: String? = nil) throws -> DaemonResponse {
        let path = sockPath ?? SandboxDaemon.defaultSockPath()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError.usage("socket() failed errno=\(errno)") }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < 104 else { throw CLIError.usage("socket path too long") }
        withUnsafeMutablePointer(to: &addr.sun_path) { buf in
            buf.withMemoryRebound(to: CChar.self, capacity: 104) { p in
                for (i, b) in pathBytes.enumerated() { p[i] = CChar(bitPattern: b) }
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            throw CLIError.usage("cannot connect to daemon at \(path): errno=\(errno) (is `dbx-poc daemon` running?)")
        }
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if n <= 0 { throw CLIError.usage("write failed errno=\(errno)") }
                written += n
            }
        }
        var responseData = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            responseData.append(contentsOf: buf[0..<n])
            if responseData.contains(0x0A) { break }
            if responseData.count > 8_388_608 { break }
        }
        guard let response = try? JSONDecoder().decode(DaemonResponse.self, from: responseData) else {
            throw CLIError.usage("invalid daemon response")
        }
        if !response.ok {
            throw CLIError.usage(response.error ?? "daemon rejected request")
        }
        return response
    }
}



extension DBXPOC {
    static func loadManifestFile(at url: URL) throws -> ManifestFile {
        var manifest = try JSONDecoder().decode(ManifestFile.self, from: Data(contentsOf: url))
        manifest.resolveRelativeURLs(from: url.deletingLastPathComponent())
        return manifest
    }
}
