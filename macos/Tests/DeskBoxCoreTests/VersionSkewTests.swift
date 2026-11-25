import XCTest
@testable import DeskBoxCore

/// M51：版本偏差。
final class VersionSkewTests: XCTestCase {
    func testDaemonSkew() {
        XCTAssertEqual(BuildRevision.skew(daemonRevision: 51, clientRevision: 51), .same)
        XCTAssertEqual(BuildRevision.skew(daemonRevision: 46, clientRevision: 51), .daemonOlder(daemonRevision: 46))
        XCTAssertEqual(BuildRevision.skew(daemonRevision: nil, clientRevision: 51), .daemonOlder(daemonRevision: nil))
        XCTAssertEqual(BuildRevision.skew(daemonRevision: 60, clientRevision: 51), .daemonNewer(daemonRevision: 60))
        XCTAssertEqual(BuildRevision.skew(daemonRevision: BuildRevision.current), .same)
    }

    func testNotes() {
        XCTAssertNil(BuildRevision.note(for: .same))
        let unknown = BuildRevision.note(for: .daemonOlder(daemonRevision: nil))
        XCTAssertNotNil(unknown)
        XCTAssertTrue(unknown!.contains("不认识版本查询"), unknown!)
        XCTAssertTrue(unknown!.contains("重启 daemon"), unknown!)
        XCTAssertTrue(unknown!.contains("所有沙箱"), "重启的代价必须说清楚：\(unknown!)")
        XCTAssertTrue(BuildRevision.note(for: .daemonOlder(daemonRevision: 46))!.contains("修订 46"))
        XCTAssertTrue(BuildRevision.note(for: .daemonNewer(daemonRevision: 99))!.contains("更新客户端"))
    }

    func testMissingFixesDependOnHowOldTheDaemonIs() {
        let all = BuildRevision.notableDaemonFixes.map(\.summary)
        XCTAssertEqual(BuildRevision.missingFixes(daemonRevision: nil), all, "不知道多旧：全部列出")
        XCTAssertEqual(BuildRevision.missingFixes(daemonRevision: BuildRevision.current), [])
        let since45 = BuildRevision.missingFixes(daemonRevision: 45)
        XCTAssertTrue(since45.contains { $0.contains("崩溃") })
        XCTAssertFalse(since45.contains { $0.contains("终端关闭后无法再次打开") })
        // 列表按修订号递增，且没有哪一条指向未来的修订。
        let revisions = BuildRevision.notableDaemonFixes.map(\.revision)
        XCTAssertEqual(revisions, revisions.sorted())
        XCTAssertLessThanOrEqual(revisions.max() ?? 0, BuildRevision.current)
    }

    func testUnknownInfoRejectionIsRecognisedFromTheOldDaemonsWording() {
        XCTAssertTrue(BuildRevision.isUnknownInfoRejection("request rejected (kind=info): unknown kind=info"))
        XCTAssertFalse(BuildRevision.isUnknownInfoRejection("request rejected (kind=exec): unknown kind=execCancel"))
        XCTAssertFalse(BuildRevision.isUnknownInfoRejection("cannot connect to daemon"))
    }

    // MARK: guest

    private func stats(_ json: String) throws -> SandboxStats {
        try JSONDecoder().decode(SandboxStats.self, from: Data(json.utf8))
    }

    func testOldGuestReportsEverythingMissing() throws {
        let findings = GuestCapabilityReport.findings(for: try stats(#"{"activeExecGroups":0}"#))
        XCTAssertEqual(findings.map(\.id), ["child-fds", "broker-control-plane", "workspace-receiver", "exec-output", "broker-result", "exec-cancel"])
        XCTAssertEqual(findings.filter { $0.severity == .isolation }.count, 3)
        XCTAssertTrue(GuestCapabilityReport.needsAttention(findings))
        XCTAssertTrue(findings.allSatisfy { $0.summary.contains("（M") }, "每条都指向引入修复的里程碑")
    }

    func testCurrentGuestHasNoFindings() throws {
        let current = try stats(#"{"activeExecGroups":0,"workspaceSyncVersion":2,"execOutputVersion":2,"execCancelVersion":1,"brokerVersion":3,"childFdsVersion":1}"#)
        XCTAssertEqual(GuestCapabilityReport.findings(for: current), [])
        XCTAssertFalse(GuestCapabilityReport.needsAttention([]))
    }

    func testIntermediateGuests() throws {
        // M42 的 guest（broker 2，没有 childFds）：控制面经 broker 杀不掉了，但 stdin 仍是控制通道。
        let m42 = try stats(#"{"workspaceSyncVersion":2,"execOutputVersion":2,"execCancelVersion":1,"brokerVersion":2}"#)
        XCTAssertEqual(GuestCapabilityReport.findings(for: m42).map(\.id), ["child-fds", "broker-result"])
        // 只缺取消：是功能缺失，不算「需要尽快处理」。
        let noCancel = try stats(#"{"workspaceSyncVersion":2,"execOutputVersion":2,"brokerVersion":3,"childFdsVersion":1}"#)
        let findings = GuestCapabilityReport.findings(for: noCancel)
        XCTAssertEqual(findings.map(\.id), ["exec-cancel"])
        XCTAssertFalse(GuestCapabilityReport.needsAttention(findings))
    }

    func testFaultFixtureIsCalledOut() throws {
        let fixture = try stats(#"{"workspaceSyncVersion":2,"execOutputVersion":2,"execCancelVersion":1,"brokerVersion":3,"childFdsVersion":1,"testFaults":true}"#)
        let findings = GuestCapabilityReport.findings(for: fixture)
        XCTAssertEqual(findings.map(\.id), ["test-faults"])
        XCTAssertTrue(GuestCapabilityReport.needsAttention(findings))
    }
}
