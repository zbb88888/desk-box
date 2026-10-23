import Foundation
import Darwin
import DeskBoxCore

/// Per-sandbox APFS copy-on-write disk manager.
///
/// `clonefile` is an APFS/filesystem primitive, not a VZ snapshot and not a
/// complete VM snapshot. The source remains read-only; VZ receives only the
/// sandbox clone as its writable block image. Unsupported filesystems fail
/// closed instead of falling back to a writable base disk.
public final class CowDiskManager: @unchecked Sendable {
    public struct Lease: Sendable, Equatable {
        public let sandboxID: SandboxID
        public let sourceURL: URL
        public let cloneURL: URL

        public init(sandboxID: SandboxID, sourceURL: URL, cloneURL: URL) {
            self.sandboxID = sandboxID
            self.sourceURL = sourceURL
            self.cloneURL = cloneURL
        }
    }

    private let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    /// Creates a clone in a fixed product-owned directory. The sandbox ID is
    /// UUID-backed, but we still reject path separators as a defense-in-depth
    /// invariant before constructing a path.
    public func createClone(source: URL, sandboxID: SandboxID) throws -> Lease {
        let source = source.standardizedFileURL
        guard fileManager.isReadableFile(atPath: source.path) else {
            throw SandboxFailure(.platformCowUnavailable, "基础盘不可读：\(source.path)")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw SandboxFailure(.platformCowUnavailable, "基础盘不是普通文件：\(source.path)")
        }
        guard !sandboxID.raw.contains("/") && !sandboxID.raw.contains("..") else {
            throw SandboxFailure(.platformCowUnavailable, "sandbox ID 不能用于构造磁盘路径")
        }

        let cloneURL = root.appendingPathComponent("sandbox-\(sandboxID.raw).vhd", isDirectory: false)
        guard !fileManager.fileExists(atPath: cloneURL.path) else {
            throw SandboxFailure(.platformCowUnavailable, "sandbox COW 已存在：\(cloneURL.path)")
        }

        let result = clonefile(source.path, cloneURL.path, 0)
        guard result == 0 else {
            let error = errno
            throw SandboxFailure(.platformCowUnavailable, "APFS clonefile 失败（errno=\(error)），拒绝回退到基础盘")
        }
        return Lease(sandboxID: sandboxID, sourceURL: source, cloneURL: cloneURL)
    }

    /// Removes only a product-owned clone. Failure is returned to caller;
    /// destroy must not report success while the COW remains.
    public func removeClone(_ lease: Lease) throws {
        let cloneParent = lease.cloneURL.deletingLastPathComponent().standardizedFileURL.path
        guard cloneParent == root.path else {
            throw SandboxFailure(.platformCowCleanupFailed, "COW 路径不属于 runtime storage root")
        }
        guard fileManager.fileExists(atPath: lease.cloneURL.path) else { return }
        do {
            try fileManager.removeItem(at: lease.cloneURL)
        } catch {
            throw SandboxFailure(.platformCowCleanupFailed, "删除 COW 失败：\(error.localizedDescription)")
        }
    }
}
