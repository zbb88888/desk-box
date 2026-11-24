import XCTest
import Foundation
@testable import DeskBoxVZ

/// M25：`DBX_SUPPORT_ROOT` 解析（fail-closed）。
final class DeskBoxPathsTests: XCTestCase {
    private let key = DeskBoxPaths.supportRootEnvKey

    func testDefaultIsApplicationSupportDeskBox() throws {
        let url = try DeskBoxPaths.resolveSupportRoot(environment: [:])
        XCTAssertTrue(url.path.hasSuffix("/Library/Application Support/DeskBox"), url.path)
        // 空串等同未设置（shell 里 `DBX_SUPPORT_ROOT= cmd` 不应被当成根目录 "/"）。
        XCTAssertEqual(try DeskBoxPaths.resolveSupportRoot(environment: [key: ""]), url)
    }

    func testAbsoluteOverrideIsUsedVerbatim() throws {
        let url = try DeskBoxPaths.resolveSupportRoot(environment: [key: "/tmp/dbx-x/support"])
        XCTAssertEqual(url.path, "/tmp/dbx-x/support")
    }

    func testInvalidOverridesAreRejectedNotIgnored() {
        for bad in ["relative/dir", "./x", "~/DeskBox", " /tmp/x"] {
            XCTAssertThrowsError(try DeskBoxPaths.resolveSupportRoot(environment: [key: bad]), bad) {
                XCTAssertEqual($0 as? DeskBoxPaths.PathError, .notAbsolute(bad))
            }
        }
        for bad in ["/tmp/../etc", "/tmp/x/..", "/../x"] {
            XCTAssertThrowsError(try DeskBoxPaths.resolveSupportRoot(environment: [key: bad]), bad) {
                XCTAssertEqual($0 as? DeskBoxPaths.PathError, .containsParentTraversal(bad))
            }
        }
        // 名字里带两个点的普通目录不是穿越。
        XCTAssertNoThrow(try DeskBoxPaths.resolveSupportRoot(environment: [key: "/tmp/a..b/c"]))
    }

    func testOverridePointingAtFileIsRejected() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dbx-paths-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try DeskBoxPaths.resolveSupportRoot(environment: [key: file.path])) {
            XCTAssertEqual($0 as? DeskBoxPaths.PathError, .notADirectory(file.path))
        }
    }

    func testDerivedPathsHangOffSupportRoot() {
        let root = DeskBoxPaths.supportRoot.path
        XCTAssertEqual(DeskBoxPaths.cowRoot.path, root + "/cows")
        XCTAssertEqual(DeskBoxPaths.snapshotKeyURL.path, root + "/snapshot.key")
        XCTAssertEqual(DeskBoxPaths.daemonSocketURL.path, root + "/dbxd.sock")
    }
}
