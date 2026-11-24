import XCTest
import Foundation
@testable import DeskBoxGUI

/// M28：daemon 原因码 → 用户可读提示。
final class DaemonErrorPresenterTests: XCTestCase {

    // 以下文本均取自真机上 daemon 的实际输出。
    private let bootSilent = "request rejected (kind=run): DBX-BOOT-FAILED(no-console-output): guest 在 console 就绪前已停止运行 | 10s 内无任何输出；内存 512MiB 低于该 guest 的估算下限约 576MiB（initrd 解包后 322MiB），请调大 --memory-mib"
    private let cancelled = "request rejected (kind=exec): DBX-OP-CANCELLED: exec aborted (sandbox is being removed)"
    private let locked = "request rejected (kind=resume): DBX-RESUME-HOST-LOCKED: Virtualization.framework 拒绝恢复 VM 状态，当前登录会话处于锁屏状态（锁屏期间无法恢复已保存的 VM 状态）。请解锁后重试 resume；沙箱仍为 suspended，快照已保留 | underlying: Error Domain=VZErrorDomain Code=12"
    private let aborted = "request rejected (kind=suspend): DBX-LIFECYCLE-SUSPEND-ABORTED: suspend 失败，已回滚到 running（沙箱可继续使用）| cause: …"

    func testKnownCodesMapToTitlesAndSeverity() {
        let cases: [(String, String, PresentedDaemonError.Severity, String)] = [
            (bootSilent, "DBX-BOOT-FAILED(no-console-output)", .error, "沙箱引导失败：guest 没有任何输出"),
            (cancelled, "DBX-OP-CANCELLED", .info, "操作已取消"),
            (locked, "DBX-RESUME-HOST-LOCKED", .warning, "无法恢复：Mac 处于锁屏状态"),
            (aborted, "DBX-LIFECYCLE-SUSPEND-ABORTED", .warning, "挂起失败，沙箱仍在运行"),
            ("request rejected (kind=run): DBX-BOOT-TIMEOUT: bootstrap did not reach running within 90s | console: x",
             "DBX-BOOT-TIMEOUT", .error, "沙箱引导超时"),
            ("request rejected (kind=suspend): DBX-LIFECYCLE-SUSPEND-FAILED: suspend 失败且无法回滚",
             "DBX-LIFECYCLE-SUSPEND-FAILED", .error, "挂起失败，沙箱已不可用"),
            ("request rejected (kind=rm): DBX-DOMAIN-SESSION-MISMATCH: rm 请求域 a 与沙箱域 b 不一致",
             "DBX-DOMAIN-SESSION-MISMATCH", .error, "凭据域不匹配"),
            ("request rejected (kind=run): DBX-BOOT-FAILED(kernel-panic): guest 内核 panic；见 console | console: Kernel panic",
             "DBX-BOOT-FAILED(kernel-panic)", .error, "沙箱引导失败"),
        ]
        for (raw, code, severity, title) in cases {
            let p = DaemonErrorPresenter.present(rejection: raw)
            XCTAssertEqual(p.code, code, raw)
            XCTAssertEqual(p.severity, severity, raw)
            XCTAssertEqual(p.title, title, raw)
            XCTAssertTrue(p.logLine.contains(title) && p.logLine.contains("[\(code)]"), p.logLine)
        }
    }

    func testUncodedRejections() {
        let notFound = DaemonErrorPresenter.present(rejection: "request rejected (kind=stop): stop: sandbox not found: ABC")
        XCTAssertNil(notFound.code)
        XCTAssertEqual(notFound.title, "沙箱不存在")
        XCTAssertEqual(notFound.severity, .warning)

        let draining = DaemonErrorPresenter.present(rejection: "request rejected (kind=ps): daemon draining: kind=ps rejected (shutdown in progress)")
        XCTAssertEqual(draining.title, "daemon 正在停机")
        XCTAssertEqual(draining.severity, .info)

        let unknown = DaemonErrorPresenter.present(rejection: "request rejected (kind=x): something brand new")
        XCTAssertEqual(unknown.title, "请求被 daemon 拒绝")
        XCTAssertEqual(unknown.severity, .error)
        XCTAssertEqual(unknown.detail, "request rejected (kind=x): something brand new", "未知错误必须原样可见")
    }

