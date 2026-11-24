import Darwin
import Foundation

/// M35：宿主侧敏感文件的写入与目录创建。
///
/// 原则：**敏感内容的保密性不依赖父目录**。默认状态目录在 `~/Library`（0700）之下，但
/// `--cow-root` / `DBX_SUPPORT_ROOT` 可以把它们指到任何地方。因此：
/// - 我们创建的目录一律 0700；
/// - 我们写的敏感文件一律 0600，并且**没有窗口期**（先在同目录建 0600 的临时文件，写完 rename）；
/// - 不去 chmod 用户给的、已经存在的顶层目录——那不是我们的东西（它可能是 `$HOME`）。
public enum SecureFile {
    /// 原子写入，最终权限为 `mode`，与 umask 无关，目标路径上任何时刻都不会出现权限更宽的同内容文件。
    public static func write(_ data: Data, to url: URL, mode: Int = 0o600) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try PrivateDirectory.create(directory)
        }
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        // open(O_EXCL) + 显式 mode：不经过「先按 umask 创建、再 chmod」。
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, mode_t(mode))
        guard fd >= 0 else { throw posixError("create \(temp.lastPathComponent)") }
        var failure: Error?
        do {
            // umask 只会让权限更严；仍显式设置一次，保证最终就是 mode。
            guard fchmod(fd, mode_t(mode)) == 0 else { throw posixError("fchmod") }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n < 0 { if errno == EINTR { continue }; throw posixError("write") }
                    offset += n
                }
            }
            guard fsync(fd) == 0 else { throw posixError("fsync") }
        } catch { failure = error }
        close(fd)
        if failure == nil, rename(temp.path, url.path) != 0 { failure = posixError("rename into \(url.lastPathComponent)") }
        if let failure {
            try? fm.removeItem(at: temp)
            throw failure
        }
    }

    /// 把一个**已存在的、属于我们的**文件收紧到 `mode`（只收紧，不放宽）。
    public static func tighten(_ url: URL, to mode: Int = 0o600) {
        guard let current = permissions(of: url), current & ~mode != 0 else { return }
        _ = chmod(url.path, mode_t(current & mode))
    }

    public static func permissions(of url: URL) -> Int? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Int(info.st_mode & 0o7777)
    }

    private static func posixError(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "SecureFile \(what) failed: \(String(cString: strerror(errno)))"])
    }
}

public enum PrivateDirectory {
    /// 创建目录（含中间目录），**新建的每一级**都是 0700；已存在的各级原样不动。
    public static func create(_ url: URL) throws {
        let fm = FileManager.default
        var missing: [URL] = []
        var cursor = url.standardizedFileURL
        while !fm.fileExists(atPath: cursor.path) {
            missing.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        for directory in missing.reversed() {
            // mkdir 的 mode 受 umask 影响只会更严；随后显式 chmod 保证正好是 0700。
            if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: "mkdir \(directory.path): \(String(cString: strerror(errno)))"])
            }
            _ = chmod(directory.path, 0o700)
        }
    }

    /// 用于**名字由我们决定、内容只属于我们**的子目录（如 `<cow-root>/snapshots`）：
    /// 不存在则创建为 0700；已存在且属于当前用户则收紧到 0700。
    /// 不要对用户提供的顶层目录调用它。
    public static func ensureOwned(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try create(url)
            return
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else { return }
        if info.st_mode & 0o077 != 0 { _ = chmod(url.path, 0o700) }
    }
}
