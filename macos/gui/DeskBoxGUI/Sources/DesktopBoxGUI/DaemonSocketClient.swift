import Darwin
import Foundation

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
struct DaemonSocketClient {
    let sockPath: String

    static func defaultSockPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DeskBox/dbxd.sock").path
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
    private let client: DaemonSocketClient
    let clientPath: String

    init(sockPath: String? = nil) {
        let path = sockPath ?? DaemonSocketClient.defaultSockPath()
        self.client = DaemonSocketClient(sockPath: path)
        self.clientPath = path
    }

    func refresh() {
        self.status = client.probing() ? .connected : .stopped
    }

    func startDaemon(dbxBinaryPath: URL, sockPath: String?) throws {
        guard !client.probing() else { self.status = .connected; return }
        let process = Process()
        process.executableURL = dbxBinaryPath
        var args = ["daemon"]
        if let sockPath, !sockPath.isEmpty { args += ["--daemon-sock", sockPath] }
        process.arguments = args
        // 输出接回 GUI 日志
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        self.process = process
        self.startedAt = ISO8601DateFormatter().string(from: Date())
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
        // 收集日志
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { LogStore.shared.append(text) }
        }
    }

    func stopDaemon() {
        if let response = try? client.send(DaemonRequest(kind: "shutdown")) {
            LogStore.shared.append("shutdown ack pid=\(response.pid ?? 0)")
            self.status = .stopped
        }
        process?.terminate()
        process = nil
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
