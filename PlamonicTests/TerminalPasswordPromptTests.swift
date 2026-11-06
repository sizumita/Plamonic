import ApplicationServices
import XCTest

@testable import Plamonic

/// Terminal password prompts (DESIGN §4.1): which lines are prompts, which line of the screen is checked, and
/// the ranges read with the visible range. Synthetic lines only.
final class TerminalPasswordPromptTests: XCTestCase {
    private func lines(_ rows: [String], base: Int = 0) -> [TerminalLine] {
        TerminalSegmenter.lines(fromScreen: rows.joined(separator: "\n"), baseOffset: base)
    }

    /// The insertion point right after the last character of `row` (or at `column` UTF-16 units into it).
    private func caret(_ screen: [TerminalLine], row: Int, column: Int? = nil) -> CFRange {
        let line = screen[row]
        return CFRange(location: line.utf16Offset + (column ?? line.text.utf16.count), length: 0)
    }

    // MARK: - One line

    func testPromptsOfCommonTools() {
        let prompts = [
            // sudo (macOS, Linux, Japanese locale), su, login
            "Password:", "Password: ", "Password:\t", "[sudo] password for demo:", "[sudo] password for demo: ",
            "[sudo] demo のパスワード:", "password for demo:",
            // ssh, ssh-add, ssh-keygen
            "demo@host's password: ", "(demo@host) Password:", "Enter passphrase for key '/Users/demo/.ssh/id_ed25519': ",
            "Enter passphrase for /Users/demo/.ssh/id_ed25519:", "Enter passphrase (empty for no passphrase): ",
            "Enter same passphrase again: ", "Bad passphrase, try again for /Users/demo/.ssh/id_ed25519: ",
            "Enter PIN for 'PIV Card Holder pin (PIV_II)': ", "Enter PIN for authenticator:",
            // git over https, curl
            "Password for 'https://demo@github.com': ", "Enter host password for user 'demo':",
            // databases
            "Enter password:", "Password for user postgres: ",
            // gpg / pinentry-tty, openssl
            "Passphrase:", "Enter passphrase:", "Enter PEM pass phrase:", "Verifying - Enter PEM pass phrase:",
            "Enter Import Password:",
            // passwd, Django, ansible, inquirer-style CLIs
            "New password:", "Retype new password:", "(current) UNIX password:", "Password (again):",
            "Verify password:", "Vault password: ", "BECOME password:", "? Master password: [input is hidden] ",
            // PIN, passcode
            "Enter PIN:", "PIN:", "Enter passcode:",
            // Other languages
            "パスワード:", "パスワード：", "パスワード： ", "パスワードを入力してください:", "パスフレーズ:", "暗証番号：",
            "Mot de passe :", "Passwort:", "[sudo] Passwort für demo:", "Contraseña:", "Senha:", "Пароль:",
            "[sudo] пароль для demo:", "密码：", "[sudo] demo 的密码：", "密碼:", "비밀번호:", "[sudo] demo의 암호:",
            // Inside a TUI box, and sudo's pwfeedback stars
            "│ Password:                    │", "[sudo] password for demo: ****", "Password: •••• ",
        ]
        for line in prompts {
            XCTAssertTrue(TerminalPasswordPrompt.matches(line), "should be a prompt: \(line)")
        }
    }

    func testLinesThatAreNotPrompts() {
        let others = [
            // Text after the colon is a value, not a hidden input.
            "Password: hunter2", "password: hunter2", "Passphrase: correct horse", "パスワード: abc123",
            // Lines that only mention passwords.
            "Password updated.", "passwd: password updated successfully", "Saved the password.",
            "Sorry, try again.", "sudo: 2 incorrect password attempts", "Forgot your password?",
            "Passwords:", "Saved passwords:", "Password manager", "암호화:",
            // Other words that contain a password word.
            "Pinned items:", "Spinning up the following:", "Opinions:", "Shipping list:", "Username:",
            "Username for 'https://github.com': ",
            // Paths, files and URLs.
            "https://example.com/password:", "See https://example.com/reset-password:",
            "http://localhost:8080/login?next=password:", "cat ~/.config/password:", "Wrote password.txt:",
            "my_password:", "password_file:",
            // Shell prompts and blanks.
            "demo@host ~ % ", "demo@host:~$ ", "", "   ", ":",
            // A line that is too long to be a prompt.
            String(repeating: "x", count: 250) + " password:",
            // Too much text between the word and the colon.
            "password " + String(repeating: "y", count: 130) + ":",
        ]
        for line in others {
            XCTAssertFalse(TerminalPasswordPrompt.matches(line), "should not be a prompt: \(line)")
        }
    }

