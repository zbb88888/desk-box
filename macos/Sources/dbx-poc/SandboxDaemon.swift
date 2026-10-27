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
}

struct SandboxInfo: Codable {
    let sandboxId: String
    let state: String
    let bootedAtUtc: String
    let manifestPath: String
    var uptimeSeconds: Int? = nil
    var workspaceId: String? = nil
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
    /// M16：保留 run 参数以便 `restart` 恢复工作流。
    let runOptions: SandboxRunOptions
    init(id: String, runtime: VZRuntime, handle: SandboxHandle, manifestPath: String, runOptions: SandboxRunOptions) {
        self.id = id
        self.runtime = runtime
        self.handle = handle
        self.manifestPath = manifestPath
        self.runOptions = runOptions
        self.bootedAt = Date()
    }
}

/// 序列化所有请求，确保 VZ queue 纪律联席会议在单队列一致。
final class SandboxDaemon {
    private let sockPath: String
    private var sessions: [String: SandboxSession] = [:]
    private let queue = DispatchQueue(label: "deskbox.daemon.queue")
    private var shouldStop = false

    static func defaultSockPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("dbxd.sock").path
    }

    init(sockPath: String) {
        self.sockPath = sockPath
    }

    func serve() throws -> Never {
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
        while !self.shouldStop {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD < 0 { continue }
            // 串行调查处理（单请求/连接；响应后关闭）
            queue.sync {
                autoreleasepool { self.handleClient(fd: clientFD) }
            }
        }
        Foundation.exit(0)
    }

    private func handleClient(fd: Int32) {
        defer { Darwin.close(fd) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.contains(0x0A) { break }
            if data.count > 1_048_576 { break }
        }
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
    }

    private func dispatch(_ request: DaemonRequest) throws -> DaemonResponse {
        switch request.kind {
        case "run":
            return try self.dispatchRun(request)
        case "ps":
            return try self.dispatchPs(request)
        case "exec":
            return try self.dispatchExec(request)
        case "stop":
            return try self.dispatchStop(request)
        case "rm":
            return try self.dispatchRm(request)
                case "ptyOpen":
            return try self.dispatchPtyOpen(request)
        case "ptyInput":
            return try self.dispatchPtyInput(request)
        case "ptyPoll":
            return try self.dispatchPtyPoll(request)
        case "ptyClose":
            return try self.dispatchPtyClose(request)
        case "wsSync":
            return try self.dispatchWsSync(request)
        case "consoleLog":
            return try self.dispatchConsoleLog(request)
        case "restart":
            return try self.dispatchRestart(request)
        case "shutdown":
            for (_, session) in self.sessions {
                try? runBlocking { try await session.runtime.destroy(session.handle) }
            }
            self.sessions.removeAll()
            self.shouldStop = true
            return DaemonResponse(ok: true, pid: ProcessInfo.processInfo.processIdentifier)
        default:
            throw CLIError.usage("unknown kind=\(request.kind)")
        }
    }

    private var ptySessions: [String: (session: VZRuntime.PtyStreamSession, sandboxId: String)] = [:]

    private func dispatchRun(_ request: DaemonRequest) throws -> DaemonResponse {
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
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("DeskBox/cows", isDirectory: true),
            audit: audit,
            enableConsole: true,
            enableControlSocket: true,
            securityPolicy: plaintextAllowed ? ControlSecurityPolicy() : .strict,
            allowUnsignedManifest: unsignedAllowed
        )
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
        let create = SandboxCreateRequest(
            sandboxID: sandboxID, workspaceID: .new(), correlationID: UUID(),
            workloadDigest: "sha256:local-poc", workload: workload,
            guestAssets: manifest.asManifest,
            resources: ResourceHints(cpuCount: request.cpus ?? 2, memoryMiB: request.memoryMiB ?? 2048),
            networking: .none
        )
        fputs("daemon create manifest=\(manifestPath) kernel=\(manifest.asManifest.kernelURL.lastPathComponent) digest=\(manifest.asManifest.manifestDigest.prefix(16)) gfx=\(runtime.enableGraphics)\n", stderr)
        let handle = try runBlocking { try await runtime.create(create) }
        do {
            _ = try runBlocking { try await runtime.start(handle) }
            fputs("daemon: VM started sandbox=\(sandboxID.description) waiting for bootstrap...\n", stderr)
            let deadline = Date().addingTimeInterval(90)
            var lastBootstrapPrinted = ""
            while Date() < deadline {
                let status = try runBlocking { try await runtime.inspect(handle) }
                let bstr = "\(status.state)/\(status.bootstrap)"
                if bstr != lastBootstrapPrinted {
                    fputs("daemon boot-watch sandbox=\(sandboxID.description) status=\(bstr)\n", stderr)
                    lastBootstrapPrinted = bstr
                }
                if status.state == .running && (status.bootstrap == .authenticated || status.bootstrap == .tlsAuthenticated) {
                    let session = SandboxSession(
                        id: sandboxID.description, runtime: runtime, handle: handle,
                        manifestPath: manifestPath,
                        runOptions: SandboxRunOptions(
                            manifestPath: manifestPath, cpus: request.cpus,
                            memoryMiB: request.memoryMiB, graphics: request.graphics,
                            cowRoot: request.cowRoot,
                            allowUnsignedManifest: request.allowUnsignedManifest,
                            allowPlaintext: request.allowPlaintext
                        ))
                    self.sessions[sandboxID.description] = session
                    return DaemonResponse(ok: true, sandboxId: session.id, state: "running")
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            throw CLIError.usage("run: bootstrap did not reach running within 90s")
        } catch {
            _ = try? runBlocking { try await runtime.destroy(handle) }
            auditFlush()
            throw error
        }
    }

    private func dispatchPs(_ request: DaemonRequest) throws -> DaemonResponse {
        let infos: [SandboxInfo] = sessions.values.map {
            SandboxInfo(
                sandboxId: $0.id,
                state: "running",
                bootedAtUtc: ISO8601DateFormatter().string(from: $0.bootedAt),
                manifestPath: $0.manifestPath,
                uptimeSeconds: Int(Date().timeIntervalSince($0.bootedAt))
            )
        }
        return DaemonResponse(ok: true, sandboxes: infos)
    }

    private func dispatchExec(_ request: DaemonRequest) throws -> DaemonResponse {
        guard let sandboxId = request.sandboxId, let session = self.sessions[sandboxId] else {
            throw CLIError.usage("exec: sandbox not found or not running: \(request.sandboxId ?? "nil")")
        }
        guard let argv = request.argv, !argv.isEmpty else {
            throw CLIError.usage("exec: argv required")
        }
        let controlRequest = ControlRequest(
            kind: .exec, argv: argv,
            env: request.env, cwd: request.cwd,
            timeoutSeconds: request.timeoutSeconds ?? 30
        )
        let response = try runBlocking { try await session.runtime.execute(session.handle, request: controlRequest) }
        return DaemonResponse(ok: true, sandboxId: sandboxId, state: "running",
                              exitCode: response.exitCode, stdout: response.stdout, stderr: response.stderr)
    }


    /// M16:consoleLog——返回 guest serial 的母/落到界 健康/联系 read 的置或。不构 Staging。
    private func dispatchConsoleLog(_ request: DaemonRequest) throws -> DaemonResponse {
        guard let sandboxId = request.sandboxId, let session = self.sessions[sandboxId] else {
            throw CLIError.usage("consoleLog: sandbox not found: \(request.sandboxId ?? "nil")")
        }
        let maxBytes = request.waitMillis ?? 16384
        let data = session.runtime.consoleTail(maxBytes: maxBytes)
        return DaemonResponse(ok: true, outputHex: data.map { String(format: "%02x", $0) }.joined(),
                              sandboxId: sandboxId, state: "running")
    }

    /// M16:restart——stop+rm+按保留参数重建沙箱（新 sandboxId）。
    private func dispatchRestart(_ request: DaemonRequest) throws -> DaemonResponse {
        guard let sandboxId = request.sandboxId, let session = self.sessions[sandboxId] else {
            throw CLIError.usage("restart: sandbox not found: \(request.sandboxId ?? "nil")")
        }
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
        guard let sandboxId = request.sandboxId, let session = self.sessions[sandboxId] else {
            throw CLIError.usage("ptyOpen: sandbox not found: \(request.sandboxId ?? "nil")")
        }
        // 单沙箱一次只能一个流式 pty 会话（协议 ptyId=0）
        if ptySessions.values.contains(where: { $0.sandboxId == sandboxId }) {
            throw CLIError.usage("ptyOpen: sandbox already has an active pty session")
        }
        guard let argv = request.argv, !argv.isEmpty else {
            throw CLIError.usage("ptyOpen: argv required")
        }
        let opened = try runBlocking { try await session.runtime.ptyOpenSession(session.handle, argv: argv) }
        let sid = opened.requestID.uuidString
        self.ptySessions[sid] = (opened, sandboxId)
        return DaemonResponse(ok: true, ptySessionId: sid, running: true, sandboxId: sandboxId, state: "running")
    }

    private func dispatchPtyInput(_ request: DaemonRequest) throws -> DaemonResponse {
        guard let sid = request.ptySessionId, let entry = self.ptySessions[sid] else {
            throw CLIError.usage("ptyInput: pty session not found")
        }
        guard let sandbox = self.sessions[entry.sandboxId] else {
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
        try runBlocking { try await sandbox.runtime.ptyWriteSession(sandbox.handle, session: entry.session, data: input) }
        return DaemonResponse(ok: true)
    }

    private func dispatchPtyPoll(_ request: DaemonRequest) throws -> DaemonResponse {
        guard let sid = request.ptySessionId, let entry = self.ptySessions[sid] else {
            throw CLIError.usage("ptyPoll: pty session not found")
        }
        guard let sandbox = self.sessions[entry.sandboxId] else {
            self.ptySessions.removeValue(forKey: sid)
            throw CLIError.usage("ptyPoll: sandbox no longer alive")
        }
        let result = try runBlocking {
            try await sandbox.runtime.ptyPollSession(sandbox.handle, session: entry.session, waitMillis: request.waitMillis ?? 200)
        }
        var response = DaemonResponse(ok: true, ptySessionId: sid, running: result.running, sandboxId: entry.sandboxId, exitCode: result.exitCode)
        response.outputHex = result.output.map { String(format: "%02x", $0) }.joined()
        if !result.running { self.ptySessions.removeValue(forKey: sid) }
        return response
    }

    private func dispatchPtyClose(_ request: DaemonRequest) throws -> DaemonResponse {
        guard let sid = request.ptySessionId, let _ = self.ptySessions[sid] else {
            throw CLIError.usage("ptyClose: pty session not found")
        }
        self.ptySessions.removeValue(forKey: sid)
        // 客端进程不可控制关闭——发 exit 信号让其自然退出；后续无态扔清
        return DaemonResponse(ok: true, running: false, sandboxId: request.sandboxId)
    }

    private func dispatchWsSync(_ request: DaemonRequest) throws -> DaemonResponse {
        guard let sandboxId = request.sandboxId, let session = self.sessions[sandboxId] else {
            throw CLIError.usage("wsSync: sandbox not found: \(request.sandboxId ?? "nil")")
        }
        guard let workspacePath = request.workspaceDir else {
            throw CLIError.usage("wsSync: workspaceDir required")
        }
        let root = URL(fileURLWithPath: workspacePath).standardizedFileURL
        let snapshot = try WorkspaceSyncService.buildSnapshot(root: root)
        let ack = try runBlocking { try await session.runtime.pushWorkspace(session.handle, snapshot: snapshot) }
        var response = DaemonResponse(ok: true, sandboxId: sandboxId, state: "running")
        response.stdout = "ws-sync ok wsId=\(ack.wsId) files=\(snapshot.files.count) bytes=\(snapshot.totalBytes)"
        return response
    }

    private func dispatchStop(_ request: DaemonRequest) throws -> DaemonResponse {
        guard let sandboxId = request.sandboxId, let session = self.sessions[sandboxId] else {
            throw CLIError.usage("stop: sandbox not found: \(request.sandboxId ?? "nil")")
        }
        try runBlocking { try await session.runtime.stop(session.handle) }
        return DaemonResponse(ok: true, sandboxId: sandboxId, state: "stopped")
    }

    private func dispatchRm(_ request: DaemonRequest) throws -> DaemonResponse {
        guard let sandboxId = request.sandboxId else { throw CLIError.usage("rm: sandboxId required") }
        let force = request.force ?? false
        guard let session = self.sessions[sandboxId] else {
            throw CLIError.usage("rm: sandbox not found: \(sandboxId)")
        }
        if !force {
            let status = try? runBlocking { try await session.runtime.inspect(session.handle) }
            if status?.state == .running { throw CLIError.usage("rm: sandbox is running; use --force") }
        }
        try runBlocking { try await session.runtime.destroy(session.handle) }
        self.sessions.removeValue(forKey: sandboxId)
        return DaemonResponse(ok: true, sandboxId: sandboxId, state: "removed")
    }
}

/// runBlocking：将 async 环境包会同步 queue 所用 semaphore，避免 daemon 嵌合 loop。
private final class RunBlockingBox<T>: @unchecked Sendable { var result: Result<T, Error>? }
func runBlocking<T>(_ body: @Sendable @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = RunBlockingBox<T>()
    Task { @Sendable in
        do {
            let value = try await body()
            box.result = .success(value)
        }            catch {
            box.result = .failure(error)
        }
        sem.signal()
    }
    sem.wait()
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
