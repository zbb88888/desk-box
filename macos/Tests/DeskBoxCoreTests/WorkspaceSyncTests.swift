import XCTest
@testable import DeskBoxVZ
@testable import DeskBoxCore

/// M2-1: workspace snapshot build 必须 fail-closed（INV-05 的宿主侧执法）。
final class WorkspaceSyncTests: XCTestCase {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskbox-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testBuildSnapshotEnumeratesRegularFilesAndDigests() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "world".write(to: root.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)

        let snapshot = try WorkspaceSyncService.buildSnapshot(root: root)
        XCTAssertEqual(snapshot.files.count, 2)
        XCTAssertEqual(snapshot.files.map(\.relativePath).sorted(), ["a.txt", "sub/b.txt"])
        XCTAssertEqual(snapshot.totalBytes, 10)
        for file in snapshot.files {
            XCTAssertEqual(file.sha256Hex.count, 64)
            XCTAssertTrue(file.mode == 0o644 || file.mode == 0o755)
        }
    }

    func testSymlinkIsRejected() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        XCTAssertThrowsError(try WorkspaceSyncService.buildSnapshot(root: root)) { error in
            guard case .symlinkRejected? = error as? WorkspaceSyncError else {
                return XCTFail("expected symlinkRejected, got \(error)")
            }
        }
    }

    func testFileSizeCapEnforced() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 0x41, count: 1024)
        try data.write(to: root.appendingPathComponent("big.bin"))
        var policy = WorkspaceSyncPolicy()
        policy.maxFileBytes = 512
        XCTAssertThrowsError(try WorkspaceSyncService.buildSnapshot(root: root, policy: policy)) { error in
            guard case .excessiveFileBytes? = error as? WorkspaceSyncError else {
                return XCTFail("expected excessiveFileBytes, got \(error)")
            }
        }
    }

    func testTotalBytesCapEnforced() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 0x42, count: 700)
        try data.write(to: root.appendingPathComponent("a.bin"))
        try data.write(to: root.appendingPathComponent("b.bin"))
        var policy = WorkspaceSyncPolicy()
        policy.maxTotalBytes = 1000
        XCTAssertThrowsError(try WorkspaceSyncService.buildSnapshot(root: root, policy: policy)) { error in
            guard case .excessiveTotalBytes? = error as? WorkspaceSyncError else {
                return XCTFail("expected excessiveTotalBytes, got \(error)")
            }
        }
    }

    func testMissingRootRejected() {
        XCTAssertThrowsError(try WorkspaceSyncService.buildSnapshot(root: URL(fileURLWithPath: "/nonexistent/path"))) { error in
            guard case .rootMissing? = error as? WorkspaceSyncError else {
                return XCTFail("expected rootMissing, got \(error)")
            }
        }
    }
}

