import XCTest
@testable import DeskBoxCore

/// M39：exec 输出的汇总与截断标记。
final class ExecOutputTests: XCTestCase {
    private func hex(_ s: String) -> String { Data(s.utf8).map { String(format: "%02x", $0) }.joined() }
    private func chunked(exit: Int32 = 0, out: Int? = nil, err: Int? = nil, stderr: String = "",
                         outTrunc: Bool = false, errTrunc: Bool = false, timedOut: Bool = false,
                         streamError: Bool = false) -> ControlResponse {
        var r = ControlResponse(exitCode: exit, stdout: "", stderr: stderr)
        r.outputVersion = 2; r.chunked = true; r.stdoutBytes = out; r.stderrBytes = err
        r.stdoutTruncated = outTrunc; r.stderrTruncated = errTrunc; r.timedOut = timedOut; r.streamError = streamError
        return r
    }

    func testChunksAreReassembledPerStreamInOrder() {
        var a = ExecOutputAssembler()
        a.append(ExecOutputChunk(s: 1, dataHex: hex("hello ")))
        a.append(ExecOutputChunk(s: 2, dataHex: hex("warn\n")))
        a.append(ExecOutputChunk(s: 1, dataHex: hex("world\n")))
        let result = a.finish(chunked(out: 12, err: 5))
        XCTAssertEqual(result.stdout, "hello world\n")
        XCTAssertEqual(result.stderr, "warn\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.stdoutTruncated || result.stderrTruncated || result.possiblyTruncated || result.timedOut)
        XCTAssertNil(result.integrityProblem)
        XCTAssertEqual(result.notices, [])
        XCTAssertEqual(result.guestOutputVersion, 2)
    }

    func testGuestReportedTruncationIsSurfaced() {
        var a = ExecOutputAssembler()
        a.append(ExecOutputChunk(s: 1, dataHex: hex("abcd")))
        let result = a.finish(chunked(out: 4, err: 0, outTrunc: true))
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertEqual(result.notices, ["stdout 被截断：只保留了前 4 字节"])
    }

    func testHostEnforcesItsOwnLimitRegardlessOfGuest() {
        // guest 声称没有截断，却发来超过上限的数据：宿主丢弃超出部分并标记截断，且不把它算成「字节数不一致」。
        var a = ExecOutputAssembler(maxBytes: 10)
        a.append(ExecOutputChunk(s: 1, dataHex: hex("12345678")))
        a.append(ExecOutputChunk(s: 1, dataHex: hex("abcdefgh")))
        a.append(ExecOutputChunk(s: 1, dataHex: hex("ignored")))
        a.append(ExecOutputChunk(s: 2, dataHex: hex("e")))
        let result = a.finish(chunked(out: 23, err: 1))
        XCTAssertEqual(result.stdout, "12345678ab")
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertFalse(result.stderrTruncated)
        XCTAssertNil(result.integrityProblem)
    }

    func testByteCountMismatchIsReportedAsIncomplete() {
        var a = ExecOutputAssembler()
        a.append(ExecOutputChunk(s: 1, dataHex: hex("abc")))
        let result = a.finish(chunked(out: 500, err: 0))
        XCTAssertEqual(result.integrityProblem, "stdout 收到 3 字节，guest 报告 500")
        XCTAssertEqual(result.notices, ["输出不完整：stdout 收到 3 字节，guest 报告 500"])
    }

    func testMalformedChunksAndStreamErrors() {
        var a = ExecOutputAssembler()
        a.append(ExecOutputChunk(s: 1, dataHex: "zz"))        // 非 hex
        a.append(ExecOutputChunk(s: 1, dataHex: "abc"))       // 奇数长度
        a.append(ExecOutputChunk(s: 3, dataHex: "00"))        // 未知的流
        a.append(ExecOutputChunk(s: 1, dataHex: "6F6b"))      // 大小写混合，合法
        XCTAssertEqual(a.malformedChunks, 3)
        let result = a.finish(chunked(out: 2, err: 0, streamError: true))
        XCTAssertEqual(result.stdout, "ok")
        XCTAssertEqual(result.integrityProblem, "guest 报告发送输出块失败；3 个输出块无法解析")
    }

    func testTimeoutKeepsPartialOutputAndAppendsGuestExplanation() {
        var a = ExecOutputAssembler()
        a.append(ExecOutputChunk(s: 1, dataHex: hex("before\n")))
        a.append(ExecOutputChunk(s: 2, dataHex: hex("partial")))
        let result = a.finish(chunked(exit: -2, out: 7, err: 7, stderr: "exec timed out; process group killed", timedOut: true))
        XCTAssertEqual(result.stdout, "before\n")
        XCTAssertEqual(result.stderr, "partial\nexec timed out; process group killed")
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, -2)
        XCTAssertEqual(result.notices, [], "新 guest 的超时不需要「旧 guest 可能卡住」的提示")
    }

