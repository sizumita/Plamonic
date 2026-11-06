import CoreGraphics
import XCTest

@testable import Plamonic

private typealias F = TranslationTestFixtures

/// DESIGN §6.1 「訳文の中のリンク」: links carried through translation.
final class TranslationLinkTests: XCTestCase {
    // MARK: - Helpers

    /// A segment text written as "Please read [[the setup guide]] now": the doubled brackets mark links.
    private func linked(_ marked: String, kind: SegmentLinkKind = .link) -> (text: String, links: [SegmentLink]) {
        var text = ""
        var links: [SegmentLink] = []
        var rest = Substring(marked)
        while let open = rest.range(of: "[[") {
            text += rest[..<open.lowerBound]
            let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex)!
            let anchor = String(rest[open.upperBound..<close.lowerBound])
            let start = text.utf16.count
            text += anchor
            links.append(SegmentLink(range: start..<text.utf16.count, text: anchor, kind: kind))
            rest = rest[close.upperBound...]
        }
        text += rest
        return (text, links)
    }

    private func makePlan(_ marked: String, maxLength: Int? = nil) -> TranslationLinks.Plan? {
        let (text, links) = linked(marked)
        return TranslationLinks.plan(
            source: text, links: links, normalized: TextSanitizer.normalizeMapped(text, maxLength: maxLength))
    }

    /// The linked parts of a mapped translation, as (link index, text).
    private func pieces(_ mapped: TranslationLinks.Mapped) -> [String] {
        let units = Array(mapped.text.utf16)
        return mapped.links.map { "\($0.linkIndex):" + String(decoding: units[$0.range], as: UTF16.self) }
    }

    private func assertNoMarkup(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            text.contains(where: { "[]［］".contains($0) }) || text.range(of: #"\(\d"#, options: .regularExpression) != nil,
            "markup shows in \(text.debugDescription)", file: file, line: line)
    }

    // MARK: - Planning

    func testEveryLinkKindIsClassified() {
        let verbatim = [
            "https://example.com/docs", "https://github.com/sizumita/plamonic/actions/runs/1234567890",
            "www.example.com", "@sizumita", "@Alice Tanaka", "＠alice", "#dev-translation", "#123",
            "TranslationCoordinator.swift", "scripts/setup.sh", "README.md", "alice@example.com", "snake_case_name",
            "GitHub", "iOS", "2026",
        ]
        for text in verbatim {
            XCTAssertTrue(TranslationLinks.isVerbatim(text, kind: .link), text)
        }
        let anchors = ["the setup guide", "Click here", "FAQ", "our blog", "セットアップガイド", "v2.0のリリース", "mlx-swift 0.32.3"]
        for text in anchors {
            XCTAssertFalse(TranslationLinks.isVerbatim(text, kind: .button), text)
        }
        XCTAssertTrue(TranslationLinks.isVerbatim("the setup guide", kind: .detected), "detected links have no anchor text")
    }

    func testOnlyNaturalLanguageAnchorsAreMarked() throws {
        let plan = try XCTUnwrap(
            makePlan("Thanks [[@alice]] for [[the review]], see [[https://example.com/a]] and [[our FAQ]] in [[README.md]]."))
        XCTAssertEqual(plan.plain, "Thanks @alice for the review, see https://example.com/a and our FAQ in README.md.")
        XCTAssertEqual(
            plan.input, "Thanks @alice for [the review](1), see https://example.com/a and [our FAQ](2) in README.md.")
        XCTAssertEqual(plan.links.map(\.markupID), [nil, 1, nil, 2, nil])
        XCTAssertEqual(plan.links.map(\.isVerbatim), [true, false, true, false, true])
        XCTAssertTrue(plan.usesMarkup)

        let verbatimOnly = try XCTUnwrap(makePlan("Run [[scripts/setup.sh]] and ping [[#dev]]"))
        XCTAssertEqual(verbatimOnly.input, verbatimOnly.plain, "verbatim links are sent as they are")
        XCTAssertFalse(verbatimOnly.usesMarkup)
    }

    func testSourceThatReadsLikeMarkupIsSentPlain() throws {
        let plan = try XCTUnwrap(makePlan("See [the docs](1) or [[the setup guide]]"))
        XCTAssertEqual(plan.input, plan.plain)
        XCTAssertEqual(plan.links.map(\.markupID), [nil])
        // The anchor is still found when the model keeps it.
        let mapped = TranslationLinks.map("[the docs](1) か the setup guide を見て", plan: plan, isPartial: false)
        XCTAssertEqual(mapped.text, "[the docs](1) か the setup guide を見て", "unmarked text is never stripped")
        XCTAssertEqual(pieces(mapped), ["0:the setup guide"])

        let bracketed = try XCTUnwrap(makePlan("Read [[the [beta] notes]] first"))
        XCTAssertEqual(bracketed.links.map(\.markupID), [nil], "an anchor with brackets is not marked")
    }

    // MARK: - Normalization

    func testLinksFollowNormalization() throws {
        let raw = "  Please\u{00A0}\u{00A0}read\r\n\r\n\r\n   the\u{200B}   [[setup   guide]]  🎉 and  [[@bob]]\t"
        let plan = try XCTUnwrap(makePlan(raw))
        XCTAssertEqual(plan.plain, "Please read\n\nthe setup guide 🎉 and @bob")
        XCTAssertEqual(plan.links.map(\.text), ["setup guide", "@bob"])
        XCTAssertEqual(plan.links.map(\.index), [0, 1])
        XCTAssertEqual(plan.input, "Please read\n\nthe [setup guide](1) 🎉 and @bob")
    }

    func testLinksBeyondTheCutAreDropped() throws {
        let words = String(repeating: "word ", count: 20)
        let source = "Start with [[the guide]]. " + words + "then [[the second guide]] at the end."
        let plan = try XCTUnwrap(makePlan(source, maxLength: 60))
        XCTAssertLessThanOrEqual(plan.plain.count, 60)
        XCTAssertEqual(plan.links.map(\.text), ["the guide"])
        XCTAssertEqual(plan.input, "Start with [the guide](1). " + String(plan.plain.dropFirst("Start with the guide. ".count)))

        // A link that the cut runs through is dropped too.
        XCTAssertNil(self.makePlan("[[" + String(repeating: "long anchor text ", count: 10) + "]]", maxLength: 40))
    }

    func testLinksWithRangesThatDoNotFitAreIgnored() {
        let text = "Read the guide"
        let links = [
            SegmentLink(range: 9..<40, text: "guide"), SegmentLink(range: -1..<3, text: "Rea"),
            SegmentLink(range: 4..<4, text: ""),
        ]
        XCTAssertNil(TranslationLinks.plan(source: text, links: links, normalized: TextSanitizer.normalizeMapped(text)))
        let overlapping = [SegmentLink(range: 5..<14, text: "the guide"), SegmentLink(range: 9..<14, text: "guide")]
        let plan = TranslationLinks.plan(
            source: text, links: overlapping, normalized: TextSanitizer.normalizeMapped(text))
        XCTAssertEqual(plan?.links.map(\.index), [0])
    }

    func testNormalizeMappedMatchesNormalize() {
        let samples = [
            "", "  a  b  ", "line1\r\nline2\r\n\r\n\r\nline3", "x\u{200B}y\u{FEFF}z", "😀  emoji  👍🏽 text",
            "<|plamo:tag|> injected", "日本語\u{3000}\u{3000}テキスト", String(repeating: "long sentence. ", count: 30),
        ]
        for sample in samples {
            for limit in [nil, 10, 100] as [Int?] {
                let mapped = TextSanitizer.normalizeMapped(sample, maxLength: limit)
                XCTAssertEqual(mapped.text, TextSanitizer.normalize(sample, maxLength: limit))
                XCTAssertEqual(mapped.offsets.count, mapped.text.utf16.count)
                XCTAssertEqual(mapped.offsets, mapped.offsets.sorted(), "offsets never decrease")
                XCTAssertTrue(mapped.offsets.allSatisfy { $0 <= sample.utf16.count })
            }
        }
    }

    // MARK: - Mapping

    func testMarkedAnchorsMapByNumberAcrossWordOrder() throws {
        let plan = try XCTUnwrap(makePlan("I opened [[an issue on GitHub]] about the leak in [[the overlay code]]."))
        let mapped = TranslationLinks.map(
            "[オーバーレイのコード](2)のメモリリークについて[GitHubでIssue](1)を立てました。", plan: plan, isPartial: false)
        XCTAssertEqual(mapped.text, "オーバーレイのコードのメモリリークについてGitHubでIssueを立てました。")
        XCTAssertEqual(pieces(mapped), ["1:オーバーレイのコード", "0:GitHubでIssue"], "text order, numbers follow the anchors")
    }

    func testVerbatimLinksAreFoundAsTheyAre() throws {
        let plan = try XCTUnwrap(
            makePlan(
                "[[@channel]] see [[https://github.com/sizumita/plamonic/actions/runs/1234567890]], [[#incidents]], "
                    + "[[#4521]], [[TranslationCoordinator.swift]] and [[GitHub]]"))
        let output =
            "@channel https://github.com/sizumita/plamonic/actions/runs/1234567890 を参照。#incidents、#4521、"
            + "TranslationCoordinator.swift、GitHub も。"
        let mapped = TranslationLinks.map(output, plan: plan, isPartial: false)
        XCTAssertEqual(mapped.text, output)
        XCTAssertEqual(
            pieces(mapped),
            [
                "0:@channel", "1:https://github.com/sizumita/plamonic/actions/runs/1234567890", "2:#incidents",
                "3:#4521", "4:TranslationCoordinator.swift", "5:GitHub",
            ])
    }

    func testRepeatedAnchorsMapInOrder() throws {
        let plan = try XCTUnwrap(makePlan("[[@bob]] asked [[@bob]] about [[the guide]] and [[the guide]] again"))
        XCTAssertEqual(plan.input, "@bob asked @bob about [the guide](1) and [the guide](2) again")
        let mapped = TranslationLinks.map(
            "@bob は @bob に[ガイド](1)と[ガイド](2)について再び尋ねた", plan: plan, isPartial: false)
        XCTAssertEqual(mapped.text, "@bob は @bob にガイドとガイドについて再び尋ねた")
        XCTAssertEqual(pieces(mapped), ["0:@bob", "1:@bob", "2:ガイド", "3:ガイド"])
        XCTAssertEqual(mapped.links.map(\.range.lowerBound), [0, 7, 13, 17])

        // A repeated verbatim link the translation mentions once: only the first is linked.
        let once = TranslationLinks.map("@bob が2回ガイドについて尋ねた", plan: plan, isPartial: false)
        XCTAssertEqual(pieces(once), ["0:@bob"])
    }

    func testVerbatimMatchesDoNotRunIntoLongerWords() throws {
        let plan = try XCTUnwrap(makePlan("Ask [[@bob]] about [[#12]]"))
        let mapped = TranslationLinks.map("@bobby ではなく @bob に #123 と #12 について聞いて", plan: plan, isPartial: false)
        XCTAssertEqual(pieces(mapped), ["0:@bob", "1:#12"])
        XCTAssertEqual(mapped.links.map(\.range.lowerBound), [12, 26])
    }

    func testBrokenMarkupFallsBackToPlainSearch() throws {
        let plan = try XCTUnwrap(makePlan("Thanks [[@alice]] for [[the pull request]] and [[the FAQ]] in [[README.md]]"))
        XCTAssertEqual(plan.input, "Thanks @alice for [the pull request](1) and [the FAQ](2) in README.md")
        let broken = [
            "@alice さん、[プルリクエスト](1)と[FAQ]の README.md をありがとう",  // missing number
            "@alice さん、[プルリクエスト](1)と[FAQ](2)の [README.md](3) をありがとう",  // extra
            "@alice さん、[プルリクエスト](1)と[FAQ](2)(2)の README.md をありがとう",  // number repeated
            "@alice さん、[プルリクエスト](1)と[FAQ](1)の README.md をありがとう",  // duplicated
            "@alice さん、[プルリクエスト](1)と[FAQ](3)の README.md をありがとう",  // unknown number
            "@alice さん、プルリクエスト](1)と[FAQ](2)の README.md をありがとう",  // lost "["
            "@alice さん、[プルリクエスト](1)とFAQの README.md をありがとう",  // missing marker
            "@alice さん、プルリクエストとFAQの README.md をありがとう",  // no markup at all
        ]
        for output in broken {
            let mapped = TranslationLinks.map(output, plan: plan, isPartial: false)
            assertNoMarkup(mapped.text)
            XCTAssertTrue(mapped.text.contains("プルリクエスト") && mapped.text.contains("FAQ"), mapped.text)
            XCTAssertEqual(pieces(mapped), ["0:@alice", "3:README.md"], output)
        }
        // An anchor the model kept as it was is still found as plain text.
        let kept = TranslationLinks.map("@alice さん、[プルリクエスト](1)と the FAQ の README.md", plan: plan, isPartial: false)
        XCTAssertEqual(pieces(kept), ["0:@alice", "2:the FAQ", "3:README.md"])
        XCTAssertEqual(kept.text, "@alice さん、プルリクエストと the FAQ の README.md")
    }

    func testFullWidthAndSpacedMarkersAreAccepted() throws {
        let plan = try XCTUnwrap(makePlan("Read [[the setup guide]] and [[our FAQ]]"))
        let mapped = TranslationLinks.map("［セットアップガイド］（１）と[ FAQ ] (2)を読んで", plan: plan, isPartial: false)
        XCTAssertEqual(mapped.text, "セットアップガイドと FAQ を読んで")
        XCTAssertEqual(pieces(mapped), ["0:セットアップガイド", "1:FAQ"])
    }

    func testBracketsOfTheSourceStay() throws {
        let plan = try XCTUnwrap(makePlan("[WIP] Read [[the setup guide]] first"))
        XCTAssertEqual(plan.input, "[WIP] Read [the setup guide](1) first")
        let mapped = TranslationLinks.map("[WIP] まず[セットアップガイド](1)を読んで", plan: plan, isPartial: false)
        XCTAssertEqual(mapped.text, "[WIP] まずセットアップガイドを読んで")
        XCTAssertEqual(pieces(mapped), ["0:セットアップガイド"])
    }

    func testPartialsNeverShowMarkup() throws {
        let plan = try XCTUnwrap(
            makePlan("Thanks [[@alice]] for reviewing [[the pull request]], see [[the setup guide]] and [[README.md]]."))
        let final = "[プルリクエスト](1)をレビューしてくれた @alice さん、ありがとう。[セットアップガイド](2)と README.md を見てね。"
        let complete = TranslationLinks.map(final, plan: plan, isPartial: false)
        XCTAssertEqual(complete.text, "プルリクエストをレビューしてくれた @alice さん、ありがとう。セットアップガイドと README.md を見てね。")
        XCTAssertEqual(pieces(complete), ["1:プルリクエスト", "0:@alice", "2:セットアップガイド", "3:README.md"])

        var previous = ""
        for length in 1...final.count {
            let partial = String(final.prefix(length))
            let mapped = TranslationLinks.map(partial, plan: plan, isPartial: true)
            assertNoMarkup(mapped.text)
            XCTAssertTrue(complete.text.hasPrefix(mapped.text), "\(partial) -> \(mapped.text)")
            XCTAssertGreaterThanOrEqual(mapped.text.count, previous.count - 1, "text does not jump back")
            for piece in pieces(mapped) {
                XCTAssertTrue(pieces(complete).contains(piece) || piece.hasPrefix("3:"), "\(piece) in \(partial)")
            }
            previous = mapped.text
        }

        // A marker that lost its "[" is hidden while it streams in, too.
        let lost = "プルリクエスト](1)をレビューしてくれた @alice さん、[セットアップガイド](2)も"
        for length in 1...lost.count {
            assertNoMarkup(TranslationLinks.map(String(lost.prefix(length)), plan: plan, isPartial: true).text)
        }
        XCTAssertEqual(
            TranslationLinks.map(lost, plan: plan, isPartial: false).text, "プルリクエストをレビューしてくれた @alice さん、セットアップガイドも")
    }

    func testMangledVerbatimLinksAreRepaired() throws {
        let plan = try XCTUnwrap(
            makePlan("Ping [[@alice]], open [[README.md]], see [[https://github.com/sizumita/plamonic/actions/runs/1234567890]]"))
        let mangled = "＠Alice に連絡し、README .md を開いて、https://github.com/sizumita/plamonic を見て"
        let mapped = TranslationLinks.map(mangled, plan: plan, isPartial: false)
        XCTAssertEqual(
            mapped.text,
            "@alice に連絡し、README.md を開いて、https://github.com/sizumita/plamonic/actions/runs/1234567890 を見て")
        XCTAssertEqual(
            pieces(mapped),
            ["0:@alice", "1:README.md", "2:https://github.com/sizumita/plamonic/actions/runs/1234567890"])

        // Not identified with confidence: left as it is, and the link is not linked.
        let unknown = "アリスに連絡し、説明書を開いて、https://example.org/other を見て"
        let untouched = TranslationLinks.map(unknown, plan: plan, isPartial: false)
        XCTAssertEqual(untouched.text, unknown)
        XCTAssertTrue(untouched.links.isEmpty)

        // A partial URL is still being written: it is not completed early.
        let partial = TranslationLinks.map("README.md と https://github.com/sizumita/pla", plan: plan, isPartial: true)
        XCTAssertEqual(partial.text, "README.md と https://github.com/sizumita/pla")
        XCTAssertEqual(pieces(partial), ["1:README.md"])
    }

    func testRepairKeepsLaterLinksInPlace() throws {
        let plan = try XCTUnwrap(makePlan("Ask [[@alice]] about [[the guide]] and [[#dev]]"))
        let mapped = TranslationLinks.map("＠ alice に[ガイド](1)と #dev について聞いて", plan: plan, isPartial: false)
        XCTAssertEqual(mapped.text, "@alice にガイドと #dev について聞いて")
        XCTAssertEqual(pieces(mapped), ["0:@alice", "1:ガイド", "2:#dev"])
    }

    func testMarkerNumbersSkipTheSourcesListNumbers() throws {
        // en → ja: the model writes the list number full-width.
        let english = try XCTUnwrap(makePlan("(1) Read [[the setup guide]] first."))
        XCTAssertEqual(english.input, "(1) Read [the setup guide](2) first.")
        let ja = TranslationLinks.map("（1）まず[セットアップガイド](2)を読んでください。", plan: english, isPartial: false)
        XCTAssertEqual(ja.text, "（1）まずセットアップガイドを読んでください。")
        XCTAssertEqual(pieces(ja), ["0:セットアップガイド"])

        // ja → en: half-width.
        let japanese = try XCTUnwrap(makePlan("手順（1）で[[設定画面]]を開く"))
        XCTAssertEqual(japanese.input, "手順（1）で[設定画面](2)を開く")
        let en = TranslationLinks.map("In step (1), open the [settings screen](2).", plan: japanese, isPartial: false)
        XCTAssertEqual(en.text, "In step (1), open the settings screen.")
        XCTAssertEqual(pieces(en), ["0:settings screen"])

        // Two links after "(2)", and a variation selector after the number.
        let step = try XCTUnwrap(makePlan("Step (2): see [[the guide]] and [[the FAQ]]"))
        XCTAssertEqual(step.input, "Step (2): see [the guide](3) and [the FAQ](4)")
        let steps = TranslationLinks.map("手順（2）\u{FE0F}：[ガイド](3)と[FAQ](4)を見て", plan: step, isPartial: false)
        XCTAssertEqual(steps.text, "手順（2）\u{FE0F}：ガイドとFAQを見て")
        XCTAssertEqual(pieces(steps), ["0:ガイド", "1:FAQ"])

        // Other list numbers a translation may write as "(n)".
        XCTAssertEqual(try XCTUnwrap(makePlan("1) Install 2) Read [[the guide]]")).input, "1) Install 2) Read [the guide](3)")
        XCTAssertEqual(try XCTUnwrap(makePlan("手順①で[[設定画面]]を開く")).input, "手順①で[設定画面](2)を開く")
        XCTAssertEqual(try XCTUnwrap(makePlan("Since (2026) see [[the guide]]")).input, "Since (2026) see [the guide](1)")
        // No three-digit numbers left: sent unmarked.
        let full = try XCTUnwrap(makePlan("(998) Read [[the guide]] and [[the FAQ]]"))
        XCTAssertEqual(full.input, full.plain)
        XCTAssertEqual(full.links.map(\.markupID), [nil, nil])
    }

    func testLeftoverMarkerNumbersGoAndTheSourcesStay() throws {
        let plan = try XCTUnwrap(makePlan("(1) Read [[the setup guide]] first."))
        // The marker lost its brackets: its number goes, the list number stays.
        let lost = TranslationLinks.map("（1）まずセットアップガイド（2）を読んでください。", plan: plan, isPartial: false)
        XCTAssertEqual(lost.text, "（1）まずセットアップガイドを読んでください。")
        XCTAssertTrue(lost.links.isEmpty)

        // Numbers that are also the source's (`plan` never makes these): kept as often as the source has them,
        // in either width.
        let colliding = TranslationLinks.Plan(
            plain: "(1) Read the setup guide first.", input: "(1) Read [the setup guide](1) first.",
            links: [.init(index: 0, text: "the setup guide", markupID: 1, isVerbatim: false, range: 9..<24)])
        let kept = TranslationLinks.map("（1）\u{FE0F}まず[セットアップガイド](1)を読んで", plan: colliding, isPartial: false)
        XCTAssertEqual(kept.text, "（1）\u{FE0F}まずセットアップガイドを読んで")
        XCTAssertEqual(pieces(kept), ["0:セットアップガイド"])
        let extra = TranslationLinks.map("（1）まずセットアップガイド(1)を読んで", plan: colliding, isPartial: false)
        XCTAssertEqual(extra.text, "（1）まずセットアップガイドを読んで")
        XCTAssertTrue(extra.links.isEmpty)
    }

    func testShortURLRepairLeavesTheSourcesOtherURLs() throws {
        // The output's URL is the source's other link: it is not rewritten into the missing one.
        let both = try XCTUnwrap(makePlan("Compare [[https://github.com/org/repo/pull/1]] with [[https://github.com/org]]"))
        let other = TranslationLinks.map("https://github.com/org と比較してください", plan: both, isPartial: false)
        XCTAssertEqual(other.text, "https://github.com/org と比較してください")
        XCTAssertEqual(pieces(other), ["1:https://github.com/org"])
        // A cut copy that is not the other URL is still repaired.
        let cut = TranslationLinks.map("https://github.com/org/repo を https://github.com/org と比較", plan: both, isPartial: false)
        XCTAssertEqual(cut.text, "https://github.com/org/repo/pull/1 を https://github.com/org と比較")
        XCTAssertEqual(pieces(cut), ["0:https://github.com/org/repo/pull/1", "1:https://github.com/org"])

        // The same for a URL that is plain text in the source, or one the copy could be cut from.
        let cases = [
            ("PR [[https://github.com/org/repo/pull/1]] (org: https://github.com/org)", "PR（組織: https://github.com/org）"),
            ("PR [[https://github.com/org/repo/pull/1]] (org: https://github.com/org/)", "PR（組織: https://github.com/org）"),
            ("PR [[https://github.com/org/repo/pull/1]] (org: https://github.com/Org)", "PR（組織: https://github.com/org）"),
        ]
        for (source, output) in cases {
            let plan = try XCTUnwrap(makePlan(source))
            let mapped = TranslationLinks.map(output, plan: plan, isPartial: false)
            XCTAssertEqual(mapped.text, output, source)
            XCTAssertTrue(mapped.links.isEmpty, source)
        }
    }

    // MARK: - Coordinator

    private func linkedSnapshot(_ marked: [String], kind: SegmentLinkKind = .link) -> WindowSnapshot {
        var snapshot = F.snapshot(marked.map { linked($0, kind: kind).text })
        for index in snapshot.segments.indices {
            snapshot.segments[index].links = linked(marked[index], kind: kind).links
        }
        return snapshot
    }

    /// Answers like a model that keeps the markers: "<model>: <input>".
    private static let echo: @Sendable (String, ModelSize) -> String = { text, model in "\(model.rawValue): \(text)" }

    @MainActor
    func testItemsWithLinksGetMarkupFreeTranslationsAndLinks() async throws {
        let backend = TranslationFakeBackend()
        backend.respond(with: Self.echo)
        let coordinator = F.coordinator(backend)
        let snapshot = linkedSnapshot(["Read [[the setup guide]] and ping [[@alice]] about [[README.md]]"])
        coordinator.process(snapshot: snapshot, settings: F.settings())
        let done = await F.waitUntil { coordinator.items(for: snapshot.key).first?.state == .final }
        XCTAssertTrue(done)

        XCTAssertEqual(
            backend.calls.map(\.request.text),
            Array(repeating: "Read [the setup guide](1) and ping @alice about README.md", count: 2))
        let item = try XCTUnwrap(coordinator.items(for: snapshot.key).first)
        XCTAssertEqual(item.translation, "2b: Read the setup guide and ping @alice about README.md")
        XCTAssertEqual(item.originalLinks, snapshot.segments[0].links)
        let units = Array(item.translation.utf16)
        XCTAssertEqual(
            item.links.map { String(decoding: units[$0.range], as: UTF16.self) }, ["the setup guide", "@alice", "README.md"])
        XCTAssertEqual(item.links.map(\.linkIndex), [0, 1, 2])
        XCTAssertTrue(OverlayLayout.isDrawable(item))
    }

    @MainActor
    func testTranslationEqualToTheOriginalIsNotDrawn() async throws {
        let backend = TranslationFakeBackend()
        backend.respond { text, _ in text }  // the model left it as it was, markers included
        let coordinator = F.coordinator(backend)
        let snapshot = linkedSnapshot(["Read  [[the setup guide]] now"])
        coordinator.process(snapshot: snapshot, settings: F.settings())
        _ = await F.waitUntil { coordinator.items(for: snapshot.key).first?.state == .final }
        let item = try XCTUnwrap(coordinator.items(for: snapshot.key).first)
        XCTAssertEqual(item.translation, "Read the setup guide now")
        XCTAssertFalse(OverlayLayout.isDrawable(item), "same as the original apart from spacing")
    }

    @MainActor
    func testLinksCutByTheLengthLimitStayInTheOriginal() async throws {
        let backend = TranslationFakeBackend()
        backend.respond(with: Self.echo)
        let coordinator = F.coordinator(backend)
        let settings = F.settings { $0.global.maxSegmentCharacters = 30 }
        let snapshot = linkedSnapshot(["See [[the guide]] first. Then read all of [[the long reference]] carefully."])
        coordinator.process(snapshot: snapshot, settings: settings)
        _ = await F.waitUntil { coordinator.items(for: snapshot.key).first?.state == .final }
        let item = try XCTUnwrap(coordinator.items(for: snapshot.key).first)
        XCTAssertEqual(backend.calls.last?.request.text, "See [the guide](1) first. Then")
        XCTAssertEqual(item.translation, "2b: See the guide first. Then")
        XCTAssertEqual(item.originalLinks.count, 2, "the overlay still guards the original link that was cut")
        XCTAssertEqual(item.links, [OverlayLink(range: 8..<17, linkIndex: 0)])
    }

    @MainActor
    func testItemsWithoutLinksAreUnchanged() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        let text = "Read [the docs](1) for details"
        let snapshot = F.snapshot([text])
        coordinator.process(snapshot: snapshot, settings: F.settings())
        _ = await F.waitUntil { coordinator.items(for: snapshot.key).first?.state == .final }
        let item = try XCTUnwrap(coordinator.items(for: snapshot.key).first)
        XCTAssertEqual(backend.calls.last?.request.text, text)
        XCTAssertEqual(item.translation, TranslationFakeBackend.output(for: text, model: .b2), "brackets of the output stay")
        XCTAssertTrue(item.links.isEmpty)
        XCTAssertTrue(item.originalLinks.isEmpty)
    }

    @MainActor
    func testVerbatimOnlyLinksShareThePlainTranslation() async throws {
        let backend = TranslationFakeBackend()
        let coordinator = F.coordinator(backend)
        let plain = F.snapshot(["The log is at https://example.com/log today"], window: 1)
        coordinator.process(snapshot: plain, settings: F.settings())
        _ = await F.waitUntil { coordinator.items(for: plain.key).first?.state == .final }
        let calls = backend.calls.count

        var linked = linkedSnapshot(["The log is at [[https://example.com/log]] today"], kind: .detected)
        linked.key = WindowKey(pid: 100, windowID: 2)
        let items = coordinator.process(snapshot: linked, settings: F.settings())
        XCTAssertEqual(items.first?.state, .final, "same cache entry as the text without links")
        XCTAssertEqual(backend.calls.count, calls)
        let item = try XCTUnwrap(items.first)
        let units = Array(item.translation.utf16)
        XCTAssertEqual(item.links.map { String(decoding: units[$0.range], as: UTF16.self) }, ["https://example.com/log"])
    }

    @MainActor
    func testStreamingPartialsNeverShowMarkup() async throws {
        let backend = TranslationFakeBackend()
        backend.respond { text, _ in
            text.replacingOccurrences(of: "Please read ", with: "まず")
                .replacingOccurrences(of: "[the setup guide](1)", with: "[セットアップガイド](1)を読んで、")
                .replacingOccurrences(of: "[the FAQ](2)", with: "[FAQ](2)も見てね")
        }
        backend.setStreaming(steps: 40, interval: 0.004)
        var configuration = F.configuration()
        configuration.partialUpdateInterval = 0.005
        let coordinator = TranslationCoordinator(
            backend: backend, cache: TranslationCache(capacity: 100, fileURL: nil), configuration: configuration,
            frontmostPID: { 100 })
        let snapshot = linkedSnapshot(["Please read [[the setup guide]] [[the FAQ]]"])
        var seen: [OverlayItem] = []
        coordinator.onItemsChanged = { key in
            if let item = coordinator.items(for: key).first, item.state == .streaming { seen.append(item) }
        }
        coordinator.process(snapshot: snapshot, settings: F.settings(draft: nil))
        let done = await F.waitUntil { coordinator.items(for: snapshot.key).first?.state == .final }
        XCTAssertTrue(done)
        XCTAssertGreaterThanOrEqual(seen.count, 3)
        for item in seen {
            assertNoMarkup(item.translation)
            for link in item.links {
                let anchor = String(decoding: Array(item.translation.utf16)[link.range], as: UTF16.self)
                XCTAssertTrue(["セットアップガイド", "FAQ"].contains(anchor), anchor)
            }
        }
        let item = try XCTUnwrap(coordinator.items(for: snapshot.key).first)
        XCTAssertEqual(item.translation, "まずセットアップガイドを読んで、 FAQも見てね")
        XCTAssertEqual(item.links.map(\.linkIndex), [0, 1])
    }

    @MainActor
    func testTranslationsWithLinksSurviveACacheRoundTrip() async throws {
        let url = F.temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let backend = TranslationFakeBackend()
        backend.respond(with: Self.echo)
        let cache = TranslationCache(capacity: 100, fileURL: url, persistenceEnabled: true, writeDelay: 0.01)
        let coordinator = F.coordinator(backend, cache: cache)
        var settings = F.settings()
        settings.global.persistCache = true
        let snapshot = linkedSnapshot(["See [[the setup guide]] and [[#dev]]", "No links in this sentence"])
        coordinator.process(snapshot: snapshot, settings: settings)
        _ = await F.waitUntil { coordinator.items(for: snapshot.key).allSatisfy { $0.state == .final } }
        cache.flush()

        let reloaded = TranslationCache(capacity: 100, fileURL: url, persistenceEnabled: true)
        reloaded.waitUntilLoaded()
        XCTAssertEqual(reloaded.count, 4)
        let other = TranslationCoordinator(
            backend: backend, cache: reloaded, configuration: F.configuration(), frontmostPID: { 100 })
        let calls = backend.calls.count
        let items = other.process(snapshot: snapshot, settings: settings)
        XCTAssertEqual(items.map(\.state), [.final, .final])
        XCTAssertEqual(backend.calls.count, calls)
        XCTAssertEqual(items[0].translation, "2b: See the setup guide and #dev")
        XCTAssertEqual(items[0].links.map(\.linkIndex), [0, 1])
        XCTAssertEqual(items[1].translation, "2b: No links in this sentence")
    }

    @MainActor
    func testHistoryIsSentWithoutMarkup() async throws {
        let backend = TranslationFakeBackend()
        backend.respond(with: Self.echo)
        let coordinator = F.coordinator(backend)
        let settings = F.settings(draft: nil) { $0.profile.useConversationHistory = true }
        let first = linkedSnapshot(["Read [[the setup guide]] first"])
        coordinator.process(snapshot: first, settings: settings)
        _ = await F.waitUntil { coordinator.items(for: first.key).first?.state == .final }

        let both = linkedSnapshot(["Read [[the setup guide]] first", "Then run the installer"])
        coordinator.process(snapshot: both, settings: settings)
        _ = await F.waitUntil { coordinator.items(for: both.key).allSatisfy { $0.state == .final } }
        let call = try XCTUnwrap(backend.calls(for: "Then run the installer").first)
        XCTAssertEqual(call.request.history.map(\.source), ["Read the setup guide first"])
        XCTAssertEqual(call.request.history.map(\.translation), ["2b: Read the setup guide first"])
    }
}
