import XCTest
import DeskBoxCore
@testable import dbx_poc

/// M51：`dbx-poc doctor`。
final class DoctorTests: XCTestCase {
    private func stats(_ json: String) throws -> SandboxStats { try JSONDecoder().decode(SandboxStats.self, from: Data(json.utf8)) }
    private func info(_ id: String, _ state: String) -> SandboxInfo {
        SandboxInfo(sandboxId: id, state: state, bootedAtUtc: "t", manifestPath: "m")
    }

    func testCurrentDaemonAndGuest() throws {
        let current = try stats(#"{"cpuUsageUsec":1,"workspaceSyncVersion":2,"execOutputVersion":2,"execCancelVersion":1,"brokerVersion":3,"childFdsVersion":1}"#)
        let report = try DoctorCLI.gather { request in
            switch request.kind {
            case "ps": return DaemonResponse(ok: true, sandboxes: [self.info("A", "running"), self.info("B", "suspended")])
            case "info": return DaemonResponse(ok: true, info: DaemonInfo(revision: BuildRevision.current, pid: 7, startedAtUtc: "t", sandboxCount: 2))
            case "stats":
                XCTAssertEqual(request.sandboxId, "A", "只查 running 的沙箱")
                return DaemonResponse(ok: true, stats: current)
            default: XCTFail(request.kind); return DaemonResponse(ok: false)
            }
        }
        XCTAssertNil(report.daemonNote)
        XCTAssertEqual(report.daemon?.revision, BuildRevision.current)
        XCTAssertEqual(report.sandboxes.map(\.sandboxId), ["A", "B"])
        XCTAssertEqual(report.sandboxes[0].findings, [])
        XCTAssertNil(report.sandboxes[1].findings, "suspended 的没有查")
        XCTAssertFalse(report.needsAttention)
        let text = report.rendered()
        XCTAssertTrue(text.contains("ok daemon 与客户端同一修订"), text)
        XCTAssertTrue(text.contains("ok guest 资产是最新的"), text)
        XCTAssertTrue(text.contains("不在 running，未检查"), text)
    }

    func testOldDaemonThatRejectsInfo() throws {
        let report = try DoctorCLI.gather { request in
            switch request.kind {
            case "ps": return DaemonResponse(ok: true, sandboxes: [])
            case "info": throw CLIError.usage("request rejected (kind=info): unknown kind=info")
            default: XCTFail(request.kind); return DaemonResponse(ok: false)
            }
        }
        XCTAssertNil(report.daemon)
        XCTAssertNotNil(report.daemonNote)
        XCTAssertEqual(report.daemonMissingFixes, BuildRevision.notableDaemonFixes.map(\.summary))
        XCTAssertTrue(report.needsAttention)
        let text = report.rendered()
        XCTAssertTrue(text.contains("不认识版本查询"), text)
        XCTAssertTrue(text.contains("缺少的修复：终端大量输出时 daemon 可能崩溃"), text)
        XCTAssertTrue(text.contains("sandboxes  （没有）"), text)
    }

    func testOldGuestFindingsAndSoftStatsFailure() throws {
        let old = try stats(#"{"cpuUsageUsec":5,"activeExecGroups":0}"#)
        let lost = try stats(#"{"statsError":"DBX-GUEST-CONTROL-LOST: stats 无法完成"}"#)
        let report = try DoctorCLI.gather { request in
            switch request.kind {
            case "ps": return DaemonResponse(ok: true, sandboxes: [self.info("OLD", "running"), self.info("DEAD", "running"), self.info("ERR", "running")])
            case "info": return DaemonResponse(ok: true, info: DaemonInfo(revision: BuildRevision.current, pid: 7, startedAtUtc: "t", sandboxCount: 3))
            case "stats":
                if request.sandboxId == "OLD" { return DaemonResponse(ok: true, stats: old) }
                if request.sandboxId == "DEAD" { return DaemonResponse(ok: true, stats: lost) }
                throw CLIError.usage("stats: sandbox not found")
            default: XCTFail(request.kind); return DaemonResponse(ok: false)
            }
        }
        XCTAssertEqual(report.sandboxes[0].findings?.count, 6)
        XCTAssertNil(report.sandboxes[1].findings)
        XCTAssertTrue(report.sandboxes[1].statsError?.contains("DBX-GUEST-CONTROL-LOST") ?? false)
        XCTAssertTrue(report.sandboxes[2].statsError?.contains("not found") ?? false)
        XCTAssertTrue(report.needsAttention, "旧 guest 有隔离问题")
        let text = report.rendered()
        XCTAssertTrue(text.contains("! [isolation]"), text)
        XCTAssertTrue(text.contains("? 无法查询 guest 能力"), text)
        XCTAssertTrue(text.contains("重建 guest 资产"), text)
    }

    func testOtherErrorsFromInfoAreNotMistakenForAnOldDaemon() {
        XCTAssertThrowsError(try DoctorCLI.gather { request in
            if request.kind == "ps" { return DaemonResponse(ok: true, sandboxes: []) }
            throw CLIError.usage("daemon draining: kind=info rejected (shutdown in progress)")
        })
        XCTAssertThrowsError(try DoctorCLI.gather { _ in throw CLIError.usage("cannot connect to daemon") })
    }

    func testReportRoundTripsAsJSONAndCLISpec() throws {
        let report = DoctorReport(clientRevision: 51, daemon: nil, daemonNote: "x", daemonMissingFixes: ["a"],
                                  sandboxes: [.init(sandboxId: "A", state: "running", findings: [.init(id: "i", severity: .isolation, summary: "s")], statsError: nil)])
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded, report)
        let parsed = try CLIArgs.parse(["--strict", "--json", "--daemon-sock", "/s"], spec: DaemonCLISpecs.doctor)
        XCTAssertTrue(parsed.flag("--strict") && parsed.flag("--json"))
        XCTAssertThrowsError(try CLIArgs.parse(["--fix"], spec: DaemonCLISpecs.doctor))
        XCTAssertThrowsError(try CLIArgs.parse(["extra"], spec: DaemonCLISpecs.doctor))
    }

    func testRealDaemonAnswersInfo() throws {
        let dir = URL(fileURLWithPath: "/tmp/dbxi-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let sock = dir.appendingPathComponent("d.sock").path
        let daemon = SandboxDaemon(sockPath: sock, supportRoot: dir)
        let done = DispatchSemaphore(value: 0)
        Thread { _ = try? daemon.serveLoop(); done.signal() }.start()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, (try? DaemonClient.send(request: DaemonRequest(kind: "ps"), sockPath: sock)) == nil { usleep(10_000) }
        let response = try DaemonClient.send(request: DaemonRequest(kind: "info"), sockPath: sock)
        XCTAssertEqual(response.info?.revision, BuildRevision.current)
        XCTAssertEqual(response.info?.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(response.info?.sandboxCount, 0)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: response.info?.startedAtUtc ?? ""))
        let report = try DoctorCLI.gather { try DaemonClient.send(request: $0, sockPath: sock) }
        XCTAssertFalse(report.needsAttention)
        XCTAssertTrue(try DaemonClient.send(request: DaemonRequest(kind: "shutdown"), sockPath: sock).ok)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    }
}