    func testInvalidUTF8IsDecodedLossilyNotDropped() {
        var a = ExecOutputAssembler()
        a.append(ExecOutputChunk(s: 1, dataHex: "61ff62"))
        let result = a.finish(chunked(out: 3, err: 0))
        XCTAssertEqual(result.stdout, "a\u{FFFD}b")
        XCTAssertNil(result.integrityProblem)
    }

    func testCancelledExecKeepsOutputProducedBeforeTheCancel() throws {
        var a = ExecOutputAssembler()
        a.append(ExecOutputChunk(s: 1, dataHex: hex("started\n")))
        var response = chunked(exit: -3, out: 8, err: 0, stderr: "exec cancelled; process group killed")
        response.cancelled = true
        let result = a.finish(response)
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout, "started\n")
        XCTAssertEqual(result.stderr, "exec cancelled; process group killed")
        XCTAssertEqual(result.exitCode, -3)
        XCTAssertEqual(result.notices, [])
        // 线上格式
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: Data(
            #"{"exitCode":-3,"stdout":"","stderr":"exec cancelled; process group killed","chunked":true,"cancelled":true}"#.utf8))
        XCTAssertEqual(decoded.cancelled, true)
        XCTAssertEqual(ControlMessageKind.execCancel.rawValue, 27)
        let stats = try JSONDecoder().decode(SandboxStats.self, from: Data(#"{"execCancelVersion":1}"#.utf8))
        XCTAssertEqual(stats.execCancelVersion, 1)
        XCTAssertNil(ExecOutputAssembler().finish(ControlResponse(exitCode: 0, stdout: "", stderr: "")).integrityProblem)
        XCTAssertFalse(ExecOutputAssembler().finish(ControlResponse(exitCode: 0, stdout: "", stderr: "")).cancelled)
    }

    // ---- 旧 guest（单帧应答，没有任何新字段） ----

    func testLegacyGuestShortOutputHasNoNotice() {
        let result = ExecOutputAssembler().finish(ControlResponse(exitCode: 0, stdout: "hi\n", stderr: ""))
        XCTAssertEqual(result.stdout, "hi\n")
        XCTAssertEqual(result.guestOutputVersion, 1)
        XCTAssertEqual(result.notices, [])
    }

    func testLegacyGuestOutputAtTheFixedCapIsFlaggedAsPossiblyTruncated() {
        let full = String(repeating: "x", count: 1023)
        let result = ExecOutputAssembler().finish(ControlResponse(exitCode: 0, stdout: full, stderr: ""))
        XCTAssertTrue(result.possiblyTruncated)
        XCTAssertFalse(result.stdoutTruncated, "只是「可能」：1023 字节也可能恰好是全部输出")
        XCTAssertEqual(result.notices.count, 1)
        XCTAssertTrue(result.notices[0].hasPrefix("输出可能被截断"), result.notices[0])
        let almost = ExecOutputAssembler().finish(ControlResponse(exitCode: 0, stdout: String(full.dropLast()), stderr: ""))
        XCTAssertFalse(almost.possiblyTruncated)
        let errFull = ExecOutputAssembler().finish(ControlResponse(exitCode: 0, stdout: "", stderr: full))
        XCTAssertTrue(errFull.possiblyTruncated)
    }

    func testLegacyGuestTimeoutMentionsThePipeStall() {
        let result = ExecOutputAssembler().finish(
            ControlResponse(exitCode: -2, stdout: "", stderr: "exec timed out; process group killed"))
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.notices.count, 1)
        XCTAssertTrue(result.notices[0].contains("64KB"), result.notices[0])
    }

    func testNewGuestSingleFrameModeReportsItsOwnTruncation() {
        // 新 guest + 不请求流式（旧宿主的用法）：截断由 guest 明确报告，不再靠猜。
        var response = ControlResponse(exitCode: 0, stdout: String(repeating: "x", count: 1023), stderr: "")
        response.outputVersion = 2; response.chunked = false; response.stdoutTruncated = true
        let result = ExecOutputAssembler().finish(response)
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertFalse(result.possiblyTruncated)
    }

    func testChunksWithoutChunkedResponseAreFlagged() {
        var a = ExecOutputAssembler()
        a.append(ExecOutputChunk(s: 1, dataHex: hex("stray")))
        let result = a.finish(ControlResponse(exitCode: 0, stdout: "x", stderr: ""))
        XCTAssertEqual(result.stdout, "x")
        XCTAssertNotNil(result.integrityProblem)
    }

    // ---- 线上格式 ----

    func testRequestOnlyCarriesStreamingFieldsWhenSet() throws {
        let plain = ControlRequest(kind: .exec, argv: ["/bin/echo"], timeoutSeconds: 5)
        let plainJSON = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(plainJSON.contains("streamOutput"), plainJSON)
        var streaming = plain
        streaming.streamOutput = true
        streaming.maxOutputBytes = 4096
        let json = String(decoding: try JSONEncoder().encode(streaming), as: UTF8.self)
        // guest 用 strstr 找这两个确切的片段。
        XCTAssertTrue(json.contains("\"streamOutput\":true"), json)
        XCTAssertTrue(json.contains("\"maxOutputBytes\":4096"), json)
    }

    func testArgvCannotSmuggleTheStreamingFlag() throws {
        // argv 里的同名文本会被 JSON 转义（引号前有反斜杠），guest 的 strstr 匹配不到。
        let request = ControlRequest(kind: .exec, argv: ["/bin/echo", "\"streamOutput\":true"])
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertFalse(json.contains("\"streamOutput\":true"), json)
    }

    func testResponseDecodesWithAndWithoutNewFields() throws {
        let old = try JSONDecoder().decode(ControlResponse.self, from: Data(#"{"exitCode":0,"stdout":"a","stderr":""}"#.utf8))
        XCTAssertNil(old.chunked)
        XCTAssertNil(old.outputVersion)
        let new = try JSONDecoder().decode(ControlResponse.self, from: Data(
            #"{"exitCode":-2,"stdout":"","stderr":"exec timed out; process group killed","outputVersion":2,"chunked":true,"stdoutBytes":7,"stderrBytes":0,"stdoutTruncated":false,"stderrTruncated":true,"timedOut":true,"streamError":false}"#.utf8))
        XCTAssertEqual(new.chunked, true)
        XCTAssertEqual(new.stdoutBytes, 7)
        XCTAssertEqual(new.stderrTruncated, true)
        XCTAssertEqual(new.timedOut, true)
        XCTAssertEqual(ControlMessageKind.execOutput.rawValue, 26)
    }

    func testStatsReportsExecOutputVersion() throws {
        let old = try JSONDecoder().decode(SandboxStats.self, from: Data(#"{"activeExecGroups":0,"workspaceSyncVersion":2}"#.utf8))
        XCTAssertNil(old.execOutputVersion)
        let new = try JSONDecoder().decode(SandboxStats.self, from: Data(#"{"activeExecGroups":0,"workspaceSyncVersion":2,"execOutputVersion":2}"#.utf8))
        XCTAssertEqual(new.execOutputVersion, 2)
    }
}
