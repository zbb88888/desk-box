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

    public init(
        sandboxID: SandboxID,
        bootID: BootID,
        status: Status,
        clonePath: String,
        hostPID: Int32,
        createdAt: Date = Date()
    ) {
        self.sandboxID = sandboxID
        self.bootID = bootID
        self.status = status
        self.clonePath = clonePath
        self.hostPID = hostPID
        self.createdAt = createdAt
    }
}

public struct RegistrySweepReport: Sendable, Equatable {
    public let orphanedSandboxes: [SandboxID]
    public let removedCloneFiles: [String]

    public var isEmpty: Bool { orphanedSandboxes.isEmpty && removedCloneFiles.isEmpty }
}

/// JSON-file registry. All mutations are serialized by callers (the VZ queue);
/// the sweep API tolerates a missing/corrupt file by rebuilding it from the
/// COW directory instead of deleting anything it can't attribute.
public final class SandboxRegistry: @unchecked Sendable {
    private let fileURL: URL
    private let cowRoot: URL

    public init(root: URL) throws {
        self.cowRoot = root
        self.fileURL = root.appendingPathComponent("registry.json", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        var entries = try load()
        if let index = entries.firstIndex(where: { $0.sandboxID == entry.sandboxID }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        try persist(entries)
    }

    public func markDestroyed(sandboxID: SandboxID) throws {
        var entries = try load()
        entries.removeAll { $0.sandboxID == sandboxID }
        try persist(entries)
    }

    private func persist(_ entries: [RegisteredSandbox]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmpURL = fileURL.appendingPathExtension("tmp")
        try encoder.encode(entries).write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        // kill(pid, 0) reports liveness without signaling; EPERM still counts
        // as alive because the process exists but isn't ours.
        kill(pid, 0)
        return errno == 0 || errno == EPERM
    }

    /// Remove COW clones of registries whose host process is dead. Never
    /// touches entries owned by a live app instance, and never deletes files
    /// that were not recorded in the registry.
    public func sweep(now: Date = Date()) throws -> RegistrySweepReport {
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
            }
        }
        try persist(survivors)
        return RegistrySweepReport(orphanedSandboxes: orphans, removedCloneFiles: removed)
    }
}
