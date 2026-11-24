import CryptoKit
import Darwin
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
    /// M37：快照构建时**一次性**读入的文件内容。推送只用这份字节，不再按路径重新打开文件——
    /// 「校验时是普通文件、推送时已被换成符号链接」这类竞争从构造上不存在。
    /// 上限由 `WorkspaceSyncPolicy.maxTotalBytes`（默认 64MiB）约束。
    public let contents: Data

    public init(relativePath: String, mode: UInt32, bytes: UInt64, sha256Hex: String, contents: Data) {
        self.relativePath = relativePath
        self.mode = mode
        self.bytes = bytes
        self.sha256Hex = sha256Hex
        self.contents = contents
    }
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
    /// 枚举之后、读取之前（或读取过程中）文件被替换 / 改动。
    case changedDuringSnapshot(String)

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
        case .changedDuringSnapshot(let p): return "文件在快照过程中被替换或改动（fail-closed 拒绝）: \(p)"
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
        // M37：root 只打开一次；之后所有文件都经由这个目录描述符、逐级 O_NOFOLLOW 打开。
        let rootFD = open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw WorkspaceSyncError.rootMissing(rootPath) }
        defer { close(rootFD) }
        var files: [WorkspaceSyncedFile] = []
        var totalBytes: UInt64 = 0
        // root 的真实路径（/tmp → /private/tmp 这类）。枚举器对个别条目（例如悬空符号链接）会给出
        // 解析后的前缀，只按字面前缀比较会把它们误报成「越出 root」。两种前缀都接受；
        // 真正的越界判定在 secureRead（逐级 O_NOFOLLOW）。
        // 注意：Foundation 的 resolvingSymlinksInPath 在 macOS 上会把 /private/tmp 「还原」成 /tmp，
        // 方向正好相反——这里要的是内核眼里的真实路径，所以用 realpath(3)。
        let rootReal: String = {
            guard let resolved = realpath(rootPath, nil) else { return rootPath }
            defer { free(resolved) }
            return String(cString: resolved)
        }()
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            let rel: String
            if path.hasPrefix(rootPath + "/") { rel = String(path.dropFirst(rootPath.count + 1)) }
            else if path.hasPrefix(rootReal + "/") { rel = String(path.dropFirst(rootReal.count + 1)) }
            else { throw WorkspaceSyncError.pathEscapesRoot(path) }
            guard !rel.split(separator: "/").contains("..") else { throw WorkspaceSyncError.pathEscapesRoot(rel) }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw WorkspaceSyncError.symlinkRejected(rel) }
            // 目录在 enumerator 递归时被展开；跳过目录本身。
            guard values.isRegularFile == true else {
                if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                throw WorkspaceSyncError.unexpectedItemType(rel)
            }
            if files.count >= policy.maxFiles { throw WorkspaceSyncError.excessiveFileCount(files.count + 1, policy.maxFiles) }
            // M37：类型 / 大小 / 内容 / 摘要全部来自**同一个已打开的描述符**。上面基于路径的检查只是
            // 提前给出更清楚的报错；真正的判定在这里。
            let read = try secureRead(rootFD: rootFD, relativePath: rel, maxBytes: policy.maxFileBytes)
            let bytes = UInt64(read.data.count)
            if totalBytes + bytes > policy.maxTotalBytes { throw WorkspaceSyncError.excessiveTotalBytes(totalBytes + bytes, policy.maxTotalBytes) }
            let sha256 = SHA256.hash(data: read.data).map { String(format: "%02x", $0) }.joined()
            let mode: UInt32 = (read.mode & 0o111) != 0 ? 0o755 : 0o644
            files.append(WorkspaceSyncedFile(relativePath: rel, mode: mode, bytes: bytes, sha256Hex: sha256, contents: read.data))
            totalBytes += bytes
        }
        files.sort { $0.relativePath < $1.relativePath }
        return WorkspaceSnapshot(wsId: UUID().uuidString, rootURL: rootURL, files: files, totalBytes: totalBytes)
    }

    /// 从 `rootFD` 出发逐级打开 `relativePath`，**每一级都不跟随符号链接**，然后在同一个描述符上
    /// 完成类型检查、大小检查与读取。
    ///
    /// 为什么不用 `Data(contentsOf:)`：它按路径打开并跟随符号链接。枚举时看到的是普通文件，
    /// 不代表读取时还是——中间任何一级目录或文件本身都可能被换成指向 workspace 之外的链接。
    static func secureRead(rootFD: Int32, relativePath: String, maxBytes: UInt64) throws -> (data: Data, mode: UInt32) {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            throw WorkspaceSyncError.pathEscapesRoot(relativePath)
        }
        var dirFD = dup(rootFD)
        guard dirFD >= 0 else { throw WorkspaceSyncError.unreadable(relativePath) }
        defer { if dirFD >= 0 { close(dirFD) } }
        for component in components.dropLast() {
            let next = openat(dirFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                // 打开失败本身就是拒绝；下面只是为了给出准确的原因。macOS 对「O_DIRECTORY|O_NOFOLLOW
                // 打开一个指向目录的符号链接」返回 ENOTDIR 而不是 ELOOP，所以再用 fstatat 看一眼。
                let code = errno
                var info = stat()
                let isLink = fstatat(dirFD, component, &info, AT_SYMLINK_NOFOLLOW) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
                if code == ELOOP || isLink { throw WorkspaceSyncError.symlinkRejected(relativePath) }
                throw WorkspaceSyncError.changedDuringSnapshot(relativePath)
            }
            close(dirFD)
            dirFD = next
        }
        // O_NONBLOCK：万一这里是个 FIFO，open 不会挂住（随后的类型检查会拒绝它）。
        let fd = openat(dirFD, components[components.count - 1], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ELOOP: throw WorkspaceSyncError.symlinkRejected(relativePath)
            case ENOENT, ENOTDIR: throw WorkspaceSyncError.changedDuringSnapshot(relativePath)
            default: throw WorkspaceSyncError.unreadable(relativePath)
            }
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw WorkspaceSyncError.unreadable(relativePath) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw WorkspaceSyncError.unexpectedItemType(relativePath) }
        let declared = UInt64(max(info.st_size, 0))
        if declared > maxBytes { throw WorkspaceSyncError.excessiveFileBytes(relativePath, declared, maxBytes) }
        // 读到 EOF；若文件在读取期间变大并越过限额，同样拒绝（不信任 st_size）。
        var data = Data(capacity: Int(declared))
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw WorkspaceSyncError.unreadable(relativePath)
            }
            if n == 0 { break }
            data.append(buffer, count: n)
            if UInt64(data.count) > maxBytes {
                throw WorkspaceSyncError.excessiveFileBytes(relativePath, UInt64(data.count), maxBytes)
            }
        }
        return (data, UInt32(info.st_mode & 0o7777))
    }
}
