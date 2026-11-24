import XCTest
import Foundation
@testable import dbx_poc

/// M34：签名 / 发布 / 校验类子命令的参数规格，以及私钥文件权限。
final class ReleaseCLITests: XCTestCase {

    private func parse(_ spec: CLISpec, _ args: [String]) throws -> CLIParsed { try CLIArgs.parse(args, spec: spec) }

    private func assertRejected(_ spec: CLISpec, _ args: [String], contains needle: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(spec, args), file: file, line: line) {
            XCTAssertTrue("\($0)".contains(needle), "期望包含「\(needle)」，实际：\($0)", file: file, line: line)
        }
    }

    // MARK: 拼错的选项不再被静默忽略（每一条都对应一个会放宽安全门槛或写错文件的真实后果）

    func testTyposThatUsedToWeakenSecurityAreRejected() {
        // 防回滚下限悄悄变回默认的 1
        assertRejected(ReleaseCLISpecs.publish,
                       ["--channel", "/c", "--manifest", "/m", "--sbom", "/s", "--release-keys", "/k", "--min-version-flor", "5"],
                       contains: "publish: unknown option '--min-version-flor'")
        // 用旧版本号签名
        assertRejected(ReleaseCLISpecs.signManifest, ["--manifest", "/m", "--key", "/k", "--output", "/o", "--asset-versoin", "7"],
                       contains: "sign-manifest: unknown option '--asset-versoin'")
        // 原地覆盖 --base
        assertRejected(ReleaseCLISpecs.rotateReleaseKey, ["--base", "/b", "--new-key", "/n", "--ouput", "/o"],
                       contains: "rotate-release-key: unknown option '--ouput'")
        assertRejected(ReleaseCLISpecs.revokeReleaseKey, ["--base", "/b", "--key-id", "abc", "--ouput", "/o"],
                       contains: "revoke-release-key: unknown option '--ouput'")
        // 用内置版本比较
        assertRejected(ReleaseCLISpecs.checkUpdate, ["--channel", "/c", "--current-versoin", "0.1.0"],
                       contains: "check-update: unknown option '--current-versoin'")
        // 以为做了 release-keys 校验，其实走的是无链校验
        assertRejected(ReleaseCLISpecs.validateAssets, ["/m.json", "--release-key", "/k"],
                       contains: "validate-assets: unknown option '--release-key'")
        // sbom 绑定被悄悄丢掉
        assertRejected(ReleaseCLISpecs.makeManifest, ["--kernel", "/k", "--root-disk", "/r", "--output", "/o", "--sbom-digset", "abc"],
                       contains: "make-manifest: unknown option '--sbom-digset'")
        assertRejected(ReleaseCLISpecs.launch, ["/m.json", "--memroy-mib", "512"], contains: "launch: unknown option")
    }

    func testValueCannotBeAnotherOptionOrEmpty() {
        assertRejected(ReleaseCLISpecs.signManifest, ["--manifest", "--key", "/k", "--output", "/o"],
                       contains: "missing value for --manifest (got option '--key')")
        assertRejected(ReleaseCLISpecs.publish, ["--channel", ""], contains: "publish: empty value for --channel")
        assertRejected(ReleaseCLISpecs.genReleaseKey, ["--output-key"], contains: "gen-release-key: missing value for --output-key")
        assertRejected(ReleaseCLISpecs.genGuestSignKey, ["--output-key", ""], contains: "empty value for --output-key")
    }

    func testVersionIntegersAreStrict() throws {
        for bad in ["-1", "abc", "1.5", "", " 3", "99999999999"] where !bad.isEmpty {
            let p = try parse(ReleaseCLISpecs.publish, ["--min-version-floor", bad])
            XCTAssertThrowsError(try p.int("--min-version-floor", in: ReleaseCLISpecs.versionRange), bad)
        }
        let ok = try parse(ReleaseCLISpecs.publish, ["--min-version-floor", "5"])
        XCTAssertEqual(try ok.int("--min-version-floor", in: ReleaseCLISpecs.versionRange), 5)
        XCTAssertNil(try parse(ReleaseCLISpecs.publish, []).int("--min-version-floor", in: ReleaseCLISpecs.versionRange))
    }

    func testDuplicateOptionsRejected() {
        assertRejected(ReleaseCLISpecs.signManifest, ["--key", "/a", "--key", "/b"], contains: "option --key given more than once")
    }

    func testCommandsWithoutArgumentsRejectStrayOnes() {
        assertRejected(ReleaseCLISpecs.version, ["--json"], contains: "version: unknown option")
        assertRejected(ReleaseCLISpecs.capcheck, ["extra"], contains: "capcheck: unexpected argument 'extra'")
        XCTAssertNoThrow(try parse(ReleaseCLISpecs.version, []))
    }

    // MARK: 位置参数

    func testPositionalCommands() throws {
        XCTAssertEqual(try parse(ReleaseCLISpecs.verifyChannel, ["/c.json"]).positional(0), "/c.json")
        assertRejected(ReleaseCLISpecs.verifyChannel, [], contains: "verify-channel: channel path required")
        assertRejected(ReleaseCLISpecs.verifyChannel, ["/a", "/b"], contains: "unexpected argument '/b'")
        assertRejected(ReleaseCLISpecs.verifySbom, ["--strict", "/s.json"], contains: "verify-sbom: unknown option")
        // launch：manifest 不必是第一个参数。
        let launch = try parse(ReleaseCLISpecs.launch, ["--cpus", "2", "/m.json", "--minimal-vz"])
        XCTAssertEqual(launch.positional(0), "/m.json")
        XCTAssertTrue(launch.flag("--minimal-vz"))
        XCTAssertEqual(try launch.int("--cpus", in: 1...256), 2)
        let validate = try parse(ReleaseCLISpecs.validateAssets, ["--release-keys", "/k", "/m.json", "--allow-unsigned-manifest"])
        XCTAssertEqual(validate.positional(0), "/m.json")
        XCTAssertEqual(validate.string("--release-keys"), "/k")
    }

    func testCheckUpdateChannelPath() throws {
        // 回归：此前没有 --channel 时取「第一个不以 -- 开头的参数」，会把 --current-version 的值当成 channel。
        let onlyVersion = try parse(ReleaseCLISpecs.checkUpdate, ["--current-version", "1.0"])
        XCTAssertThrowsError(try ReleaseCLISpecs.channelPath(onlyVersion)) {
            XCTAssertTrue("\($0)".contains("channel path required"), "\($0)")
        }
        XCTAssertEqual(try ReleaseCLISpecs.channelPath(parse(ReleaseCLISpecs.checkUpdate, ["--channel", "/c.json", "--current-version", "1.0"])), "/c.json")
        XCTAssertEqual(try ReleaseCLISpecs.channelPath(parse(ReleaseCLISpecs.checkUpdate, ["--current-version", "1.0", "/c.json", "--json"])), "/c.json")
        // 两种方式同时给：拒绝，不猜。
        XCTAssertThrowsError(try ReleaseCLISpecs.channelPath(parse(ReleaseCLISpecs.checkUpdate, ["--channel", "/a", "/b"]))) {
            XCTAssertTrue("\($0)".contains("already given via --channel"), "\($0)")
        }
        assertRejected(ReleaseCLISpecs.checkUpdate, ["/a", "/b"], contains: "unexpected argument '/b'")
    }

    func testOptionalPositionalAccessor() throws {
        let none = try parse(ReleaseCLISpecs.checkUpdate, [])
        XCTAssertNil(none.optionalPositional(0))
        assertRejected(ReleaseCLISpecs.checkUpdate, [""], contains: "check-update: empty channel path")
    }

    func testEverySpecIsSelfConsistent() {
        for spec in ReleaseCLISpecs.all {
            XCTAssertTrue(spec.valueOptions.isDisjoint(with: spec.flags), spec.command)
            XCTAssertTrue(spec.allOptions.allSatisfy { $0.hasPrefix("--") }, spec.command)
            for option in spec.allOptions {
                XCTAssertTrue(spec.usage.contains(option), "\(spec.command) usage 缺 \(option)")
            }
            XCTAssertTrue(spec.usage.hasPrefix("dbx-poc \(spec.command)"), spec.command)
        }
        let names = ReleaseCLISpecs.all.map(\.command) + DaemonCLISpecs.all.map(\.command)
        XCTAssertEqual(Set(names).count, names.count, "子命令名重复")
    }

    // MARK: 私钥文件

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbx-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testPrivateKeyIsWrittenOwnerOnly() throws {
        let dir = try tempDir()
        let key = dir.appendingPathComponent("nested/sign-key.local")
        try PrivateKeyFile.write("private:abc\n", to: key)
        XCTAssertEqual(try mode(key), 0o600)
        XCTAssertEqual(try String(contentsOf: key, encoding: .utf8), "private:abc\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: key.deletingLastPathComponent().path), ["sign-key.local"],
                       "不得留下临时文件")
    }

    func testOverwritingALooselyPermissionedKeyTightensIt() throws {
        // 回归：旧版本生成的私钥是 0644。重新生成后必须是 0600，而不是沿用旧文件的权限。
        let dir = try tempDir()
        let key = dir.appendingPathComponent("dev-sign-key.local")
        try Data("private:old\n".utf8).write(to: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key.path)
        try PrivateKeyFile.write("private:new\n", to: key)
        XCTAssertEqual(try mode(key), 0o600)
        XCTAssertEqual(try String(contentsOf: key, encoding: .utf8), "private:new\n")
    }

    func testPrivateKeyIgnoresPermissiveUmask() throws {
        let dir = try tempDir()
        let previous = umask(0)          // 最宽松的 umask
        defer { umask(previous) }
        let key = dir.appendingPathComponent("k.local")
        try PrivateKeyFile.write("private:x\n", to: key)
        XCTAssertEqual(try mode(key), 0o600)
    }

    func testPrivateKeyWriteFailureLeavesNothingBehind() throws {
        let dir = try tempDir()
        // 目标是一个非空目录：rename 必然失败。
        let target = dir.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: target.appendingPathComponent("f"))
        XCTAssertThrowsError(try PrivateKeyFile.write("private:x\n", to: target))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["occupied"], "失败后不得留下临时私钥文件")
    }
}
