import DeskBoxCore
import Foundation

/// Workspace snapshot 推送（docs/design/m2-1-workspace-sync.md）。
///
/// 安全语义：
/// - fail-closed：启动快照构建遇任何违规（symlink/越界/超限）直接抛错，不做静默跳过；
/// - 推送走加密 control channel（secret channel 才允许进行）；
/// - manifest 中的 per-file SHA-256 成为后续供应链记录的初步主张。
public struct WorkspaceSyncPolicy: Sendable, Equatable {
    public var maxFiles: Int = 4_096
    public var maxTotalBytes: UInt64 = 64 * 1024 * 1024
    public var maxFileBytes: UInt64 = 16 * 1024 * 1024

    public init() {}
}

public struct WorkspaceSyncedFile: Sendable, Equatable {
    public let relativePath: String
    public let mode: UInt32
    public let bytes: UInt64
    public let sha256Hex: String
}

public struct WorkspaceSnapshot: Sendable, Equatable {
    public let wsId: String
    public let rootURL: URL
    public let files: [WorkspaceSyncedFile]
    public let totalBytes: UInt64
}

public enum WorkspaceSyncError: Error, Equatable, CustomStringConvertible {
    case rootMissing(String)
    case symlinkRejected(String)
    case pathEscapesRoot(String)
    case excessiveFileCount(Int, Int)
    case excessiveTotalBytes(UInt64, UInt64)
    case excessiveFileBytes(String, UInt64, UInt64)
    case unreadable(String)
    case unexpectedItemType(String)

    public var description: String {
        switch self {
        case .rootMissing(let p): return "workspace root 不存在或不可读: \(p)"
        case .symlinkRejected(let p): return "workspace 包含符号链接（fail-closed 拒绝）: \(p)"
        case .pathEscapesRoot(let p): return "路径越出 workspace root: \(p)"
        case .excessiveFileCount(let n, let cap): return "文件数 \(n) 超过限额 \(cap)"
        case .excessiveTotalBytes(let n, let cap): return "总字节 \(n) 超过限额 \(cap)"
        case .excessiveFileBytes(let p, let n, let cap): return "文件 \(p) 大小 \(n) 超过限额 \(cap)"
        case .unreadable(let p): return "文件不可读: \(p)"
        case .unexpectedItemType(let p): return "不支持的文件类型: \(p)"
        }
    }
}

public enum WorkspaceSyncService {
    public static func buildSnapshot(root: URL, policy: WorkspaceSyncPolicy = WorkspaceSyncPolicy()) throws -> WorkspaceSnapshot {
        let rootURL = root.standardizedFileURL
        let rootPath = rootURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceSyncError.rootMissing(rootPath)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw WorkspaceSyncError.rootMissing(rootPath)
        }
        var files: [WorkspaceSyncedFile] = []
        var totalBytes: UInt64 = 0
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { throw WorkspaceSyncError.pathEscapesRoot(path) }
            let rel = String(path.dropFirst(rootPath.count + 1))
            guard !rel.split(separator: "/").contains("..") else { throw WorkspaceSyncError.pathEscapesRoot(rel) }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw WorkspaceSyncError.symlinkRejected(rel) }
            // 目录在 enumerator 递归时被展开；跳过目录本身。
            guard values.isRegularFile == true else {
                if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                throw WorkspaceSyncError.unexpectedItemType(rel)
            }
            if files.count >= policy.maxFiles { throw WorkspaceSyncError.excessiveFileCount(files.count + 1, policy.maxFiles) }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let bytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            if bytes > policy.maxFileBytes { throw WorkspaceSyncError.excessiveFileBytes(rel, bytes, policy.maxFileBytes) }
            if totalBytes + bytes > policy.maxTotalBytes { throw WorkspaceSyncError.excessiveTotalBytes(totalBytes + bytes, policy.maxTotalBytes) }
            guard FileManager.default.isReadableFile(atPath: path) else { throw WorkspaceSyncError.unreadable(rel) }
            let sha256 = try DigestVerifier.sha256Hex(of: url)
            let posix = (attributes[.posixPermissions] as? NSNumber)?.uint32Value
            let mode: UInt32 = (posix != nil && (posix! & 0o111) != 0) ? 0o755 : 0o644
            files.append(WorkspaceSyncedFile(relativePath: rel, mode: mode, bytes: bytes, sha256Hex: sha256))
            totalBytes += bytes
        }
        files.sort { $0.relativePath < $1.relativePath }
        return WorkspaceSnapshot(wsId: UUID().uuidString, rootURL: rootURL, files: files, totalBytes: totalBytes)
    }
}
