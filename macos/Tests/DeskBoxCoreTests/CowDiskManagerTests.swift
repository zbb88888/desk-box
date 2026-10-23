import XCTest
@testable import DeskBoxVZ
@testable import DeskBoxCore

final class CowDiskManagerTests: XCTestCase {
    func testCloneIsIndependentAndCanBeRemoved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskbox-cow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("base.vhd")
        try Data("base".utf8).write(to: source)
        let manager = try CowDiskManager(root: root.appendingPathComponent("cows"))
        let sandbox = SandboxID.new()

        do {
            let lease = try manager.createClone(source: source, sandboxID: sandbox)
            XCTAssertTrue(FileManager.default.fileExists(atPath: lease.cloneURL.path))
            XCTAssertEqual(try Data(contentsOf: lease.cloneURL), Data("base".utf8))
            try Data("clone".utf8).write(to: lease.cloneURL)
            XCTAssertEqual(try Data(contentsOf: source), Data("base".utf8))
            try manager.removeClone(lease)
            XCTAssertFalse(FileManager.default.fileExists(atPath: lease.cloneURL.path))
        } catch let error as SandboxFailure where error.reason == .platformCowUnavailable {
            // The test runner may use a non-APFS temporary volume. The
            // production contract is still fail-closed in that case.
            throw XCTSkip("temporary volume does not support APFS clonefile: \(error)")
        }
    }

    func testExistingCloneDoesNotGetOverwritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskbox-cow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("base.vhd")
        try Data("base".utf8).write(to: source)
        let manager = try CowDiskManager(root: root.appendingPathComponent("cows"))
        let sandbox = SandboxID.new()

        do {
            let first = try manager.createClone(source: source, sandboxID: sandbox)
            XCTAssertThrowsError(try manager.createClone(source: source, sandboxID: sandbox)) { error in
                XCTAssertEqual((error as? SandboxFailure)?.reason, .platformCowUnavailable)
            }
            try manager.removeClone(first)
        } catch let error as SandboxFailure where error.reason == .platformCowUnavailable {
            throw XCTSkip("temporary volume does not support APFS clonefile: \(error)")
        }
    }
}