    // MARK: - Which line

    func testLastNonEmptyLineIsChecked() {
        let screen = lines(["demo@host ~ % sudo ls", "Password:", "", ""])
        XCTAssertTrue(TerminalPasswordPrompt.isWaiting(lines: screen, insertionPoint: nil))
    }

    func testPromptFollowedByMoreOutputIsNotWaiting() {
        let answered = lines(["demo@host ~ % sudo ls", "Password:", "Sorry, try again.", "demo@host ~ % "])
        XCTAssertFalse(TerminalPasswordPrompt.isWaiting(lines: answered, insertionPoint: nil))
        let done = lines(["[sudo] password for demo: ", "Applications  Library  System", "demo@host:~$"])
        XCTAssertFalse(TerminalPasswordPrompt.isWaiting(lines: done, insertionPoint: nil))
        // sudo asks again after a wrong password.
        let again = lines(["Password:", "Sorry, try again.", "Password:"])
        XCTAssertTrue(TerminalPasswordPrompt.isWaiting(lines: again, insertionPoint: nil))
    }

    func testEmptyScreenIsNotWaiting() {
        XCTAssertFalse(TerminalPasswordPrompt.isWaiting(lines: [], insertionPoint: nil))
        XCTAssertFalse(TerminalPasswordPrompt.isWaiting(lines: lines(["", "  "]), insertionPoint: nil))
    }

    func testInsertionPointFindsAPromptAboveAStatusLine() {
        // tmux: the status line is the last line, the cursor waits after the prompt.
        let screen = lines(
            ["demo@host ~ % ssh build", "demo@build's password: ", "", "[0] 0:ssh*                 \"build\" 12:00"],
            base: 5000)
        XCTAssertFalse(TerminalPasswordPrompt.isWaiting(lines: screen, insertionPoint: nil))
        XCTAssertTrue(TerminalPasswordPrompt.isWaiting(lines: screen, insertionPoint: caret(screen, row: 1)))
    }

    func testInsertionPointInsideALeftPane() {
        // Side by side panes: only the text before the cursor is checked, the rest is the border and blanks.
        let screen = lines(["Password:            │ other pane: ok", "                     │"])
        XCTAssertTrue(
            TerminalPasswordPrompt.isWaiting(lines: screen, insertionPoint: caret(screen, row: 0, column: 10)))
    }

    func testInsertionPointWithTextAfterItIsNotAPrompt() {
        let screen = lines(["Password: please wait", "% "])
        XCTAssertNil(TerminalPasswordPrompt.lineBefore(caret(screen, row: 0, column: 9), in: screen))
        XCTAssertFalse(
            TerminalPasswordPrompt.isWaiting(lines: screen, insertionPoint: caret(screen, row: 0, column: 9)))
    }

    func testSelectionsAndPointsOffTheScreenFallBackToTheLastLine() {
        let screen = lines(["output", "Password:"], base: 100)
        // A mouse selection, a point above the screen and one past it.
        for point in [
            CFRange(location: 100, length: 6), CFRange(location: 10, length: 0), CFRange(location: 10_000, length: 0),
        ] {
            XCTAssertNil(TerminalPasswordPrompt.lineBefore(point, in: screen))
            XCTAssertTrue(TerminalPasswordPrompt.isWaiting(lines: screen, insertionPoint: point))
        }
        let shell = lines(["Password:", "Sorry, try again.", "% "], base: 100)
        XCTAssertFalse(
            TerminalPasswordPrompt.isWaiting(lines: shell, insertionPoint: CFRange(location: 100, length: 9)),
            "a selected prompt is no insertion point")
    }

