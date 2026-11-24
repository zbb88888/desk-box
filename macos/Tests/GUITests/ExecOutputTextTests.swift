import XCTest
@testable import DeskBoxGUI

/// M39：Exec 面板文本。
final class ExecOutputTextTests: XCTestCase {
    func testPlainResultKeepsTheFamiliarLayout() {
        XCTAssertEqual(ExecOutputText.render(exitCode: 0, stdout: "hi\n", stderr: "", notices: nil),
                       "exit=0\n---stdout---\nhi\n\n---stderr---\n")
        XCTAssertEqual(ExecOutputText.render(exitCode: nil, stdout: nil, stderr: nil, notices: []),
                       "exit=0\n---stdout---\n\n---stderr---\n")
    }

    func testNoticesComeBeforeTheOutput() {
        let text = ExecOutputText.render(exitCode: 0, stdout: String(repeating: "x", count: 5000), stderr: "",
                                         notices: ["stdout 被截断：只保留了前 5000 字节", "另一条"])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], "exit=0")
        XCTAssertEqual(lines[1], "⚠︎ stdout 被截断：只保留了前 5000 字节")
        XCTAssertEqual(lines[2], "⚠︎ 另一条")
        XCTAssertEqual(lines[3], "---stdout---")
    }
}
