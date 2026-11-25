import XCTest
@testable import dbx_poc

/// M45：生成密钥时不悄悄覆盖已有的私钥。
final class PrivateKeyOverwriteTests: XCTestCase {
    func testRefusalDecision() {
        XCTAssertNil(PrivateKeyFile.overwriteRefusal(path: "/k", exists: false, force: false))
        XCTAssertNil(PrivateKeyFile.overwriteRefusal(path: "/k", exists: false, force: true))
        XCTAssertNil(PrivateKeyFile.overwriteRefusal(path: "/k", exists: true, force: true))
        let refusal = PrivateKeyFile.overwriteRefusal(path: "/keys/release.local", exists: true, force: false)
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal!.hasPrefix("DBX-KEY-EXISTS: "), refusal!)
        XCTAssertTrue(refusal!.contains("/keys/release.local"), refusal!)
        XCTAssertTrue(refusal!.contains("--force"), refusal!)
    }

    func testWriteRefusesExistingFileAndLeavesItUntouched() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbx-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let key = dir.appendingPathComponent("sign.local")

        try PrivateKeyFile.write("private:first\n", to: key, force: false)
        XCTAssertEqual(try String(contentsOf: key, encoding: .utf8), "private:first\n")

        XCTAssertThrowsError(try PrivateKeyFile.write("private:second\n", to: key, force: false)) {
            XCTAssertTrue("\($0)".contains("DBX-KEY-EXISTS"), "\($0)")
        }
        XCTAssertEqual(try String(contentsOf: key, encoding: .utf8), "private:first\n", "被拒绝时旧私钥原样保留")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["sign.local"], "没有遗留临时文件")

        try PrivateKeyFile.write("private:third\n", to: key, force: true)
        XCTAssertEqual(try String(contentsOf: key, encoding: .utf8), "private:third\n")
        let mode = try FileManager.default.attributesOfItem(atPath: key.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testDanglingSymlinkCountsAsExisting() throws {
        // 指向别处的（哪怕是悬空的）链接也不能被悄悄替换。
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbx-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("link.local")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: dir.appendingPathComponent("nowhere").path)
        XCTAssertThrowsError(try PrivateKeyFile.write("private:x\n", to: link, force: false)) {
            XCTAssertTrue("\($0)".contains("DBX-KEY-EXISTS"), "\($0)")
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       dir.appendingPathComponent("nowhere").path, "链接本身没被动")
    }

    func testCLISpecsAcceptForce() throws {
        let plain = try CLIArgs.parse(["--output-key", "/k"], spec: ReleaseCLISpecs.genGuestSignKey)
        XCTAssertFalse(plain.flag("--force"))
        let forced = try CLIArgs.parse(["--force", "--output-key", "/k"], spec: ReleaseCLISpecs.genReleaseKey)
        XCTAssertTrue(forced.flag("--force"))
        XCTAssertThrowsError(try CLIArgs.parse(["--output-key", "/k", "--overwrite"], spec: ReleaseCLISpecs.genGuestSignKey))
    }
}
