import XCTest
@testable import DeskBoxGUI

/// M53：不可撤销的操作先确认。
final class ActionConfirmationTests: XCTestCase {
    func testWhichActionsAsk() {
        for action in SandboxAction.allCases {
            let prompt = ActionConfirmation.prompt(for: action, sandboxId: "ABCDEFGH-1234", state: "running")
            switch action {
            case .rm, .restart, .stop:
                XCTAssertNotNil(prompt, action.rawValue)
                XCTAssertEqual(prompt?.target, .sandbox(action: action, sandboxId: "ABCDEFGH-1234"))
                XCTAssertTrue(prompt!.title.contains("ABCDEFGH"), prompt!.title)
                XCTAssertFalse(["OK", "确定", "是"].contains(prompt!.confirmLabel), "确认按钮要说出做什么")
            case .terminal, .console, .exec, .suspend, .resume:
                XCTAssertNil(prompt, "\(action.rawValue) 可以撤销 / 没有损失，不该打断")
            }
        }
    }

    func testMessagesSayWhatIsLost() {
        let rm = ActionConfirmation.prompt(for: .rm, sandboxId: "A", state: "running")!
        XCTAssertTrue(rm.message.contains("/workspace") && rm.message.contains("不能撤销"), rm.message)
        let rmFailed = ActionConfirmation.prompt(for: .rm, sandboxId: "A", state: "failed")!
        XCTAssertFalse(rmFailed.message.contains("立刻结束"), "failed 的沙箱已经不在运行：\(rmFailed.message)")
        XCTAssertTrue(rmFailed.message.contains("不能撤销"))
        let restart = ActionConfirmation.prompt(for: .restart, sandboxId: "A", state: "running")!
        XCTAssertTrue(restart.message.contains("数据不保留") && restart.message.contains("新的 sandbox id"), restart.message)
        let stop = ActionConfirmation.prompt(for: .stop, sandboxId: "A", state: "running")!
        XCTAssertTrue(stop.message.contains("Suspend"), "给出不丢现场的替代做法：\(stop.message)")
        // 每个提示的 id 不同（SwiftUI 用它区分对话框）。
        XCTAssertEqual(Set([rm.id, restart.id, stop.id]).count, 3)
    }

    func testShutdownAsksOnlyWhenThereAreSandboxes() {
        XCTAssertNil(ActionConfirmation.shutdownPrompt(sandboxCount: 0))
        let prompt = ActionConfirmation.shutdownPrompt(sandboxCount: 3)
        XCTAssertEqual(prompt?.target, .shutdownDaemon)
        XCTAssertTrue(prompt!.message.contains("3 台"), prompt!.message)
    }

    func testViewModelOnlyRegistersUntilConfirmed() {
        // socket 不存在：如果 request() 真的发了请求，errorText / execOutput 会被写入。
        let model = SandboxViewModel(client: DaemonSocketClient(sockPath: "/nonexistent/dbx.sock"))
        XCTAssertFalse(model.request(.rm, sandboxId: "A", daemonManager: nil))
        XCTAssertEqual(model.pendingConfirmation?.target, .sandbox(action: .rm, sandboxId: "A"))
        // 再点另一个：以最后一次为准（同时只有一个对话框）。
        XCTAssertFalse(model.request(.stop, sandboxId: "B", daemonManager: nil))
        XCTAssertEqual(model.pendingConfirmation?.target, .sandbox(action: .stop, sandboxId: "B"))
        model.cancelPending()
        XCTAssertNil(model.pendingConfirmation)
        // 没有登记时确认是空操作。
        model.confirmPending(daemonManager: nil)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(model.execOutput, "", "确认之前不应该发出任何请求")
        // 纯界面动作：不登记也不提交。
        XCTAssertFalse(model.request(.console, sandboxId: "A", daemonManager: nil))
        XCTAssertNil(model.pendingConfirmation)
    }

    func testConfirmSubmitsExactlyTheRegisteredAction() {
        let model = SandboxViewModel(client: DaemonSocketClient(sockPath: "/nonexistent/dbx.sock"))
        model.request(.rm, sandboxId: "A", daemonManager: nil)
        let done = expectation(description: "submitted")
        model.confirmPending(daemonManager: nil) { result in
            // 连不上：说明请求确实发了出去。
            if case .failure = result { done.fulfill() }
        }
        XCTAssertNil(model.pendingConfirmation, "确认之后立刻清掉，不会被执行两次")
        wait(for: [done], timeout: 10)
    }
}
