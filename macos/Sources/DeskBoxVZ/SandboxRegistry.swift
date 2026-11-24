import Foundation
import DeskBoxCore

/// Durable sandbox registry used to recover orphaned resources after SIGKILL,
/// host crash or reboot. The registry file itself is protected declaratively
/// (JSON-Codable) and cleanup deletes only paths recorded in it, inside the
/// COW root, belonging to a dead host process.
public struct RegisteredSandbox: Sendable, Codable, Equatable {
    public enum Status: String, Sendable, Codable {
        case created
        case running
        case stopped
    }

    public let sandboxID: SandboxID
    public let bootID: BootID
    public var status: Status
    public let clonePath: String
    public let hostPID: Int32
    public let createdAt: Date
    /// M23（INV-02）：凭据域（旧 registry 文件缺该字段时按 `default` 读取）。
    public let domainID: CredentialDomainID

    public init(
        sandboxID: SandboxID,
        bootID: BootID,
        status: Status,
        clonePath: String,
        hostPID: Int32,
        createdAt: Date = Date(),
        domainID: CredentialDomainID = CredentialDomainID("default")
    ) {
        self.sandboxID = sandboxID
        self.bootID = bootID
        self.status = status
        self.clonePath = clonePath
        self.hostPID = hostPID
        self.createdAt = createdAt
        self.domainID = domainID
    }

    private enum CodingKeys: String, CodingKey {
        case sandboxID, bootID, status, clonePath, hostPID, createdAt, domainID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sandboxID = try c.decode(SandboxID.self, forKey: .sandboxID)
        bootID = try c.decode(BootID.self, forKey: .bootID)
        status = try c.decode(Status.self, forKey: .status)
        clonePath = try c.decode(String.self, forKey: .clonePath)
        hostPID = try c.decode(Int32.self, forKey: .hostPID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        // 兼容 M23 之前写下的 registry：无 domainID 视为 default。
        domainID = (try? c.decode(CredentialDomainID.self, forKey: .domainID))
            ?? CredentialDomainID("default")
    }
}

public struct RegistrySweepReport: Sendable, Equatable {
    public let orphanedSandboxes: [SandboxID]
    public let removedCloneFiles: [String]

    public var isEmpty: Bool { orphanedSandboxes.isEmpty && removedCloneFiles.isEmpty }
}

/// JSON-file registry.
///
/// M24b：daemon 并发化后，多个 VZRuntime 实例（每沙箱一个，各自独立 queue）以及独立的
/// CLI `sweep` 进程会同时对同一个 registry.json 做 read-modify-write。所有变更统一经
/// `withFileLock`（flock 独占锁，跨线程 + 跨进程）串行化，避免 lost update。
/// the sweep API tolerates a missing/corrupt file by rebuilding it from the
/// COW directory instead of deleting anything it can't attribute.
public final class SandboxRegistry: @unchecked Sendable {
    private let fileURL: URL
    private let cowRoot: URL
    private let lockURL: URL

    public init(root: URL) throws {
        self.cowRoot = root
        self.fileURL = root.appendingPathComponent("registry.json", isDirectory: false)
        self.lockURL = root.appendingPathComponent("registry.lock", isDirectory: false)
        try PrivateDirectory.create(root)
    }

    /// flock 按 open-file-description 计：每次调用各自 open，同进程线程间也互斥。
    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw SandboxFailure(.bootstrapProofMismatch,
                                 "sandbox registry 锁文件无法打开：errno=\(errno)")
        }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw SandboxFailure(.bootstrapProofMismatch,
                                 "sandbox registry 加锁失败：errno=\(errno)")
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    public func load() throws -> [RegisteredSandbox] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([RegisteredSandbox].self, from: data)
        } catch {
            throw SandboxFailure(.bootstrapProofMismatch,
                                 "sandbox registry 无法解析且拒绝猜目录内容：\(error.localizedDescription)")
        }
    }

    public func upsert(_ entry: RegisteredSandbox) throws {
        try withFileLock {
            var entries = try load()
            if let index = entries.firstIndex(where: { $0.sandboxID == entry.sandboxID }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
            try persist(entries)
        }
    }

    public func markDestroyed(sandboxID: SandboxID) throws {
        try withFileLock {
            var entries = try load()
            entries.removeAll { $0.sandboxID == sandboxID }
            try persist(entries)
        }
    }

    private func persist(_ entries: [RegisteredSandbox]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // M35：0600 原子写入。SecureFile 用带 UUID 的临时文件 + rename，
        // 即便锁失效也不会两个 writer 写同一个临时文件。
        try SecureFile.write(try encoder.encode(entries), to: fileURL)
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        // kill(pid, 0) reports liveness without signaling; EPERM still counts
        // as alive because the process exists but isn't ours.
        // M24b fix：必须看返回值——kill 成功时不会清 errno，此前读到的是本线程上一次失败
        // 调用留下的脏 errno，会把「活着的」沙箱误判为孤儿并删掉它的 COW 盘。
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Remove COW clones of registries whose host process is dead. Never
    /// touches entries owned by a live app instance, and never deletes files
    /// that were not recorded in the registry.
    /// M20：当前仍存活（host PID 活着）的沙箱 ID 集合，供快照清理判断。
    public func liveSandboxIDs() throws -> Set<String> {
        var ids: Set<String> = []
        for entry in try load() where Self.processIsAlive(entry.hostPID) {
            ids.insert(entry.sandboxID.description)
        }
        return ids
    }

    public func sweep(now: Date = Date()) throws -> RegistrySweepReport {
        try withFileLock { try sweepLocked() }
    }

    private func sweepLocked() throws -> RegistrySweepReport {
        let entries = try load()
        var survivors: [RegisteredSandbox] = []
        var orphans: [SandboxID] = []
        var removed: [String] = []

        for entry in entries {
            let alive = Self.processIsAlive(entry.hostPID)
            if alive {
                survivors.append(entry)
                continue
            }
            orphans.append(entry.sandboxID)
            let cloneURL = URL(fileURLWithPath: entry.clonePath)
            guard cloneURL.standardizedFileURL.deletingLastPathComponent()
                    .standardizedFileURL.path == cowRoot.standardizedFileURL.path else {
                // Registry entry path is outside the COW root; keep the entry so
                // a human can investigate instead of deleting arbitrary paths.
                survivors.append(entry)
                continue
            }
            do {
                try FileManager.default.removeItem(at: cloneURL)
                removed.append(entry.clonePath)
            } catch CocoaError.fileNoSuchFile {
                // Already gone; still an orphan worth dropping from the registry.
            } catch {
                survivors.append(entry)
                continue
            }
            // M24 fix：M23 的域标记文件（`<clone>.domain`）与 clone 同生共死。此前崩溃清理
            // 只删 clone，每次崩溃都在 cow-root 留下一个孤儿 sidecar。路径由已校验在
            // cowRoot 内的 clonePath 派生，不会越界。
            try? FileManager.default.removeItem(at: CowDiskManager.domainMarkerURL(forClone: cloneURL))
        }
        try persist(survivors)
        return RegistrySweepReport(orphanedSandboxes: orphans, removedCloneFiles: removed)
    }
}
