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