    func testUnknownDBXCodeIsStillSurfaced() {
        let p = DaemonErrorPresenter.present(rejection: "DBX-FUTURE-THING: whatever")
        XCTAssertEqual(p.code, "DBX-FUTURE-THING")
        XCTAssertEqual(p.title, "请求被 daemon 拒绝")
    }

    func testCodeExtraction() {
        XCTAssertEqual(DaemonErrorPresenter.extractCode(from: "x DBX-BOOT-FAILED(no-console-output): y"), "DBX-BOOT-FAILED(no-console-output)")
        XCTAssertEqual(DaemonErrorPresenter.extractCode(from: "DBX-OP-CANCELLED: exec aborted"), "DBX-OP-CANCELLED")
        XCTAssertEqual(DaemonErrorPresenter.extractCode(from: "DBX-BOOT-PROOF-MISSING"), "DBX-BOOT-PROOF-MISSING")
        XCTAssertNil(DaemonErrorPresenter.extractCode(from: "no code here"))
        XCTAssertNil(DaemonErrorPresenter.extractCode(from: "DBX-"))
        // 括号不闭合 / 括号里是垃圾：不得把后面的任意文本吞进 code。
        XCTAssertEqual(DaemonErrorPresenter.extractCode(from: "DBX-BOOT-FAILED(oops and then lots of text"), "DBX-BOOT-FAILED(oops")
    }

    func testClientErrorClassification() {
        let unreachable = DaemonErrorPresenter.present(DaemonClientError.connectFailed("/x errno=61"))
        XCTAssertEqual(unreachable.title, "无法连接 daemon")
        XCTAssertEqual(unreachable.severity, .error)

        let busy = DaemonErrorPresenter.present(DaemonClientError.weird("invalid response"))
        XCTAssertEqual(busy.title, "daemon 没有给出有效响应")
        XCTAssertEqual(busy.severity, .warning)

        XCTAssertEqual(DaemonErrorPresenter.present(DaemonClientError.rejected(cancelled)).code, "DBX-OP-CANCELLED")

        struct Other: LocalizedError { var errorDescription: String? { "boom" } }
        let other = DaemonErrorPresenter.present(Other())
        XCTAssertEqual(other.title, "请求失败")
        XCTAssertEqual(other.detail, "boom")
    }

    func testOnlyConnectFailuresMeanDaemonIsDown() {
        // 回归：此前任何失败都会把 daemon 状态置为 stopped——一次被拒绝的 run 就让界面显示 daemon 已停。
        XCTAssertTrue(DaemonClientError.connectFailed("x").indicatesDaemonUnreachable)
        XCTAssertTrue(DaemonClientError.socketFailed(24).indicatesDaemonUnreachable)
        XCTAssertFalse(DaemonClientError.rejected(bootSilent).indicatesDaemonUnreachable, "被拒绝说明 daemon 活着")
        XCTAssertFalse(DaemonClientError.weird("invalid response").indicatesDaemonUnreachable, "超时不足以断定 daemon 已死")
    }

    func testDetailIsSanitizedAndBounded() {
        // 引导失败消息里带 guest 控制的 console 片段。
        let hostile = "DBX-BOOT-FAILED(kernel-panic): x | console: \u{1B}[2J\u{1B}[31mPWNED\u{07}\u{00}\n\nline2\u{9B}0m"
            + String(repeating: "A", count: 5000)
        let p = DaemonErrorPresenter.present(rejection: hostile)
        XCTAssertFalse(p.detail.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || ($0.value >= 0x80 && $0.value < 0xA0) })
        XCTAssertFalse(p.detail.contains("\u{1B}"))
        XCTAssertTrue(p.detail.contains("PWNED line2"), p.detail)
        XCTAssertLessThanOrEqual(p.detail.count, 601)
        XCTAssertEqual(p.code, "DBX-BOOT-FAILED(kernel-panic)")
    }
}
