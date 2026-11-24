import XCTest
import Foundation
@testable import dbx_poc

/// M27：daemon 子命令参数解析（fail-closed）。
final class CLIArgsTests: XCTestCase {

    private func assertUsageError(_ body: @autoclosure () throws -> Any, contains needle: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertTrue("\($0)".contains(needle), "期望包含「\(needle)」，实际：\($0)", file: file, line: line)
        }
    }

    // MARK: 位置无关

    func testOptionsMayAppearBeforeOrAfterPositionals() throws {
        // 上一轮真实踩到的坑：`exec --timeout 5 <id>` 曾把 "--timeout" 当成沙箱 id。
        for args in [
            ["--daemon-sock", "/s", "--timeout", "5", "SB", "--", "/bin/echo", "hi"],
            ["SB", "--timeout", "5", "--daemon-sock", "/s", "--", "/bin/echo", "hi"],
            ["--timeout=5", "SB", "--daemon-sock=/s", "--", "/bin/echo", "hi"],
        ] {
            let inv = try DaemonCLI.exec(args)
            XCTAssertEqual(inv.request.sandboxId, "SB", "\(args)")
            XCTAssertEqual(inv.request.timeoutSeconds, 5)
            XCTAssertEqual(inv.sock, "/s")
            XCTAssertEqual(inv.request.argv ?? [], ["/bin/echo", "hi"])
        }
        let run = try DaemonCLI.run(["--memory-mib", "1024", "--domain", "work", "/m.json", "--cpus", "2"])
        XCTAssertEqual(run.request.manifestPath, "/m.json")
        XCTAssertEqual(run.request.memoryMiB, 1024)
        XCTAssertEqual(run.request.cpus, 2)
        XCTAssertEqual(run.request.domain, "work")
        XCTAssertNil(run.sock)
    }

    // MARK: `--` 之后原样透传

    func testPassthroughIsVerbatim() throws {
        // guest 命令行里出现宿主同名选项、甚至再出现一个 `--`，都不得被解析或吃掉。
        let guest = ["/bin/sh", "-c", "echo $1", "--timeout", "9", "--env", "A=B", "--domain", "work",
                     "--daemon-sock", "/evil", "--", "--force", ""]
        let inv = try DaemonCLI.exec(["SB", "--"] + guest)
        XCTAssertEqual(inv.request.argv ?? [], guest)
        XCTAssertNil(inv.request.timeoutSeconds)
        XCTAssertNil(inv.request.env)
        XCTAssertNil(inv.request.domain)
        XCTAssertNil(inv.sock, "guest 参数里的 --daemon-sock 不得改变宿主连接目标")
    }

    func testExecRequiresPassthroughArgv() {
        assertUsageError(try DaemonCLI.exec(["SB"]), contains: "exec requires argv via '-- ...'")
        assertUsageError(try DaemonCLI.exec(["SB", "--"]), contains: "exec requires argv via '-- ...'")
        // 没有 `--` 时多出来的词不是 guest argv，而是多余的位置参数。
        assertUsageError(try DaemonCLI.exec(["SB", "/bin/echo"]), contains: "unexpected argument '/bin/echo'")
    }

    func testDoubleDashRejectedWhereNotAllowed() {
        assertUsageError(try DaemonCLI.rm(["SB", "--", "x"]), contains: "rm: unexpected '--'")
    }

    // MARK: 缺值 / 空值不得回落默认

    func testMissingValueIsAnError() {
        assertUsageError(try DaemonCLI.bare(["--daemon-sock"], spec: DaemonCLISpecs.shutdown, kind: "shutdown"),
                         contains: "shutdown: missing value for --daemon-sock")
        assertUsageError(try DaemonCLI.rm(["SB", "--daemon-sock", "--force"]),
                         contains: "missing value for --daemon-sock (got option '--force')")
        assertUsageError(try DaemonCLI.exec(["SB", "--timeout", "--", "/bin/echo"]),
                         contains: "missing value for --timeout")
        assertUsageError(try DaemonCLI.run(["/m.json", "--memory-mib", "--cpus=2"]),
                         contains: "missing value for --memory-mib")
    }

    func testEmptyValueIsAnError() {
        // `--daemon-sock "$UNSET"`：以前静默连到默认 socket——shutdown 会关掉用户真实的 daemon。
        assertUsageError(try DaemonCLI.bare(["--daemon-sock", ""], spec: DaemonCLISpecs.shutdown, kind: "shutdown"),
                         contains: "shutdown: empty value for --daemon-sock")
        assertUsageError(try DaemonCLI.bare(["--daemon-sock="], spec: DaemonCLISpecs.ps, kind: "ps"),
                         contains: "ps: empty value for --daemon-sock")
        assertUsageError(try DaemonCLI.daemonSocket(["--daemon-sock", ""]), contains: "daemon: empty value")
        assertUsageError(try DaemonCLI.rm([""]), contains: "rm: empty sandbox id")
        assertUsageError(try DaemonCLI.sweepCowRoot(["--cow-root", ""]), contains: "sweep: empty value for --cow-root")
    }

    func testSockIsNilOnlyWhenOptionAbsent() throws {
        XCTAssertNil(try DaemonCLI.bare([], spec: DaemonCLISpecs.ps, kind: "ps").sock)
        XCTAssertEqual(try DaemonCLI.bare(["--daemon-sock", "/x"], spec: DaemonCLISpecs.ps, kind: "ps").sock, "/x")
        XCTAssertNil(try DaemonCLI.daemonSocket([]))
        XCTAssertNil(try DaemonCLI.sweepCowRoot([]))
        XCTAssertEqual(try DaemonCLI.sweepCowRoot(["--cow-root", "/a/b/../c"])?.path, "/a/c")
    }

    // MARK: 未知 / 重复 / 非法

    func testUnknownOptionsAreRejected() {
        assertUsageError(try DaemonCLI.rm(["SB", "--froce"]), contains: "rm: unknown option '--froce'")
        assertUsageError(try DaemonCLI.run(["/m.json", "--memroy-mib", "512"]), contains: "run: unknown option '--memroy-mib'")
        assertUsageError(try DaemonCLI.bare(["-v"], spec: DaemonCLISpecs.ps, kind: "ps"), contains: "ps: unknown option '-v'")
        assertUsageError(try DaemonCLI.single(["SB", "--force"], spec: DaemonCLISpecs.stop, kind: "stop"),
                         contains: "stop: unknown option '--force'")
        assertUsageError(try DaemonCLI.daemonSocket(["--daemon-sok", "/x"]), contains: "daemon: unknown option")
    }

    func testDuplicateOptionRejectedButEnvRepeats() throws {
        assertUsageError(try DaemonCLI.rm(["SB", "--daemon-sock", "/a", "--daemon-sock", "/b"]),
                         contains: "option --daemon-sock given more than once")
        let inv = try DaemonCLI.exec(["SB", "--env", "A=1", "--env", "B=x=y", "--env", "A=2", "--", "/bin/sh"])
        XCTAssertEqual(inv.request.env ?? [:], ["A": "2", "B": "x=y"])
    }

    func testEnvMustBeKeyValue() {
        assertUsageError(try DaemonCLI.exec(["SB", "--env", "NOEQUALS", "--", "/bin/sh"]), contains: "invalid --env 'NOEQUALS'")
        assertUsageError(try DaemonCLI.exec(["SB", "--env", "=v", "--", "/bin/sh"]), contains: "invalid --env '=v'")
        XCTAssertEqual(try DaemonCLI.exec(["SB", "--env", "EMPTY=", "--", "/bin/sh"]).request.env ?? [:], ["EMPTY": ""])
    }

    func testIntegersAreStrict() {
        for bad in ["4G", "abc", "0", "-1", "1.5", "+5", " 5", "５", "99999999999999999999"] {
            assertUsageError(try DaemonCLI.run(["/m.json", "--memory-mib", bad]), contains: "invalid value for --memory-mib")
        }
        assertUsageError(try DaemonCLI.run(["/m.json", "--cpus", "0"]), contains: "invalid value for --cpus")
        assertUsageError(try DaemonCLI.run(["/m.json", "--cpus", "257"]), contains: "invalid value for --cpus")
        assertUsageError(try DaemonCLI.exec(["SB", "--timeout", "0", "--", "/bin/sh"]), contains: "invalid value for --timeout")
        assertUsageError(try DaemonCLI.exec(["SB", "--timeout", "86401", "--", "/bin/sh"]), contains: "invalid value for --timeout")
    }

    func testFlagDoesNotTakeValue() {
        assertUsageError(try DaemonCLI.rm(["SB", "--force=yes"]), contains: "option --force does not take a value")
    }

    func testPositionalCount() {
        assertUsageError(try DaemonCLI.run([]), contains: "run: manifest path required")
        assertUsageError(try DaemonCLI.run(["/a.json", "/b.json"]), contains: "run: unexpected argument '/b.json'")
        assertUsageError(try DaemonCLI.rm([]), contains: "rm: sandbox id required")
        assertUsageError(try DaemonCLI.bare(["extra"], spec: DaemonCLISpecs.ps, kind: "ps"), contains: "ps: unexpected argument 'extra'")
        assertUsageError(try DaemonCLI.bare(["SB"], spec: DaemonCLISpecs.shutdown, kind: "shutdown"),
                         contains: "shutdown: unexpected argument 'SB'")
    }

    // MARK: 请求内容

    func testRunFlagsAndDefaults() throws {
        let bare = try DaemonCLI.run(["/m.json"]).request
        XCTAssertEqual(bare.allowUnsignedManifest, false)
        XCTAssertEqual(bare.allowPlaintext, false)
        XCTAssertNil(bare.memoryMiB); XCTAssertNil(bare.cpus); XCTAssertNil(bare.domain); XCTAssertNil(bare.cowRoot)
        let full = try DaemonCLI.run(["/m.json", "--allow-unsigned-manifest", "--allow-plaintext", "--cow-root", "/c",
                                      "--workspace", "/w", "--oci-bundle", "/o", "--release-keys", "/k"]).request
        XCTAssertEqual(full.allowUnsignedManifest, true)
        XCTAssertEqual(full.allowPlaintext, true)
        XCTAssertEqual([full.cowRoot, full.workspaceDir, full.ociBundlePath, full.releaseKeysPath], ["/c", "/w", "/o", "/k"])
    }

    func testDomainIsForwardedByEverySessionScopedCommand() throws {
        // 此前 stop / rm / stats / console / restart 接受 --domain 却不发送——声明形同虚设。
        XCTAssertEqual(try DaemonCLI.rm(["SB", "--domain", "work", "--force"]).request.domain, "work")
        XCTAssertEqual(try DaemonCLI.rm(["SB", "--domain", "work", "--force"]).request.force, true)
        XCTAssertEqual(try DaemonCLI.rm(["SB"]).request.force, false)
        XCTAssertEqual(try DaemonCLI.stats(["SB", "--domain", "work", "--json"]).request.domain, "work")
        XCTAssertTrue(try DaemonCLI.stats(["SB", "--json"]).json)
        XCTAssertFalse(try DaemonCLI.stats(["SB"]).json)
        XCTAssertEqual(try DaemonCLI.console(["SB", "--domain", "work"]).request.domain, "work")
        XCTAssertEqual(try DaemonCLI.console(["SB"]).request.kind, "consoleLog")
        XCTAssertEqual(try DaemonCLI.console(["SB"]).request.waitMillis, 16384)
        for (spec, kind) in [(DaemonCLISpecs.stop, "stop"), (DaemonCLISpecs.restart, "restart"),
                             (DaemonCLISpecs.suspend, "suspend"), (DaemonCLISpecs.resume, "resume")] {
            let inv = try DaemonCLI.single(["--domain", "work", "SB"], spec: spec, kind: kind)
            XCTAssertEqual(inv.request.kind, kind)
            XCTAssertEqual(inv.request.sandboxId, "SB")
            XCTAssertEqual(inv.request.domain, "work")
        }
    }

    func testEverySpecIsSelfConsistent() {
        for spec in DaemonCLISpecs.all {
            XCTAssertTrue(spec.valueOptions.isDisjoint(with: spec.flags), spec.command)
            XCTAssertTrue(spec.valueOptions.isDisjoint(with: spec.repeatableOptions), spec.command)
            XCTAssertTrue(spec.allOptions.allSatisfy { $0.hasPrefix("--") }, spec.command)
            // usage 必须列出每一个选项，否则报错里的 usage 会误导人。
            for option in spec.allOptions {
                XCTAssertTrue(spec.usage.contains(option), "\(spec.command) usage 缺 \(option)")
            }
        }
        XCTAssertEqual(Set(DaemonCLISpecs.all.map(\.command)).count, DaemonCLISpecs.all.count)
    }
}
