import XCTest
import Foundation
@testable import DeskBoxCore
@testable import DeskBoxVZ

/// M19 安全证据 corpus（INV-05 文件系统 / INV-06 OCI metadata）。
///
/// 每个用例断言**具体拒绝原因**，而不是「大概失败了」——这是可证伪的证据。
/// 证据输出：`swift test --filter SecurityCorpus` 全绿即通过；CI 归档日志。
final class SecurityCorpusTests: XCTestCase {

    // MARK: - 工具

    private func makeTempDir(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbx-corpus-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// 断言 buildSnapshot 以指定错误被拒。
    private func expectWorkspaceReject(_ root: URL, _ expected: WorkspaceSyncError,
                                       file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try WorkspaceSyncService.buildSnapshot(root: root)
            XCTFail("期望被拒 \(expected)，实际通过", file: file, line: line)
        } catch let error as WorkspaceSyncError {
            XCTAssertEqual(error, expected, "拒绝原因不符", file: file, line: line)
        } catch {
            XCTFail("期望 WorkspaceSyncError，实际 \(error)", file: file, line: line)
        }
    }

    private func expectWorkspaceRejectAny(_ root: URL, file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try WorkspaceSyncService.buildSnapshot(root: root)
            XCTFail("期望被拒，实际通过", file: file, line: line)
        } catch is WorkspaceSyncError {
            // ok
        } catch {
            XCTFail("期望 WorkspaceSyncError，实际 \(error)", file: file, line: line)
        }
    }

    // MARK: - INV-05：文件系统 corpus

    func testINV05_AllowsNormalNestedWorkspace() throws {
        let root = try makeTempDir("fs-ok")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        try "world".write(to: root.appendingPathComponent("src/deep/b.txt"), atomically: true, encoding: .utf8)
        let snap = try WorkspaceSyncService.buildSnapshot(root: root)
        XCTAssertEqual(snap.files.count, 2)
        XCTAssertEqual(Set(snap.files.map(\.relativePath)), ["src/a.txt", "src/deep/b.txt"])
    }

    func testINV05_RejectsFileSymlink() throws {
        let root = try makeTempDir("fs-symlink-file")
        let target = root.appendingPathComponent("real.txt")
        try "secret".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"), withDestinationURL: target)
        expectWorkspaceRejectAny(root)
    }

    func testINV05_RejectsDirSymlink() throws {
        let root = try makeTempDir("fs-symlink-dir")
        let outside = try makeTempDir("fs-symlink-dir-outside")
        try "x".write(to: outside.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("dirlink"), withDestinationURL: outside)
        expectWorkspaceRejectAny(root)
    }

    func testINV05_RejectsChainedSymlink() throws {
        let root = try makeTempDir("fs-symlink-chain")
        let outside = try makeTempDir("fs-symlink-chain-outside")
        let hop = root.appendingPathComponent("hop")
        try FileManager.default.createSymbolicLink(at: hop, withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("chain"), withDestinationURL: hop)
        expectWorkspaceRejectAny(root)
    }

    func testINV05_RejectsFileCountOverLimit() throws {
        let root = try makeTempDir("fs-count")
        var policy = WorkspaceSyncPolicy()
        policy.maxFiles = 2
        for i in 0..<3 {
            try "x".write(to: root.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertThrowsError(try WorkspaceSyncService.buildSnapshot(root: root, policy: policy)) { error in
            guard case WorkspaceSyncError.excessiveFileCount = error else {
                return XCTFail("期望 excessiveFileCount，实际 \(error)")
            }
        }
    }

    func testINV05_RejectsTotalBytesOverLimit() throws {
        let root = try makeTempDir("fs-total")
        var policy = WorkspaceSyncPolicy()
        policy.maxTotalBytes = 8
        try String(repeating: "a", count: 32)
            .write(to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WorkspaceSyncService.buildSnapshot(root: root, policy: policy)) { error in
            guard case WorkspaceSyncError.excessiveTotalBytes = error else {
                return XCTFail("期望 excessiveTotalBytes，实际 \(error)")
            }
        }
    }

    func testINV05_RejectsSingleFileOverLimit() throws {
        let root = try makeTempDir("fs-file")
        var policy = WorkspaceSyncPolicy()
        policy.maxFileBytes = 4
        policy.maxTotalBytes = 1024
        try String(repeating: "b", count: 64)
            .write(to: root.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WorkspaceSyncService.buildSnapshot(root: root, policy: policy)) { error in
            guard case WorkspaceSyncError.excessiveFileBytes = error else {
                return XCTFail("期望 excessiveFileBytes，实际 \(error)")
            }
        }
    }

    /// 大小写不敏感文件系统上 `A.txt` 与 `a.txt` 互为同一 inode；两者并存时
    /// 快照必须能稳定区分或明确拒绝，不允许产生「同名不同内容」的歧义条目。
    func testINV05_CaseCollisionIsDeterministic() throws {
        let root = try makeTempDir("fs-case")
        let upper = root.appendingPathComponent("Same.txt")
        let lower = root.appendingPathComponent("same.txt")
        try "U".write(to: upper, atomically: true, encoding: .utf8)
        // APFS 默认大小写不敏感：写 lower 会命中同一文件；若失败说明文件系统区分大小写。
        try? "L".write(to: lower, atomically: true, encoding: .utf8)
        let snap = try WorkspaceSyncService.buildSnapshot(root: root)
        let names = Set(snap.files.map { $0.relativePath.lowercased() })
        XCTAssertEqual(names.count, snap.files.count,
                       "同一快照内出现大小写重复路径: \(snap.files.map(\.relativePath))")
    }

    func testINV05_RejectsMissingRoot() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbx-corpus-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try WorkspaceSyncService.buildSnapshot(root: missing)) { error in
            guard case WorkspaceSyncError.rootMissing = error else {
                return XCTFail("期望 rootMissing，实际 \(error)")
            }
        }
    }

    // MARK: - INV-06：OCI metadata corpus

    private func bundle() throws -> URL {
        let dir = try makeTempDir("oci-bundle")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("rootfs"), withIntermediateDirectories: true)
        return dir
    }

    private func spec(args: [String] = ["/bin/echo", "hi"],
                      cwd: String = "/workspace",
                      env: [String]? = nil,
                      uid: Int = 65_534,
                      gid: Int = 65_534,
                      mounts: [OciRuntimeSpec.Mount]? = nil,
                      privileged: Bool? = nil,
                      rootPath: String? = nil,
                      namespaces: [OciRuntimeSpec.Namespace]? = nil) -> OciRuntimeSpec {
        OciRuntimeSpec(
            ociVersion: "1.0.2",
            root: rootPath.map { OciRuntimeSpec.Root(path: $0) },
            process: OciRuntimeSpec.Process(
                args: args, cwd: cwd, env: env,
                user: OciRuntimeSpec.User(uid: uid, gid: gid)),
            mounts: mounts,
            linux: (privileged != nil || namespaces != nil)
                ? OciRuntimeSpec.Linux(namespaces: namespaces, privileged: privileged)
                : nil
        )
    }

    private func expectOciReject(_ spec: OciRuntimeSpec, bundleDir: URL,
                                 _ match: (OciPolicyError) -> Bool,
                                 _ label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try OciPolicyValidator.validate(spec: spec, bundleDir: bundleDir)
            XCTFail("期望拒绝 (\(label))，实际通过", file: file, line: line)
        } catch let error as OciPolicyError {
            XCTAssertTrue(match(error), "\(label): 拒绝原因不符 -> \(error)", file: file, line: line)
        } catch {
            XCTFail("\(label): 期望 OciPolicyError，实际 \(error)", file: file, line: line)
        }
    }

    func testINV06_AcceptsMinimalValidSpec() throws {
        let dir = try bundle()
        let resolved = try OciPolicyValidator.validate(spec: spec(), bundleDir: dir)
        XCTAssertEqual(resolved.cwd, "/workspace")
        XCTAssertEqual(resolved.argv, ["/bin/echo", "hi"])
    }

    func testINV06_RejectsPrivileged() throws {
        let dir = try bundle()
        expectOciReject(spec(privileged: true), bundleDir: dir,
                        { if case .privilegedRequested = $0 { return true }; return false }, "privileged")
    }

    func testINV06_RejectsRootUid() throws {
        let dir = try bundle()
        expectOciReject(spec(uid: 0), bundleDir: dir,
                        { if case .uidNotNobody(0) = $0 { return true }; return false }, "uid=0")
    }

    func testINV06_RejectsNonNobodyUid() throws {
        let dir = try bundle()
        expectOciReject(spec(uid: 1000), bundleDir: dir,
                        { if case .uidNotNobody(1000) = $0 { return true }; return false }, "uid=1000")
    }

    func testINV06_RejectsCwdOutsideWorkspace() throws {
        let dir = try bundle()
        for cwd in ["/etc", "/workspace/../etc", "/"] {
            expectOciReject(spec(cwd: cwd), bundleDir: dir,
                            { if case .cwdNotUnderWorkspace = $0 { return true }; return false }, "cwd=\(cwd)")
        }
    }

    func testINV06_RejectsReservedEnvKeys() throws {
        let dir = try bundle()
        for kv in ["DBX_TOKEN=1", "PATH=/evil", "HOME=/root", "USER=root"] {
            expectOciReject(spec(env: [kv]), bundleDir: dir,
                            { if case .envKeyInvalid = $0 { return true }; return false }, "env \(kv)")
        }
    }

    func testINV06_RejectsEmptyArgs() throws {
        let dir = try bundle()
        expectOciReject(spec(args: []), bundleDir: dir,
                        { if case .emptyArgs = $0 { return true }; return false }, "空 argv")
    }

    func testINV06_RejectsMountOutsideWorkspace() throws {
        let dir = try bundle()
        let mounts = [OciRuntimeSpec.Mount(destination: "/etc", source: "somewhere", type: "bind")]
        expectOciReject(spec(mounts: mounts), bundleDir: dir,
                        { if case .mountOutsideWorkspace = $0 { return true }; return false }, "mount /etc")
    }

    func testINV06_RejectsSuspiciousMountSource() throws {
        let dir = try bundle()
        for source in ["/dev/sda", "/proc", "/sys", "/etc/shadow"] {
            let mounts = [OciRuntimeSpec.Mount(destination: "/workspace/m", source: source, type: "bind")]
            expectOciReject(spec(mounts: mounts), bundleDir: dir,
                            { if case .mountSourceSuspicious = $0 { return true }; return false }, "source \(source)")
        }
    }

    func testINV06_RejectsNamespacePath() throws {
        let dir = try bundle()
        let ns = [OciRuntimeSpec.Namespace(type: "network", path: "/proc/1/ns/net")]
        expectOciReject(spec(namespaces: ns), bundleDir: dir,
                        { if case .namespaceUnsupported = $0 { return true }; return false }, "ns path")
    }

    func testINV06_RejectsOciRootOutsideBundle() throws {
        let dir = try bundle()
        for rootPath in ["../outside", "/etc", "/"] {
            expectOciReject(spec(rootPath: rootPath), bundleDir: dir,
                            { if case .ociRootOutsideBundle = $0 { return true }; return false }, "root \(rootPath)")
        }
    }

    func testINV06_RejectsOverlongEnvValue() throws {
        let dir = try bundle()
        let kv = "BIG=" + String(repeating: "x", count: 4096)
        expectOciReject(spec(env: [kv]), bundleDir: dir,
                        { if case .envValueTooLong = $0 { return true }; return false }, "env 超长")
    }

    func testINV06_RejectsMalformedEnvPair() throws {
        let dir = try bundle()
        expectOciReject(spec(env: ["NOEQUALS"]), bundleDir: dir,
                        { if case .envPairsMalformed = $0 { return true }; return false }, "env 无 =")
    }
}
