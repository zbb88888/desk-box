import Darwin
import DeskBoxVZ
import Foundation

struct DaemonRequest: Codable, Sendable {
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
}

struct DaemonResponse: Codable, Sendable {
    let ok: Bool
    var ptySessionId: String? = nil
    var outputHex: String? = nil
    var stats: SandboxStats? = nil
    var running: Bool? = nil
    var error: String? = nil
    var sandboxId: String? = nil
    var state: String? = nil
    var exitCode: Int32? = nil
    var stdout: String? = nil
    var stderr: String? = nil
    var notices: [String]? = nil
    var cancelled: Bool? = nil
    /// M51：daemon 的构建修订号等（`info` 请求）。
    var info: DaemonInfo? = nil
    var sandboxes: [SandboxInfo]? = nil
    var pid: Int32? = nil
}

/// M21：guest 资源采样（诊断用途）。
struct SandboxStats: Codable, Sendable {
    var cpuUsageUsec: UInt64? = nil
    var memoryCurrentBytes: UInt64? = nil
    var memoryMaxBytes: UInt64? = nil
    var pidsCurrent: Int? = nil
    var pidsMax: Int? = nil
    var activeExecGroups: Int? = nil
    var statsError: String? = nil
    // M52：guest 上报的能力字段（旧 guest 不上报）。
    var workspaceSyncVersion: Int? = nil
    var execOutputVersion: Int? = nil
    var execCancelVersion: Int? = nil
    var brokerVersion: Int? = nil
    var childFdsVersion: Int? = nil
    var testFaults: Bool? = nil
}

struct SandboxInfo: Codable, Identifiable, Sendable {
    var id: String { sandboxId }
    let sandboxId: String
    let state: String
    let bootedAtUtc: String
    let manifestPath: String
    var uptimeSeconds: Int? = nil
    var workspaceId: String? = nil
    /// M23（INV-02）：凭据域。
    var domain: String? = nil
    /// M45：状态的补充说明（failed 的原因）。
    var stateDetail: String? = nil
}

enum DaemonClientError: LocalizedError {
    case socketFailed(Int32)
    case connectFailed(String)
    case weird(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .socketFailed(let e): return "socket() errno=\(e)"
        case .connectFailed(let s): return "connect: \(s)"
        case .weird(let s): return s
        case .rejected(let s): return "daemon: \(s)"
        }
    }
}

/// 与 M12 dbx-poc daemon 使用同一 JSON-lines 协议（chmod 600 的本地 UNIX socket）。
struct DaemonSocketClient: Sendable {
    let sockPath: String

    static func defaultSockPath() -> String {
        // M30：与 daemon/CLI 同一解析点（含 DBX_SUPPORT_ROOT；非法值直接 exit 2，不回落默认目录）。
        // GUI 拉起的 daemon 继承同一环境变量，因此两边看到的是同一个 socket。
        DeskBoxPaths.daemonSocketURL.path
    }

    func probing() -> Bool {
        let response = try? self.send(DaemonRequest(kind: "ps"), timeoutSec: 2)
        return response?.ok ?? false
    }

    func send(_ request: DaemonRequest, timeoutSec: Int = 30) throws -> DaemonResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonClientError.socketFailed(errno) }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(self.sockPath.utf8)
        guard pathBytes.count < 104 else { throw DaemonClientError.weird("socket path too long") }
        withUnsafeMutablePointer(to: &addr.sun_path) { buf in
            buf.withMemoryRebound(to: CChar.self, capacity: 104) { p in
                for (i, b) in pathBytes.enumerated() { p[i] = CChar(bitPattern: b) }
            }
        }
        let connResult = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connResult == 0 else {
            throw DaemonClientError.connectFailed("\(self.sockPath) errno=\(errno) (guard is daemon running)")
        }
        // timeout on read
        var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if n <= 0 { throw DaemonClientError.weird("write errno=\(errno)") }
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
            if responseData.count > 8_388_608 { throw DaemonClientError.weird("response too large") }
        }
        guard let response = try? JSONDecoder().decode(DaemonResponse.self, from: responseData) else {
            throw DaemonClientError.weird("invalid response")
        }
        if !response.ok {
            throw DaemonClientError.rejected(response.error ?? "unknown error")
        }
        return response
    }
}

/// daemon 进程管理（GUI 启动的 `dbx-poc daemon`）。
final class DaemonProcessManager: ObservableObject, @unchecked Sendable {
    @Published var status: Status = .unknown
    @Published var lastError: String? = nil
    @Published var startedAt: String? = nil

    enum Status: String {
        case unknown = "unknown"
        case stopped = "stopped"
        case connected = "connected"
    }

    private var process: Process? = nil
    /// M17 hotfix：保盾 daemon 日志 fd 一直吃 daemon 生命周期，不在 startDaemon 出去后被 ARC 释放。
    private var daemonLogHandle: FileHandle? = nil
    private let client: DaemonSocketClient
    let clientPath: String

    init(sockPath: String? = nil) {
        let path = sockPath ?? DaemonSocketClient.defaultSockPath()
        self.client = DaemonSocketClient(sockPath: path)
        self.clientPath = path
    }

