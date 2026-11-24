import XCTest
import Darwin
import Foundation
@testable import dbx_poc
@testable import DeskBoxCore
@testable import DeskBoxVZ

/// M35：敏感文件 / 目录的权限不依赖父目录，也不依赖 umask。
final class SecureStorageTests: XCTestCase {

    /// 一个权限很宽（0755）的「用户提供的」目录，里面的东西得自己保护自己。
    private func looseDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbx-sec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o755)
        addTeardownBlock {
            chmod(dir.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func mode(_ url: URL) -> Int { SecureFile.permissions(of: url) ?? -1 }

    /// 在最宽松的 umask 下执行（最坏情况）。
    private func withUmaskZero<T>(_ body: () throws -> T) rethrows -> T {
        let previous = umask(0)
        defer { umask(previous) }
        return try body()
    }

    // MARK: SecureFile

    func testWriteIsOwnerOnlyRegardlessOfUmask() throws {
        let dir = try looseDir()
        let file = dir.appendingPathComponent("secret")
        try withUmaskZero { try SecureFile.write(Data("s3cret".utf8), to: file) }
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertEqual(try Data(contentsOf: file), Data("s3cret".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["secret"], "不得留下临时文件")
    }

    func testOverwriteReplacesLooseFileWithTightOne() throws {
        let dir = try looseDir()
        let file = dir.appendingPathComponent("secret")
        try Data("old".utf8).write(to: file)
        chmod(file.path, 0o644)
        try SecureFile.write(Data("new".utf8), to: file)
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
    }

    func testWriteCreatesMissingParentsPrivately() throws {
        let dir = try looseDir()
        let file = dir.appendingPathComponent("a/b/secret")
        try withUmaskZero { try SecureFile.write(Data("x".utf8), to: file) }
        XCTAssertEqual(mode(dir.appendingPathComponent("a")), 0o700)
        XCTAssertEqual(mode(dir.appendingPathComponent("a/b")), 0o700)
        XCTAssertEqual(mode(dir), 0o755, "已存在的（用户的）目录不得被改动")
    }

    func testFailedWriteLeavesNoTempFile() throws {
        let dir = try looseDir()
        let occupied = dir.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: occupied.appendingPathComponent("f"))
        XCTAssertThrowsError(try SecureFile.write(Data("x".utf8), to: occupied))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["occupied"])
    }

    func testTightenOnlyRemovesBits() throws {
        let dir = try looseDir()
        let file = dir.appendingPathComponent("f")
        try Data("x".utf8).write(to: file)
        chmod(file.path, 0o644)
        SecureFile.tighten(file)
        XCTAssertEqual(mode(file), 0o600)
        chmod(file.path, 0o400)
        SecureFile.tighten(file)
        XCTAssertEqual(mode(file), 0o400, "tighten 不得放宽已经更严的权限")
        SecureFile.tighten(dir.appendingPathComponent("missing"))   // 不存在：空操作，不崩溃
    }

    // MARK: PrivateDirectory

    func testCreateMakesOnlyNewLevelsPrivate() throws {
        let dir = try looseDir()
        let nested = dir.appendingPathComponent("x/y")
        try withUmaskZero { try PrivateDirectory.create(nested) }
        XCTAssertEqual(mode(nested), 0o700)
        XCTAssertEqual(mode(dir.appendingPathComponent("x")), 0o700)
        XCTAssertEqual(mode(dir), 0o755)
        // 已存在：不改动（哪怕它很宽松）。
        chmod(nested.path, 0o755)
        try PrivateDirectory.create(nested)
        XCTAssertEqual(mode(nested), 0o755)
    }

    func testEnsureOwnedTightensExistingSubdirectory() throws {
        let dir = try looseDir()
        let snapshots = dir.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        chmod(snapshots.path, 0o755)
        try PrivateDirectory.ensureOwned(snapshots)
        XCTAssertEqual(mode(snapshots), 0o700)
        XCTAssertEqual(mode(dir), 0o755, "父目录不是我们的")
        // 路径上是个文件：不动它。
        let file = dir.appendingPathComponent("not-a-dir")
        try Data("x".utf8).write(to: file); chmod(file.path, 0o644)
        try PrivateDirectory.ensureOwned(file)
        XCTAssertEqual(mode(file), 0o644)
    }

    // MARK: 各组件落盘的权限（放在一个 0755 的 cow-root 里，umask 000）

    func testCowCloneAndMarkerAreOwnerOnly() throws {
        let dir = try looseDir()
        let base = dir.appendingPathComponent("base.raw")
        try Data(repeating: 7, count: 4096).write(to: base)
        chmod(base.path, 0o644)                       // 基础镜像通常是 0644
        let cows = dir.appendingPathComponent("cows")
        let lease = try withUmaskZero { () -> CowDiskManager.Lease in
            let manager = try CowDiskManager(root: cows)
            return try manager.createClone(source: base, sandboxID: .new(), domainID: CredentialDomainID("work"))
        }
        XCTAssertEqual(mode(cows), 0o700, "我们新建的 cow-root")
        XCTAssertEqual(mode(lease.cloneURL), 0o600, "clone 不得继承基础镜像的 0644")
        XCTAssertEqual(mode(CowDiskManager.domainMarkerURL(forClone: lease.cloneURL)), 0o600)
        XCTAssertEqual(mode(base), 0o644, "基础镜像本身不动")
        XCTAssertEqual(try CowDiskManager.recordedDomain(forClone: lease.cloneURL), CredentialDomainID("work"))
    }

    func testCowManagerDoesNotChmodAUserProvidedDirectory() throws {
        let dir = try looseDir()                      // 已存在、0755、不是我们建的
        let base = dir.appendingPathComponent("base.raw")
        try Data(repeating: 7, count: 1024).write(to: base)
        let manager = try CowDiskManager(root: dir)
        let lease = try manager.createClone(source: base, sandboxID: .new())
        XCTAssertEqual(mode(dir), 0o755, "用户提供的目录（可能是 $HOME）不得被 chmod")
        XCTAssertEqual(mode(lease.cloneURL), 0o600, "但里面的沙箱盘必须自己是 0600")
    }

    func testRegistryFileIsOwnerOnly() throws {
        let dir = try looseDir()
        let registry = try SandboxRegistry(root: dir)
        try withUmaskZero {
            try registry.upsert(RegisteredSandbox(sandboxID: .new(), bootID: .new(), status: .running,
                                                  clonePath: dir.appendingPathComponent("c").path,
                                                  hostPID: ProcessInfo.processInfo.processIdentifier))
        }
        XCTAssertEqual(mode(dir.appendingPathComponent("registry.json")), 0o600)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["registry.json", "registry.lock"])
    }

    func testSnapshotKeyAndSnapshotAreOwnerOnly() throws {
        let dir = try looseDir()
        let keyURL = dir.appendingPathComponent("snapshot.key")
        let store = SnapshotStore(keyURL: keyURL)
        let snap = dir.appendingPathComponent("snapshots/SB.snap")
        let metadata = SnapshotMetadata(sandboxID: "SB", bootID: "B", manifestDigest: "d", guestAssetVersion: 1,
                                        keyID: "k", createdAtUtc: "t", hostBuild: "h", payloadSha256: "", domainID: "default")
        try withUmaskZero { try store.seal(payload: Data("vm-state".utf8), metadata: metadata, to: snap) }
        XCTAssertEqual(mode(keyURL), 0o600)
        XCTAssertEqual(mode(snap), 0o600)
        XCTAssertEqual(mode(snap.deletingLastPathComponent()), 0o700, "快照目录归我们所有")
        XCTAssertEqual(try store.open(at: snap), Data("vm-state".utf8))
    }

    func testLooseExistingSnapshotKeyIsTightenedOnLoad() throws {
        let dir = try looseDir()
        let keyURL = dir.appendingPathComponent("snapshot.key")
        try Data(repeating: 9, count: 32).write(to: keyURL)
        chmod(keyURL.path, 0o644)
        _ = try SnapshotStore(keyURL: keyURL).loadOrCreateKey()
        XCTAssertEqual(mode(keyURL), 0o600)
        XCTAssertEqual(try Data(contentsOf: keyURL), Data(repeating: 9, count: 32), "内容不变")
    }

    func testSweepRemovesStaleAtomicWriteTemps() {
        let alive: (Int32) -> Bool = { _ in true }
        let name = ".SB.snap.tmp-\(UUID().uuidString)"
        XCTAssertEqual(SnapshotSweepPolicy.verdict(name: name, liveSandboxIDs: [], age: 1, isProcessAlive: alive), .keep)
        XCTAssertEqual(SnapshotSweepPolicy.verdict(name: name, liveSandboxIDs: [], age: SnapshotSweepPolicy.legacyGrace + 1,
                                                   isProcessAlive: alive), .remove)
        XCTAssertEqual(SnapshotSweepPolicy.verdict(name: ".DS_Store", liveSandboxIDs: [], age: 1e9, isProcessAlive: alive), .ignore)
    }

    // MARK: daemon socket

    func testPeerPolicy() {
        XCTAssertTrue(DaemonPeerPolicy.allows(peerUID: 501, daemonUID: 501))
        XCTAssertTrue(DaemonPeerPolicy.allows(peerUID: 0, daemonUID: 501), "root 本来就能接管进程")
        XCTAssertFalse(DaemonPeerPolicy.allows(peerUID: 502, daemonUID: 501))
        XCTAssertFalse(DaemonPeerPolicy.allows(peerUID: 501, daemonUID: 502))
        XCTAssertFalse(DaemonPeerPolicy.admits(fd: -1), "取不到对端身份必须拒绝")
    }

    func testPeerUIDOfARealConnectionIsOurs() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertEqual(DaemonPeerPolicy.peerUID(of: fds[0]), geteuid())
        XCTAssertTrue(DaemonPeerPolicy.admits(fd: fds[0]))
        XCTAssertFalse(DaemonPeerPolicy.admits(fd: fds[0], daemonUID: geteuid() &+ 1), "对端不是 daemon 的用户")
    }

    func testDaemonSocketIsOwnerOnlyEvenUnderPermissiveUmask() throws {
        let dir = URL(fileURLWithPath: "/tmp/dbxp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let sock = dir.appendingPathComponent("d.sock").path
        let daemon = SandboxDaemon(sockPath: sock, supportRoot: dir)
        let done = DispatchSemaphore(value: 0)
        let previous = umask(0)
        Thread { try? daemon.serveLoop(); done.signal() }.start()
        var ready = false
        for _ in 0..<250 {
            if (try? DaemonClient.send(request: DaemonRequest(kind: "ps"), sockPath: sock)) != nil { ready = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        umask(previous)
        XCTAssertTrue(ready)
        XCTAssertEqual(mode(URL(fileURLWithPath: sock)), 0o600)
        XCTAssertTrue(try DaemonClient.send(request: DaemonRequest(kind: "shutdown"), sockPath: sock).ok)
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
    }
}
