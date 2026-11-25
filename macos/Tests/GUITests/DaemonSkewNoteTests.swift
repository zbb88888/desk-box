import XCTest
@testable import DeskBoxGUI

/// M51：界面顶部的「daemon 较旧」提示。
final class DaemonSkewNoteTests: XCTestCase {
    private func response(revision: Int?) -> DaemonResponse {
        var r = DaemonResponse(ok: true)
        if let revision { r.info = DaemonInfo(revision: revision, pid: 1, startedAtUtc: "t", sandboxCount: 0) }
        return r
    }

    func testSameRevisionShowsNothing() {
        XCTAssertEqual(DaemonSkewNote.evaluate(.success(response(revision: DaemonSkewNote.clientRevision))), .note(nil))
    }

    func testOlderDaemonNamesWhatItIsMissing() {
        guard case .note(let text?) = DaemonSkewNote.evaluate(.success(response(revision: 40))) else { return XCTFail() }
        XCTAssertTrue(text.contains("修订 40"), text)
        XCTAssertTrue(text.contains("重启 daemon"), text)
        XCTAssertTrue(text.contains("缺少的修复包括"), text)
        XCTAssertTrue(text.contains("崩溃"), text)
    }

    func testDaemonThatRejectsTheQueryIsTreatedAsOld() {
        // 旧 daemon 的真实措辞（经 GUI 客户端包装之后）。
        let error = DaemonClientError.rejected("request rejected (kind=info): unknown kind=info")
        guard case .note(let text?) = DaemonSkewNote.evaluate(.failure(error)) else { return XCTFail() }
        XCTAssertTrue(text.contains("不认识版本查询"), text)
        // 应答成功却没有 info 字段：同样按旧处理。
        guard case .note(let bare?) = DaemonSkewNote.evaluate(.success(response(revision: nil))) else { return XCTFail() }
        XCTAssertTrue(bare.contains("不认识版本查询"), bare)
    }

    func testNewerDaemonAsksToUpdateTheApp() {
        guard case .note(let text?) = DaemonSkewNote.evaluate(.success(response(revision: DaemonSkewNote.clientRevision + 5))) else { return XCTFail() }
        XCTAssertTrue(text.contains("更新客户端"), text)
    }

    func testConnectionProblemsAreRetriedNotReportedAsSkew() {
        XCTAssertEqual(DaemonSkewNote.evaluate(.failure(DaemonClientError.connectFailed("errno=61"))), .retryLater)
        XCTAssertEqual(DaemonSkewNote.evaluate(.failure(DaemonClientError.rejected("daemon draining: kind=info rejected"))), .retryLater)
    }
}
