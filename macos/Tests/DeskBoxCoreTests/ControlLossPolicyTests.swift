import XCTest
@testable import DeskBoxCore
@testable import DeskBoxVZ

/// M43：guest 关闭控制连接时，是否算意外。
final class ControlLossPolicyTests: XCTestCase {
    func testOnlyTheCurrentSocketOfARunningSandboxCounts() {
        XCTAssertTrue(ControlLossPolicy.isUnexpected(failedSocketIsCurrent: true, state: .running))
        // resume / stop 先把 controlSocket 置空：旧连接随后报的 EOF 与当前会话无关。
        XCTAssertFalse(ControlLossPolicy.isUnexpected(failedSocketIsCurrent: false, state: .running))
    }

    func testLifecycleTransitionsAreNeverTreatedAsLoss() {
        for state in SandboxState.allCases where state != .running {
            XCTAssertFalse(ControlLossPolicy.isUnexpected(failedSocketIsCurrent: true, state: state), "\(state)")
            XCTAssertFalse(ControlLossPolicy.isUnexpected(failedSocketIsCurrent: false, state: state), "\(state)")
        }
    }

    func testStatsCapabilityFieldsFromNewerGuests() throws {
        // 旧 guest 一个都不上报；测试夹具才有 testFaults。
        let old = try JSONDecoder().decode(SandboxStats.self, from: Data(#"{"activeExecGroups":0}"#.utf8))
        XCTAssertNil(old.childFdsVersion)
        XCTAssertNil(old.testFaults)
        XCTAssertNil(old.brokerVersion)
        let fixture = try JSONDecoder().decode(SandboxStats.self, from: Data(
            #"{"activeExecGroups":0,"workspaceSyncVersion":2,"execOutputVersion":2,"execCancelVersion":1,"brokerVersion":3,"childFdsVersion":1,"testFaults":true}"#.utf8))
        XCTAssertEqual(fixture.childFdsVersion, 1)
        XCTAssertEqual(fixture.testFaults, true)
        XCTAssertEqual(fixture.brokerVersion, 3)
        let release = try JSONDecoder().decode(SandboxStats.self, from: Data(
            #"{"activeExecGroups":0,"brokerVersion":3,"childFdsVersion":1}"#.utf8))
        XCTAssertNil(release.testFaults, "正式资产不上报 testFaults")
    }

    func testMessageCarriesCodeOperationAndDetail() {
        let message = ControlLossPolicy.message(waitingFor: "exec", detail: "guest control socket closed")
        XCTAssertTrue(message.hasPrefix("DBX-GUEST-CONTROL-LOST: "), message)
        XCTAssertTrue(message.contains("exec"), message)
        XCTAssertTrue(message.contains("guest control socket closed"), message)
        XCTAssertTrue(message.contains("rm"), message)
    }
}
