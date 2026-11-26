import XCTest
@testable import DeskBoxGUI

/// M52：Stats 面板里的「guest 资产缺什么」。
final class GuestFindingsNoteTests: XCTestCase {
    private func stats(_ json: String) throws -> SandboxStats { try JSONDecoder().decode(SandboxStats.self, from: Data(json.utf8)) }
    private let current = #"{"cpuUsageUsec":1,"memoryCurrentBytes":2,"workspaceSyncVersion":2,"execOutputVersion":2,"execCancelVersion":1,"brokerVersion":3,"childFdsVersion":1}"#

    func testGUIWireTypeDecodesTheCapabilityFields() throws {
        let s = try stats(current)
        XCTAssertEqual(s.workspaceSyncVersion, 2)
        XCTAssertEqual(s.brokerVersion, 3)
        XCTAssertEqual(s.childFdsVersion, 1)
        XCTAssertNil(s.testFaults)
        XCTAssertEqual(GuestFindingsNote.findings(for: s), [])
    }

    func testOldGuestAndHeadline() throws {
        let findings = try XCTUnwrap(GuestFindingsNote.findings(for: try stats(#"{"cpuUsageUsec":1,"memoryCurrentBytes":2}"#)))
        XCTAssertEqual(findings.count, 6)
        XCTAssertTrue(GuestFindingsNote.needsAttention(findings))
        let headline = GuestFindingsNote.headline(findings)
        XCTAssertTrue(headline.contains("缺 6 项") && headline.contains("3 项涉及隔离"), headline)
        let featureOnly = try XCTUnwrap(GuestFindingsNote.findings(for: try stats(#"{"cpuUsageUsec":1,"workspaceSyncVersion":2,"execOutputVersion":2,"brokerVersion":3,"childFdsVersion":1}"#)))
        XCTAssertEqual(featureOnly.map(\.id), ["exec-cancel"])
        XCTAssertFalse(GuestFindingsNote.headline(featureOnly).contains("隔离"))
    }

    func testSoftFailureGivesNoVerdict() throws {
        // guest 没有应答：没有能力字段不等于「旧 guest」。
        XCTAssertNil(GuestFindingsNote.findings(for: try stats(#"{"statsError":"DBX-GUEST-CONTROL-LOST: x"}"#)))
    }

    func testStatsModelKeepsVerdictAcrossSoftFailureAndClearsOnSelect() throws {
        let model = StatsModel(client: DaemonSocketClient(sockPath: "/nonexistent"))
        model.select("A")
        XCTAssertNil(model.guestFindings)
        var ok = DaemonResponse(ok: true); ok.stats = try stats(#"{"cpuUsageUsec":1,"memoryCurrentBytes":2}"#)
        model.apply(.success(ok), nowNanos: 1, cores: 1)
        XCTAssertEqual(model.guestFindings?.count, 6)
        var soft = DaemonResponse(ok: true); soft.stats = try stats(#"{"statsError":"busy"}"#)
        model.apply(.success(soft), nowNanos: 2, cores: 1)
        XCTAssertEqual(model.guestFindings?.count, 6, "软失败不改变结论")
        model.select("B")
        XCTAssertNil(model.guestFindings, "换一台沙箱：结论清空")
        var fresh = DaemonResponse(ok: true); fresh.stats = try stats(current)
        model.apply(.success(fresh), nowNanos: 3, cores: 1)
        XCTAssertEqual(model.guestFindings, [])
    }
}