/// M37：快照内容只读一次、且经由逐级 O_NOFOLLOW 的描述符（INV-05 的 TOCTOU）。
final class WorkspaceSnapshotRaceTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskbox-wsrace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func openRoot(_ url: URL) -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        addTeardownBlock { close(fd) }
        return fd
    }

    func testSnapshotCarriesTheBytesItHashed() throws {
        let root = try makeRoot()
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data().write(to: root.appendingPathComponent("empty"))
        let script = root.appendingPathComponent("run.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        chmod(script.path, 0o750)
        let snapshot = try WorkspaceSyncService.buildSnapshot(root: root)
        let byPath = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.relativePath, $0) })
        XCTAssertEqual(byPath["a.txt"]?.contents, Data("hello".utf8))
        XCTAssertEqual(byPath["a.txt"]?.sha256Hex, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(byPath["a.txt"]?.bytes, 5)
        XCTAssertEqual(byPath["empty"]?.contents, Data())
        XCTAssertEqual(byPath["run.sh"]?.mode, 0o755)
        XCTAssertEqual(byPath["a.txt"]?.mode, 0o644)
        XCTAssertEqual(snapshot.totalBytes, UInt64(snapshot.files.reduce(0) { $0 + $1.contents.count }))
    }

    func testSwappingAFileForASymlinkAfterTheSnapshotCannotChangeWhatIsPushed() throws {
        // 回归：推送阶段曾按路径重新读取文件（跟随符号链接、不比对摘要）。
        let root = try makeRoot()
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("deskbox-secret-\(UUID().uuidString)")
        try Data("TOP-SECRET-HOST-FILE".utf8).write(to: secret)
        addTeardownBlock { try? FileManager.default.removeItem(at: secret) }
        let file = root.appendingPathComponent("notes.txt")
        try Data("benign".utf8).write(to: file)

        let snapshot = try WorkspaceSyncService.buildSnapshot(root: root)

        // 校验之后，把文件换成指向 workspace 之外的符号链接。
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
        XCTAssertEqual(try Data(contentsOf: file), Data("TOP-SECRET-HOST-FILE".utf8), "对照：按路径读确实会读到秘密")

        XCTAssertEqual(snapshot.files.map(\.contents), [Data("benign".utf8)], "推送用的是快照里的字节")
    }

    func testSecureReadRejectsSymlinksAtEveryLevel() throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        try Data("outside".utf8).write(to: outside.appendingPathComponent("f"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("real/deep"), withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: root.appendingPathComponent("real/deep/f"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linkfile"), withDestinationURL: outside.appendingPathComponent("f"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linkdir"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("real/linkmid"), withDestinationURL: outside)
        // 指向 workspace 内部的链接同样拒绝（不做「看起来安全」的例外）。
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("inner"), withDestinationURL: root.appendingPathComponent("real/deep/f"))
        let fd = openRoot(root)

        XCTAssertEqual(try WorkspaceSyncService.secureRead(rootFD: fd, relativePath: "real/deep/f", maxBytes: 100).data, Data("inside".utf8))
        for path in ["linkfile", "linkdir/f", "real/linkmid/f", "inner"] {
            XCTAssertThrowsError(try WorkspaceSyncService.secureRead(rootFD: fd, relativePath: path, maxBytes: 100), path) {
                XCTAssertEqual($0 as? WorkspaceSyncError, .symlinkRejected(path))
            }
        }
    }

    func testSecureReadRejectsEscapesSpecialFilesAndOversize() throws {
        let root = try makeRoot()
        try Data(repeating: 0x41, count: 11).write(to: root.appendingPathComponent("big"))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("fifo").path, 0o644), 0)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        let fd = openRoot(root)

        for path in ["../etc/passwd", "a/../../x", "./big", ""] {
            XCTAssertThrowsError(try WorkspaceSyncService.secureRead(rootFD: fd, relativePath: path, maxBytes: 100), path) {
                XCTAssertEqual($0 as? WorkspaceSyncError, .pathEscapesRoot(path))
            }
        }
        XCTAssertThrowsError(try WorkspaceSyncService.secureRead(rootFD: fd, relativePath: "big", maxBytes: 10)) {
            XCTAssertEqual($0 as? WorkspaceSyncError, .excessiveFileBytes("big", 11, 10))
        }
        XCTAssertEqual(try WorkspaceSyncService.secureRead(rootFD: fd, relativePath: "big", maxBytes: 11).data.count, 11)
        // FIFO：必须立刻被拒绝，而不是挂在 open/read 上。
        let started = Date()
        XCTAssertThrowsError(try WorkspaceSyncService.secureRead(rootFD: fd, relativePath: "fifo", maxBytes: 100)) {
            XCTAssertEqual($0 as? WorkspaceSyncError, .unexpectedItemType("fifo"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertThrowsError(try WorkspaceSyncService.secureRead(rootFD: fd, relativePath: "dir", maxBytes: 100)) {
            XCTAssertEqual($0 as? WorkspaceSyncError, .unexpectedItemType("dir"))
        }
        XCTAssertThrowsError(try WorkspaceSyncService.secureRead(rootFD: fd, relativePath: "missing", maxBytes: 100)) {
            XCTAssertEqual($0 as? WorkspaceSyncError, .changedDuringSnapshot("missing"))
        }
    }

    func testConcurrentSwapNeverLeaksOutsideContent() throws {
        // 性质测试：另一个线程不停地把 workspace 里的文件在「普通文件」与「指向秘密的符号链接」之间来回切换，
        // 中间一级目录也在「真实目录」与「指向外部的符号链接」之间切换。
        // 不变量：每一次快照要么抛错，要么只包含 workspace 自己的内容——**绝不**包含秘密。
        let root = try makeRoot()
        let outside = try makeRoot()
        let secret = Data("TOP-SECRET-\(UUID().uuidString)".utf8)
        try secret.write(to: outside.appendingPathComponent("f.txt"))
        let file = root.appendingPathComponent("f.txt")
        let sub = root.appendingPathComponent("sub")
        let benign = Data("benign".utf8)

        let stop = Box(false)
        let flipper = Thread {
            let fm = FileManager.default
            var i = 0
            while !stop.value {
                i += 1
                try? fm.removeItem(at: file)
                if i % 2 == 0 { try? benign.write(to: file) }
                else { try? fm.createSymbolicLink(at: file, withDestinationURL: outside.appendingPathComponent("f.txt")) }
                try? fm.removeItem(at: sub)
                if i % 3 == 0 { try? fm.createSymbolicLink(at: sub, withDestinationURL: outside) }
                else {
                    try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
                    try? benign.write(to: sub.appendingPathComponent("f.txt"))
                }
            }
        }
        flipper.start()
        defer { stop.value = true; while !flipper.isFinished { usleep(1000) } }

        var built = 0, rejected = 0
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            do {
                let snapshot = try WorkspaceSyncService.buildSnapshot(root: root)
                built += 1
                for f in snapshot.files {
                    XCTAssertNotEqual(f.contents, secret, "快照里出现了 workspace 之外的内容：\(f.relativePath)")
                    XCTAssertEqual(f.contents, benign, f.relativePath)
                }
            } catch {
                rejected += 1
            }
        }
        XCTAssertGreaterThan(built + rejected, 50, "迭代次数太少，测试没有意义")
        XCTAssertGreaterThan(rejected, 0, "从未撞上竞争窗口——测试没有施加到压力（built=\(built)）")
        XCTAssertGreaterThan(built, 0, "从未成功过——无法证明成功路径（rejected=\(rejected)）")
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