    // M28：GUI **不再删除 socket 文件**。
    // 旧逻辑（M17 hotfix）在探活失败且 GUI 不持有 daemon 进程时 unlink socket。探活失败并不等于
    // daemon 已死（2s 读超时、daemon 由别处启动且正忙……）；删掉一个活 daemon 的 socket 会让它
    // 连同 VM 变成不可达的孤儿。而且 M27 起 daemon 有单实例守卫：真正的 stale socket 由新 daemon
    // 在启动时探活后自行接管，GUI 侧没有任何理由再碰这个文件。

    func refresh() {
        // M17 hotfix：GUI 自持的 daemon 以 process.isRunning 为连注目（期间run 忙 socket 的 probing 会超时）。
        if let p = process, p.isRunning {
            self.status = .connected
            return
        }
        // Cmd+Q bug fix：probing 带 2s 读超时，每 3s 的定时器在主线程调它会卡死 runloop。
        let client = self.client
        DispatchQueue.global().async { [weak self] in
            let on = client.probing()
            DispatchQueue.main.async {
                guard let self else { return }
                self.status = on ? .connected : .stopped
            }
        }
    }

    /// daemon 死处理：若已死，重置 process 引用使 startDaemon 工作。
    func noteDiedIfNeeded() {
        if let p = process, !p.isRunning {
            process = nil
        }
    }

    func startDaemon(dbxBinaryPath: URL, sockPath: String?) throws {
        // M17 hotfix：已有本 GUI 开的 daemon 组件时，直接返回（probing 在 boot 期间可能超时不负责任）。
        if let p = process, p.isRunning { self.status = .connected; return }
        noteDiedIfNeeded()
        guard !client.probing() else { self.status = .connected; return }
        let process = Process()
        process.executableURL = dbxBinaryPath
        var args = ["daemon"]
        if let sockPath, !sockPath.isEmpty { args += ["--daemon-sock", sockPath] }
        process.arguments = args
        // M17 hotfix：daemon 的 stdout/stderr 写到日志文件（避免 pipe 缓冲阻锡。
        // GUI 由 LogStore.loadExternal 追加显示。
        let logDir = (sockPath ?? self.clientPath).replacingOccurrences(of: "/dbxd.sock", with: "")
        let logPath = logDir + "/dbxd-gui.log"
        // M35：daemon 日志里有 guest console 输出；0600，且已存在的旧日志也收紧。
        FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        SecureFile.tighten(URL(fileURLWithPath: logPath))
        let logHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        try? logHandle?.truncate(atOffset: 0)
        process.standardOutput = logHandle
        process.standardError = logHandle
        self.daemonLogHandle = logHandle
        self.daemonLogPath = logPath
        try process.run()
        self.process = process
        self.startedAt = ISO8601DateFormatter().string(from: Date())
        // M17：GUI 从日志文件增量加载（独立 timer）。
        self.startLogTail(path: self.daemonLogPath)
        // polling connect readiness
        DispatchQueue.global().async {
            for _ in 0..<40 {
                if self.client.probing() {
                    DispatchQueue.main.async { self.status = .connected }
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            DispatchQueue.main.async {
                self.status = .stopped
                self.lastError = "daemon 启动后在 10s 内未响应 socket"
            }
        }
    }

    // MARK: - Log tail (M17 hotfix)
    var daemonLogPath: String = ""
    private var logTailOffset: UInt64 = 0

    func startLogTail(path: String) {
        guard !path.isEmpty else { return }
        logTailOffset = 0
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.tailLoop(path: path)
        }
    }

    private func tailLoop(path: String) {
        // 简捕：每 1s 拉尾部 until daemon 停。
        while true {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
                Thread.sleep(forTimeInterval: 1.0); continue
            }
            if data.count > logTailOffset {
                let newData = data.subdata(in: Int(logTailOffset)..<data.count)
                let text = String(decoding: newData, as: UTF8.self)
                logTailOffset = UInt64(data.count)
                DispatchQueue.main.async { LogStore.shared.append(text) }
            }
            guard let p = self.process, p.isRunning else { break }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    func stopDaemon() {
        // Cmd+Q bug fix：shutdown 请求离主线程（默认 30s 超时足以卡死 UI）。
        let client = self.client
        let p = process
        process = nil
        self.status = .stopped
        DispatchQueue.global().async {
            if let response = try? client.send(DaemonRequest(kind: "shutdown"), timeoutSec: 5) {
                LogStore.shared.append("shutdown ack pid=\(response.pid ?? 0)")
            }
            p?.terminate()
        }
    }
}

final class LogStore: ObservableObject, @unchecked Sendable {
    static let shared = LogStore()
    @Published private var linesMutable: [String] = []
    private let lock = NSLock()
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return linesMutable }
    func append(_ text: String) {
        let chunks = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        lock.lock()
        linesMutable.append(contentsOf: chunks)
        if linesMutable.count > 500 { linesMutable.removeFirst(linesMutable.count - 500) }
        lock.unlock()
        DispatchQueue.main.async { self.objectWillChange.send() }
    }
}
