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
        /// M23（INV-02）：clone 所属凭据域。跨域复用同一 lease 必须被拒绝。
        public let domainID: CredentialDomainID

        public init(sandboxID: SandboxID, sourceURL: URL, cloneURL: URL,
                    domainID: CredentialDomainID = CredentialDomainID("default")) {
            self.sandboxID = sandboxID
            self.sourceURL = sourceURL
            self.cloneURL = cloneURL
            self.domainID = domainID
        }
    }

    /// M23：与 clone 并排的域标记文件（`sandbox-<id>.vhd.domain`）。
    /// 单独落盘而不是只放在内存里，是为了让崩溃后 sweep / 人工取证也能识别跨域挪用。
    static func domainMarkerURL(forClone cloneURL: URL) -> URL {
        cloneURL.appendingPathExtension("domain")
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
    public func createClone(source: URL, sandboxID: SandboxID,
                            domainID: CredentialDomainID = CredentialDomainID("default")) throws -> Lease {
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
        // M23：域标记失败也必须清理 clone（否则会留下无法归属的 COW）。
        do {
            try Data(domainID.raw.utf8).write(to: Self.domainMarkerURL(forClone: cloneURL), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: cloneURL)
            throw SandboxFailure(.platformCowUnavailable, "写入 COW 域标记失败：\(error)")
        }
        return Lease(sandboxID: sandboxID, sourceURL: source, cloneURL: cloneURL, domainID: domainID)
    }

    /// M23（INV-02）：把一个已存在的 clone 认领给某个域。
    /// 用于「域 A 的 clone 被挪给域 B」这一攻击路径——domain 标记不符即拒绝。
    public func adoptClone(cloneURL: URL, sandboxID: SandboxID,
                          domainID: CredentialDomainID) throws -> Lease {
        let clone = cloneURL.standardizedFileURL
        let cloneParent = clone.deletingLastPathComponent().standardizedFileURL.path
        guard cloneParent == root.path else {
            throw SandboxFailure(.platformCowUnavailable, "clone 路径不属于 runtime storage root")
        }
        guard fileManager.fileExists(atPath: clone.path) else {
            throw SandboxFailure(.platformCowUnavailable, "clone 不存在：\(clone.path)")
        }
        if let recorded = try Self.recordedDomain(forClone: clone), recorded != domainID {
            throw SandboxFailure(.platformCowUnavailable,
                                 "COW 域不匹配（cow-domain-mismatch）：clone 属于 \(recorded)，请求域 \(domainID)")
        }
        return Lease(sandboxID: sandboxID, sourceURL: clone, cloneURL: clone, domainID: domainID)
    }

    /// 读取 clone 的域标记；不存在返回 nil（旧版本 clone）。
    public static func recordedDomain(forClone cloneURL: URL) throws -> CredentialDomainID? {
        let url = domainMarkerURL(forClone: cloneURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let raw = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return CredentialDomainID(raw)
    }

    /// Removes only a product-owned clone. Failure is returned to caller;
    /// destroy must not report success while the COW remains.
    public func removeClone(_ lease: Lease) throws {
        let cloneParent = lease.cloneURL.deletingLastPathComponent().standardizedFileURL.path
        guard cloneParent == root.path else {
            throw SandboxFailure(.platformCowCleanupFailed, "COW 路径不属于 runtime storage root")
        }
        try? fileManager.removeItem(at: Self.domainMarkerURL(forClone: lease.cloneURL))
        guard fileManager.fileExists(atPath: lease.cloneURL.path) else { return }
        do {
            try fileManager.removeItem(at: lease.cloneURL)
        } catch {
            throw SandboxFailure(.platformCowCleanupFailed, "删除 COW 失败：\(error.localizedDescription)")
        }
    }
}
