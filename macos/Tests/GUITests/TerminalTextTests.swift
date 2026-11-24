import XCTest
import Foundation
@testable import DeskBoxGUI

/// M33：hex 解码与终端输出净化。
final class TerminalTextTests: XCTestCase {

    // MARK: HexCoding

    func testHexRoundTrip() {
        let data = Data([0x00, 0x1B, 0x7F, 0xFF, 0x41])
        XCTAssertEqual(HexCoding.encode(data), "001b7fff41")
        XCTAssertEqual(HexCoding.decode("001b7fff41"), data)
        XCTAssertEqual(HexCoding.decode("001B7FFF41"), data, "大小写都接受")
        XCTAssertEqual(HexCoding.decode(""), Data())
    }

    func testMalformedHexReturnsNilInsteadOfCrashing() {
        // 回归：此前奇数长度会在 `hex.index(i, offsetBy: 2)` 处越界 trap，GUI 直接崩溃。
        for bad in ["a", "abc", "zz", "0g", "12 34", "1234\n", "é0"] {
            XCTAssertNil(HexCoding.decode(bad), bad)
        }
    }

    // MARK: TerminalTextFilter

    private func render(_ chunks: [Data]) -> String {
        var filter = TerminalTextFilter()
        var text = ""
        for chunk in chunks { filter.feed(chunk, into: &text) }
        return text
    }
    private func render(_ string: String) -> String { render([Data(string.utf8)]) }

    func testCSISequencesAreRemovedCompletely() {
        // 回归：旧实现把 `[` 当成终止字节，屏幕上会留下 "0;32m"。
        XCTAssertEqual(render("\u{1B}[0;32mgreen\u{1B}[0m plain"), "green plain")
        XCTAssertEqual(render("a\u{1B}[2Kb\u{1B}[1;1Hc\u{1B}[?25ld"), "abcd")
        XCTAssertEqual(render("x\u{1B}[38;5;196my"), "xy")
    }

    func testOSCAndOtherStringSequencesAreRemoved() {
        XCTAssertEqual(render("\u{1B}]0;window title\u{07}prompt$ "), "prompt$ ")
        XCTAssertEqual(render("\u{1B}]8;;http://x\u{1B}\\link\u{1B}]8;;\u{1B}\\"), "link")
        XCTAssertEqual(render("a\u{1B}Pdcs payload\u{1B}\\b"), "ab")
    }

    func testTwoByteEscapesAndCharsetSelection() {
        XCTAssertEqual(render("a\u{1B}=b\u{1B}>c\u{1B}(Bd\u{1B})0e"), "abcde")
    }

    func testSequencesSplitAcrossChunks() {
        // poll 的分块边界是任意的。
        let whole = "pre\u{1B}[0;32mGREEN\u{1B}[0m\u{1B}]0;t\u{07}post"
        let bytes = Array(whole.utf8)
        for cut in 1..<bytes.count {
            XCTAssertEqual(render([Data(bytes[..<cut]), Data(bytes[cut...])]), "preGREENpost", "cut=\(cut)")
        }
    }

    func testMultiByteCharactersSplitAcrossChunks() {
        let whole = "你好🙂é"
        let bytes = Array(whole.utf8)
        for cut in 1..<bytes.count {
            XCTAssertEqual(render([Data(bytes[..<cut]), Data(bytes[cut...])]), whole, "cut=\(cut)")
        }
        // 逐字节喂入。
        XCTAssertEqual(render(bytes.map { Data([$0]) }), whole)
    }

    func testInvalidBytesDoNotStallOutput() {
        XCTAssertEqual(render([Data([0x61, 0xFF, 0xFE, 0x62]), Data("c".utf8)]), "a\u{FFFD}\u{FFFD}bc")
        // 孤立的续字节 / 被截断后跟了普通字符：不能把后面的输出吞掉。
        XCTAssertTrue(render([Data([0xE4, 0xBD]), Data("ok\n".utf8)]).hasSuffix("ok\n"))
    }

    func testBackspaceAndCarriageReturn() {
        XCTAssertEqual(render("abc\u{08} \u{08}d"), "abd", "shell 回显里的 \\b 空格 \\b")
        XCTAssertEqual(render("x\u{7F}y"), "y")
        XCTAssertEqual(render("line\n\u{08}\u{08}z"), "line\nz", "退格不跨行")
        XCTAssertEqual(render("\u{08}a"), "a", "空缓冲上的退格是空操作")
        XCTAssertEqual(render("a\r\nb\rc"), "a\nbc")
    }

    func testControlCharactersAreDropped() {
        XCTAssertEqual(render("a\u{07}b\u{00}c\u{0B}d\u{85}e\tf\n"), "abcde\tf\n")
        XCTAssertEqual(render("a\u{9B}31mb"), "ab", "8-bit CSI")
    }

    func testOutputNeverContainsEscapeOrControlBytes() {
        // 用伪随机字节流打一遍：不变量是输出里只有可打印字符、\n、\t。
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt8 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: seed >> 33) }
        var filter = TerminalTextFilter()
        var text = ""
        for _ in 0..<400 {
            filter.feed(Data((0..<Int(next() % 40)).map { _ in next() }), into: &text)
        }
        XCTAssertFalse(text.unicodeScalars.contains { s in
            (s.value < 0x20 && s != "\n" && s != "\t") || s.value == 0x7F || (0x80...0x9F).contains(s.value)
        })
    }

    func testOutputIsBounded() {
        var filter = TerminalTextFilter()
        var text = ""
        let chunk = Data(String(repeating: "x", count: 50_000).utf8)
        for _ in 0..<10 { filter.feed(chunk, into: &text) }
        filter.feed(Data("TAIL".utf8), into: &text)
        XCTAssertEqual(text.count, TerminalTextFilter.maxCharacters)
        XCTAssertTrue(text.hasSuffix("TAIL"), "保留的是最新的内容")
    }

    func testConsoleLogDecoding() {
        XCTAssertEqual(ConsoleLog.text(fromHex: HexCoding.encode(Data("[ 0.1] boot\u{1B}[0m\r\nDesk Box ready\n".utf8))),
                       "[ 0.1] boot\nDesk Box ready\n")
        XCTAssertEqual(ConsoleLog.text(fromHex: ""), "")
        XCTAssertNil(ConsoleLog.text(fromHex: "abc"))
    }

    // MARK: PtySessionModel.handlePoll

    func testPtyPollHandling() {
        let model = PtySessionModel(sandboxId: "SB", client: DaemonSocketClient(sockPath: "/nonexistent"))
        var response = DaemonResponse(ok: true)
        response.running = true
        response.outputHex = HexCoding.encode(Data("$ \u{1B}[1mls\u{1B}[0m\r\n".utf8))
        model.handlePoll(.success(response))
        XCTAssertEqual(model.output, "$ ls\n")
        XCTAssertNil(model.error)

        // 畸形 hex：报错但不崩溃，已有输出保留。
        response.outputHex = "abc"
        model.handlePoll(.success(response))
        XCTAssertEqual(model.output, "$ ls\n")
        XCTAssertNotNil(model.error)

        response.outputHex = nil
        response.running = false
        response.exitCode = 3
        model.handlePoll(.success(response))
        XCTAssertFalse(model.running)
        XCTAssertTrue(model.output.hasSuffix("[pty exited code=3]"))

        model.handlePoll(.failure(DaemonClientError.rejected("request rejected (kind=ptyPoll): ptyPoll: sandbox no longer alive")))
        XCTAssertTrue(model.error?.hasPrefix("poll: ") ?? false)
    }
}