    func testLineBeforeUsesUTF16Offsets() {
        let screen = lines(["👋 こんにちは", "👋 [sudo] demo のパスワード: "], base: 42)
        XCTAssertEqual(screen[1].utf16Offset, 42 + "👋 こんにちは".utf16.count + 1)
        XCTAssertEqual(
            TerminalPasswordPrompt.lineBefore(caret(screen, row: 1), in: screen), "👋 [sudo] demo のパスワード: ")
        XCTAssertEqual(
            TerminalPasswordPrompt.lineBefore(caret(screen, row: 1, column: 22), in: screen),
            "👋 [sudo] demo のパスワード:", "the trailing space is blank")
        XCTAssertNil(TerminalPasswordPrompt.lineBefore(caret(screen, row: 1, column: 2), in: screen))
        XCTAssertNil(TerminalPasswordPrompt.lineBefore(caret(screen, row: 0, column: 0), in: screen))
        XCTAssertTrue(TerminalPasswordPrompt.isWaiting(lines: screen, insertionPoint: caret(screen, row: 1)))
    }

    func testCaretAtTheStartOfAnEmptyLineBelowThePromptStillPauses() {
        // After Return the cursor moves down before the output comes: the password was not echoed.
        let screen = lines(["Password:", ""])
        XCTAssertTrue(TerminalPasswordPrompt.isWaiting(lines: screen, insertionPoint: caret(screen, row: 1)))
    }

    // MARK: - Typed marks

    func testTypedMarksAfterAPromptBecomeSpaces() {
        let prompts = [
            "[sudo] password for demo: ••••", "[sudo] password for demo: *", "Password: ********", "Password: •••• ",
            "? Password: ●●●●●●", "Enter passphrase: ∙∙∙", "Passphrase: ···", "[sudo] demo のパスワード: ***",
            "│ Password: ****               │",
        ]
        for line in prompts {
            let blanked = TerminalPasswordPrompt.blankingInput(line)
            XCTAssertEqual(blanked.utf16.count, line.utf16.count, "offsets stay valid: \(line)")
            XCTAssertFalse(blanked.contains { "*•●∙·".contains($0) }, "no marks left: \(blanked)")
            XCTAssertTrue(TerminalPasswordPrompt.matches(blanked), "still a prompt: \(blanked)")
            let kept = line.prefix { !"*•●∙·".contains($0) }
            XCTAssertTrue(blanked.hasPrefix(kept), "the prompt itself stays: \(blanked)")
        }
        XCTAssertEqual(
            TerminalPasswordPrompt.blankingInput("│ Password: ****    │"), "│ Password:         │",
            "the border after the input stays")
    }

    func testOtherLinesAreNotChanged() {
        let others = [
            "a * b ***", "Rating: ***", "Password: hunter2", "Password: ab**", "Password:", "[sudo] password for demo: ",
            "* * *", "•••• Password:", "Password: * *", "demo@host ~ % echo '***'", "",
        ]
        for line in others {
            XCTAssertEqual(TerminalPasswordPrompt.blankingInput(line), line)
        }
    }

