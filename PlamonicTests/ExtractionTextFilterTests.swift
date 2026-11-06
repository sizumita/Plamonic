import XCTest

@testable import Plamonic

final class ExtractionTextFilterTests: XCTestCase {
    private func reason(_ text: String, min: Int = 2) -> TextRejection? {
        TextFilters.rejection(for: text, minLength: min)
    }

    func testRejectsNonLanguage() {
        XCTAssertEqual(reason(""), .empty)
        XCTAssertEqual(reason("a"), .tooShort)
        XCTAssertEqual(reason("12:30"), .noLetters)
        XCTAssertEqual(reason("+12 -4"), .noLetters)
        XCTAssertEqual(reason("🎉🎉"), .noLetters)
        XCTAssertEqual(reason("10:30 AM"), .numeric)
        XCTAssertEqual(reason("2025年11月5日"), .numeric)
        XCTAssertEqual(reason("3h"), .numeric)
        XCTAssertEqual(reason("1.2k"), .numeric)
        XCTAssertEqual(reason(":thumbsup: :tada:"), .emojiShortcode)
    }

    func testRejectsURLsAndPaths() {
        XCTAssertEqual(reason("https://example.com/a?b=c"), .url)
        XCTAssertEqual(reason("example.com"), .url)
        XCTAssertEqual(reason("foo@bar.com"), .url)
        XCTAssertEqual(reason("https://a.example.com https://b.example.com"), .url)
        XCTAssertEqual(reason("/usr/local/bin"), .filePath)
        XCTAssertEqual(reason("~/Workspace/x"), .filePath)
        XCTAssertEqual(reason("src/main.swift"), .filePath)
        XCTAssertEqual(reason("README.md"), .filePath)
    }

    func testRejectsCode() {
        XCTAssertEqual(reason("let x = foo(bar);"), .codeLike)
        XCTAssertEqual(reason("git commit -m \"fix\""), .codeLike)
        XCTAssertEqual(reason("snake_case_name"), .codeLike)
        XCTAssertEqual(reason("camelCaseName"), .codeLike)
        XCTAssertEqual(reason("if (a == b) {"), .codeLike)
        XCTAssertEqual(reason("func a() {\n  return 1\n}"), .codeLike)
    }

    func testRejectsShellCommands() {
        for text in [
            "git push", "npm install", "brew install ripgrep", "ls -la", "cd ~/src", "cd ..", "go test ./...",
            "go build", "swift build", "make -j8", "echo $PATH", "export FOO=bar", "cat README.md",
            "python main.py", "find . -name '*.swift'", "claude --version", "git log --oneline | head -5",
            "git commit -m \"don't, panic\"",
        ] {
            XCTAssertEqual(reason(text), .codeLike, text)
        }
    }

    func testKeepsChatThatStartsWithACommandName() {
        for text in [
            "make sense?", "claude is great", "go ahead - it's fine with me",
            "make sure you update the config/settings first", "find the bug in the auth/login flow please",
            "head out now", "cd into the folder and run it", "go get some coffee", "git is great, isn't it?",
        ] {
            XCTAssertNil(reason(text), text)
        }
    }

    func testKeepsProse() {
        for text in [
            "Hello world", "こんにちは", "OK", "Use the foo() function to start.", "Today at 10:30",
            "I moved it to src/main.swift yesterday.", "We shipped v2.0 today!", "Thanks 🙏",
            "設定画面で `scope` を変更してください。",
        ] {
            XCTAssertNil(reason(text), text)
        }
    }

    func testLimitsAndIgnorePatterns() {
        XCTAssertEqual(TextFilters.rejection(for: "abcdef", minLength: 2, maxLength: 5), .tooLong)
        XCTAssertEqual(reason("ab", min: 3), .tooShort)
        let ignore = IgnorePatterns(["^\\[bot\\]", "("])
        XCTAssertEqual(ignore.invalidPatterns, ["("])
        XCTAssertEqual(TextFilters.rejection(for: "[bot] deployed v2", minLength: 2, ignore: ignore), .ignoredPattern)
        XCTAssertNil(TextFilters.rejection(for: "deployed by [bot]", minLength: 2, ignore: ignore))
    }

    func testNormalize() {
        XCTAssertEqual(TextFilters.normalize("  a \u{200B}b  \n\n\n  c\t d "), "a b\n\nc d")
        XCTAssertEqual(TextFilters.normalize("全角\u{3000}スペース"), "全角\u{3000}スペース")
    }

    func testMetrics() {
        XCTAssertEqual(TextMetrics.cellWidth("aあ字"), 5)
        XCTAssertEqual(TextMetrics.joinWrapped("foo", "bar"), "foo bar")
        XCTAssertEqual(TextMetrics.joinWrapped("日本", "語"), "日本語")
        XCTAssertEqual(TextMetrics.joinWrapped("end.", "次"), "end.次")
        XCTAssertEqual(TextMetrics.stableHash("hello"), "a430d84680aabd0b")
        XCTAssertTrue(TextMetrics.isCJK(Character("字")))
        XCTAssertFalse(TextMetrics.isCJK(Character("한")))
    }
}
