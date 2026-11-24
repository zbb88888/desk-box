import XCTest
import Foundation
@testable import DeskBoxGUI
@testable import DeskBoxVZ

/// M30：行内操作按状态启用 + GUI 与 daemon 共用状态根目录。
final class SandboxRowActionsTests: XCTestCase {

    func testRunningOffersEverythingExceptResume() {
        XCTAssertEqual(SandboxRowActions.available(forState: "running"),
                       [.terminal, .console, .exec, .suspend, .restart, .stop, .rm])
    }

    func testSuspendedOffersResumeNotExec() {
        let actions = SandboxRowActions.available(forState: "suspended")
        XCTAssertEqual(actions, [.console, .resume, .rm])
        XCTAssertFalse(actions.contains(.exec), "suspended 沙箱不能 exec（daemon 会拒绝）")
        XCTAssertFalse(actions.contains(.suspend))
    }

    func testEveryStateKeepsConsoleAndRm() {
        // Rm 是任何异常状态的唯一出路，绝不能被禁掉。
        for state in ["pending", "running", "suspending", "suspended", "resuming", "stopping", "stopped", "failed",
                      "", "RUNNING", "some-future-state"] {
            let actions = SandboxRowActions.available(forState: state)
            XCTAssertTrue(actions.contains(.rm), state)
            XCTAssertTrue(actions.contains(.console), state)
            XCTAssertEqual(Set(actions).count, actions.count, "重复按钮：\(state)")
        }
    }

    func testTransitionalAndUnknownStatesAreConservative() {
        for state in ["pending", "suspending", "resuming", "stopping", "stopped", "failed", "RUNNING", "garbage"] {
            XCTAssertEqual(SandboxRowActions.available(forState: state), [.console, .rm], state)
        }
    }

    func testResumeAndSuspendAreNeverOfferedTogether() {
        for state in ["pending", "running", "suspending", "suspended", "resuming", "stopping", "stopped", "failed"] {
            let actions = SandboxRowActions.available(forState: state)
            XCTAssertFalse(actions.contains(.suspend) && actions.contains(.resume), state)
        }
    }

    func testRequestsMatchDaemonWireNames() throws {
        XCTAssertNil(SandboxRowActions.request(for: .terminal, sandboxId: "SB"))
        XCTAssertNil(SandboxRowActions.request(for: .console, sandboxId: "SB"))
        XCTAssertNil(SandboxRowActions.request(for: .exec, sandboxId: "SB"))
        for (action, kind) in [(SandboxAction.suspend, "suspend"), (.resume, "resume"), (.restart, "restart"), (.stop, "stop")] {
            let request = try XCTUnwrap(SandboxRowActions.request(for: action, sandboxId: "SB"))
            XCTAssertEqual(request.kind, kind)
            XCTAssertEqual(request.sandboxId, "SB")
            XCTAssertNil(request.force, "\(kind) 不应带 force")
        }
        let rm = try XCTUnwrap(SandboxRowActions.request(for: .rm, sandboxId: "SB"))
        XCTAssertEqual(rm.kind, "rm")
        XCTAssertEqual(rm.force, true)
        // 线上 JSON：只有被设置的字段出现，kind 与 daemon 决策表里的路由名一致。
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rm)) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "rm")
        XCTAssertEqual(json["sandboxId"] as? String, "SB")
        XCTAssertEqual(json["force"] as? Bool, true)
    }

    func testLabelsAreUniqueAndNonEmpty() {
        let labels = SandboxAction.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(SandboxAction.allCases.filter(\.isDestructive), [.rm])
    }

    func testGUIUsesTheSameSocketPathAsDaemonAndCLI() {
        // 单一解析点：GUI 的默认 socket 就是 DeskBoxPaths 的 socket（DBX_SUPPORT_ROOT 同时作用于三者）。
        XCTAssertEqual(DaemonSocketClient.defaultSockPath(), DeskBoxPaths.daemonSocketURL.path)
        XCTAssertTrue(DaemonSocketClient.defaultSockPath().hasSuffix("/dbxd.sock"))
        XCTAssertEqual(DaemonProcessManager().clientPath, DeskBoxPaths.daemonSocketURL.path)
    }
}
