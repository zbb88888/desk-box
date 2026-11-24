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

    func testMessageCarriesCodeOperationAndDetail() {
        let message = ControlLossPolicy.message(waitingFor: "exec", detail: "guest control socket closed")
        XCTAssertTrue(message.hasPrefix("DBX-GUEST-CONTROL-LOST: "), message)
        XCTAssertTrue(message.contains("exec"), message)
        XCTAssertTrue(message.contains("guest control socket closed"), message)
        XCTAssertTrue(message.contains("rm"), message)
    }
}
