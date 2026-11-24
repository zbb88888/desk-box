import XCTest
@testable import DeskBoxGUI

/// M32：Exec 输入框的命令行分词。
final class ExecCommandLineTests: XCTestCase {
    private func argv(_ line: String) throws -> [String] { try ExecCommandLine.argv(from: line) }

    func testPlainWordsSplitOnWhitespace() throws {
        XCTAssertEqual(try argv("/bin/echo hello world"), ["/bin/echo", "hello", "world"])
        XCTAssertEqual(try argv("  /bin/echo \t a\n b  "), ["/bin/echo", "a", "b"])
        XCTAssertEqual(try argv(""), [])
        XCTAssertEqual(try argv("   \t "), [])
    }

    func testTheCaseThatUsedToBeImpossible() throws {
        // 旧实现：["/bin/sh", "-c", "'echo", "a", "b'"]
        XCTAssertEqual(try argv("/bin/sh -c 'echo a b'"), ["/bin/sh", "-c", "echo a b"])
        XCTAssertEqual(try argv(#"/bin/sh -c "echo a b""#), ["/bin/sh", "-c", "echo a b"])
    }

    func testSingleQuotesAreLiteral() throws {
        XCTAssertEqual(try argv(#"'a "b" \n $HOME'"#), [#"a "b" \n $HOME"#])
    }

    func testDoubleQuoteEscapes() throws {
        XCTAssertEqual(try argv(#""say \"hi\"""#), [#"say "hi""#])
        XCTAssertEqual(try argv(#""back\\slash""#), [#"back\slash"#])
        // 其它反斜杠在双引号内保留（POSIX）。
        XCTAssertEqual(try argv(#""a\nb""#), [#"a\nb"#])
        XCTAssertEqual(try argv(#""it's""#), ["it's"])
    }

    func testBackslashOutsideQuotes() throws {
        XCTAssertEqual(try argv(#"a\ b c"#), ["a b", "c"])
        XCTAssertEqual(try argv(#"\'x\'"#), ["'x'"])
    }

    func testAdjacentPiecesConcatenate() throws {
        XCTAssertEqual(try argv(#"a"b c"'d e'f"#), ["ab cd ef"])
        XCTAssertEqual(try argv("--name='x y'"), ["--name=x y"])
    }

    func testEmptyStringArguments() throws {
        XCTAssertEqual(try argv("/bin/echo '' x"), ["/bin/echo", "", "x"])
        XCTAssertEqual(try argv(#""""#), [""])
        XCTAssertEqual(try argv("''''"), [""])   // 两个相邻的空引号拼成一个空参数
    }

    func testNoExpansionOfAnyKind() throws {
        // 只分词：结果原样作为 argv，不经过 shell。
        XCTAssertEqual(try argv("/bin/echo $HOME *.txt `id` $(id) ; rm -rf / | cat > x"),
                       ["/bin/echo", "$HOME", "*.txt", "`id`", "$(id)", ";", "rm", "-rf", "/", "|", "cat", ">", "x"])
    }

    func testUnicodeIsPreserved() throws {
        XCTAssertEqual(try argv("/bin/echo '你好 世界' 🙂"), ["/bin/echo", "你好 世界", "🙂"])
    }

    func testMalformedInputIsRejectedNotGuessed() {
        XCTAssertThrowsError(try argv("/bin/echo 'oops")) { XCTAssertEqual($0 as? ExecCommandLine.ParseError, .unterminatedSingleQuote) }
        XCTAssertThrowsError(try argv(#"/bin/echo "oops"#)) { XCTAssertEqual($0 as? ExecCommandLine.ParseError, .unterminatedDoubleQuote) }
        XCTAssertThrowsError(try argv(#"/bin/echo "oops\"#)) { XCTAssertEqual($0 as? ExecCommandLine.ParseError, .unterminatedDoubleQuote) }
        XCTAssertThrowsError(try argv(#"/bin/echo x\"#)) { XCTAssertEqual($0 as? ExecCommandLine.ParseError, .trailingBackslash) }
        for error in [ExecCommandLine.ParseError.unterminatedSingleQuote, .unterminatedDoubleQuote, .trailingBackslash] {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }
}