    /// The lines the terminal reader segments: typing a password with marks changes no paragraph text, and no
    /// mark reaches a paragraph (and so no translation or cache entry). Also for the prompt left in the
    /// scrollback after Return.
    func testTypingMarksChangesNoParagraph() throws {
        func paragraphs(_ rows: [String]) -> (texts: [String], waiting: Bool) {
            let screen = ExtractionWalk.terminalLines(
                fromScreen: rows.joined(separator: "\n"), baseOffset: 300, maxLines: 300)
            let caret = screen.last(where: { !$0.text.allSatisfy(\.isWhitespace) }).map {
                CFRange(location: $0.utf16Offset + $0.text.utf16.count, length: 0)
            }
            return (
                TerminalSegmenter.segment(screen, columns: 80).map(\.text),
                TerminalPasswordPrompt.isWaiting(lines: screen, insertionPoint: caret)
            )
        }
        let output = ["demo@host ~ % sudo make install", "Installing the files into the system folders.", ""]
        let empty = paragraphs(output + ["[sudo] password for demo: "])
        XCTAssertTrue(empty.waiting)
        XCTAssertTrue(empty.texts.contains { $0.contains("password for demo:") }, "the prompt is still read")
        for mark in ["•", "*", "●"] {
            for count in [1, 3, 8, 20] {
                let typed = paragraphs(output + ["[sudo] password for demo: " + String(repeating: mark, count: count)])
                XCTAssertEqual(typed.texts, empty.texts, "\(count) × \(mark)")
                XCTAssertTrue(typed.waiting, "\(count) × \(mark)")
                XCTAssertFalse(typed.texts.joined().contains(mark), "\(count) × \(mark)")
            }
        }
        // After Return the prompt stays above the output.
        let done = paragraphs(output + ["[sudo] password for demo: ••••••", "Installed 12 files.", "demo@host ~ % "])
        XCTAssertFalse(done.waiting)
        XCTAssertFalse(done.texts.joined().contains("•"))
    }

    func testBlankedLinesKeepTheirOffsets() {
        let rows = ["👋 output", "[sudo] demo のパスワード: ●●●●", "next"]
        let raw = TerminalSegmenter.lines(fromScreen: rows.joined(separator: "\n"), baseOffset: 42)
        let read = ExtractionWalk.terminalLines(fromScreen: rows.joined(separator: "\n"), baseOffset: 42, maxLines: 300)
        XCTAssertEqual(read.map(\.utf16Offset), raw.map(\.utf16Offset))
        XCTAssertEqual(read.map(\.row), raw.map(\.row))
        XCTAssertEqual(read.map(\.text.utf16.count), raw.map(\.text.utf16.count))
        XCTAssertEqual(read[1].text, "[sudo] demo のパスワード:     ")
        XCTAssertEqual(
            ExtractionWalk.terminalLines(fromScreen: rows.joined(separator: "\n"), baseOffset: 42, maxLines: 2)
                .map(\.row), [1, 2], "the last lines are kept")
    }

    // MARK: - Ranges read with the visible range

    func testRangesAreDecodedAndErrorsAreNil() throws {
        var visible = CFRange(location: 120, length: 2400)
        var caret = CFRange(location: 2500, length: 0)
        var error = AXError.attributeUnsupported
        let v = try XCTUnwrap(AXValueCreate(.cfRange, &visible))
        let c = try XCTUnwrap(AXValueCreate(.cfRange, &caret))
        let e = try XCTUnwrap(AXValueCreate(.axError, &error))

        let both = ExtractionWalk.terminalRanges(values: [v, c])
        XCTAssertEqual(both.visible?.location, 120)
        XCTAssertEqual(both.visible?.length, 2400)
        XCTAssertEqual(both.selected?.location, 2500)
        XCTAssertEqual(both.selected?.length, 0)

        let noCaret = ExtractionWalk.terminalRanges(values: [v, e])
        XCTAssertEqual(noCaret.visible?.location, 120)
        XCTAssertNil(noCaret.selected)

        let nothing = ExtractionWalk.terminalRanges(values: [NSNull(), "text" as NSString])
        XCTAssertNil(nothing.visible)
        XCTAssertNil(nothing.selected)
        XCTAssertNil(ExtractionWalk.terminalRanges(values: []).visible)
    }

    // MARK: - Cost

    func testChecksAreCheap() {
        // A full screen: only the caret line and the last line are checked.
        var rows = (0..<300).map { "line \($0): some output that mentions a password:" }
        rows.append("[sudo] password for demo: ")
        rows += ["", ""]
        let screen = lines(rows)
        let point = caret(screen, row: 300)
        var waiting = 0
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<1000 where TerminalPasswordPrompt.isWaiting(lines: screen, insertionPoint: point) {
            waiting += 1
        }
        XCTAssertEqual(waiting, 1000)
        XCTAssertLessThan((CFAbsoluteTimeGetCurrent() - start) / 1000, 0.001)
    }
}
