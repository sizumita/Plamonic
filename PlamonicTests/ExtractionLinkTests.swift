import ApplicationServices
import XCTest

@testable import Plamonic

/// Links inside segments (DESIGN §6.1 「リンクを取る」) and the paragraph look around them. Frames are synthetic,
/// shaped like what Chromium reports for the link fixture (15 px text, 18 pt runs, 22 pt line pitch).
final class ExtractionLinkTests: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// Distinct elements (CFEqual compares the pid of application elements).
    private func element(_ n: Int32) -> AXElement { AXElement(AXUIElementCreateApplication(1000 + n)) }

    private func part(
        _ text: String, _ frame: CGRect, element n: Int32, link: LinkMark? = nil, whole: Bool = true
    ) -> ExtractionWalk.Part {
        ExtractionWalk.Part(
            text: text, frame: frame, visible: true, role: "AXStaticText", treeIndex: Int(n), element: element(n),
            isWhole: whole, link: link)
    }

    private func walk(controls: Bool = false, granularity: SegmentGranularity = .paragraph) -> ExtractionWalk {
        var profile = AppProfile(bundleID: "com.example.chat", displayName: "Chat")
        profile.includeControls = controls
        profile.granularity = granularity
        return ExtractionWalk(
            settings: EffectiveSettings(profile: profile, global: GlobalSettings()), limits: ExtractionLimits(),
            ignore: nil, start: CFAbsoluteTimeGetCurrent())
    }

    private func color(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private func attributed(_ runs: [(String, [String: Any])]) -> NSAttributedString {
        let s = NSMutableAttributedString()
        for (text, attrs) in runs {
            var keyed: [NSAttributedString.Key: Any] = [:]
            for (k, v) in attrs { keyed[NSAttributedString.Key(k)] = v }
            s.append(NSAttributedString(string: text, attributes: keyed))
        }
        return s
    }

    // MARK: The paragraph's look (the reported bug: a sentence drawn in its link's color)

    func testParagraphStyleDoesNotComeFromALongLink() {
        // "The fix is in <a>https://github.com/…</a> ok." The link is the longest run.
        let link = LinkMark(element: element(50), kind: .link)
        let parts = [
            part("The fix is in ", rect(56, 604, 80, 18), element: 1),
            part("https://github.com/example-org/example-repository/pull/12345", rect(136, 604, 400, 18), element: 2, link: link),
            part(" ok.", rect(536, 604, 30, 18), element: 3),
        ]
        var s = RawSegment(text: "", frame: .zero, role: "AXGroup", isEditable: false, treeIndex: 0)
        ExtractionWalk.describeRuns(parts, into: &s)
        XCTAssertEqual(s.styleSource?.element, element(1), "the longest run outside the link decides the look")
    }

    func testReportedColorOfAParagraphIsNotItsLinksColor() throws {
        // What Chromium returns for the whole paragraph (measured on the fixture): the link is the longest run.
        let gray = color(0.85, 0.85, 0.86)
        let blue = color(0.1, 0.67, 0.85)
        let s = attributed([
            ("The fix is in ", ["AXFont": ["AXFontSize": 15], "AXForegroundColor": gray]),
            ("https://github.com/example-org/example-repository/pull/12345/files", ["AXFont": ["AXFontSize": 15], "AXForegroundColor": blue]),
            (" and it is ready.", ["AXFont": ["AXFontSize": 15], "AXForegroundColor": gray]),
        ])
        let runs = try XCTUnwrap(TextStyleReader.runs(of: s))
        // Without knowing the link, the link's color wins (the bug).
        XCTAssertEqual(runs.resolve().text?.textColor?.blue ?? 0, 0.85, accuracy: 0.01)
        let styles = runs.resolve(linkTexts: ["https://github.com/example-org/example-repository/pull/12345/files"])
        XCTAssertEqual(styles.text?.textColor?.red ?? 0, 0.85, accuracy: 0.01, "the text outside the link")
        XCTAssertEqual(styles.text?.fontSize, 15)
        XCTAssertEqual(styles.links.count, 1)
        XCTAssertEqual(styles.links[0]?.color?.blue ?? 0, 0.85, accuracy: 0.01)
        XCTAssertEqual(styles.links[0]?.isUnderlined, false)
    }

    func testLinkLooksAndUnderlineFromTheParagraphRuns() throws {
        let gray = color(0.85, 0.85, 0.86)
        let blue = color(0.1, 0.67, 0.85)
        let s = attributed([
            ("Compare ", ["AXFont": ["AXFontSize": 15], "AXForegroundColor": gray]),
            ("the old design", ["AXFont": ["AXFontSize": 15], "AXForegroundColor": blue, "AXUnderline": 1]),
            (" with ", ["AXFont": ["AXFontSize": 15], "AXForegroundColor": gray]),
            ("the new proposal", ["AXFont": ["AXFontSize": 15], "AXForegroundColor": blue]),
            (" today.", ["AXFont": ["AXFontSize": 15], "AXForegroundColor": gray]),
        ])
        let styles = try XCTUnwrap(TextStyleReader.runs(of: s)).resolve(linkTexts: ["the old design", "", "missing", "the new proposal"])
        XCTAssertEqual(styles.text?.textColor?.red ?? 0, 0.85, accuracy: 0.01)
        XCTAssertEqual(styles.links.count, 4)
        XCTAssertEqual(styles.links[0]?.isUnderlined, true)
        XCTAssertNil(styles.links[1], "not asked for")
        XCTAssertNil(styles.links[2], "not in the text")
        XCTAssertEqual(styles.links[3]?.isUnderlined, false)
        XCTAssertEqual(styles.links[3]?.color?.blue ?? 0, 0.85, accuracy: 0.01)
    }

    func testNativeLinkRunsAreLeftOutOfTheDominantRun() throws {
        // NSTextView marks link runs with AXLink.
        let s = attributed([
            ("See ", ["AXFont": ["AXFontSize": 13], "AXForegroundColor": color(0, 0, 0)]),
            ("the documentation for this feature", ["AXFont": ["AXFontSize": 13], "AXForegroundColor": color(0, 0, 1), "AXLink": "x"]),
            (" now.", ["AXFont": ["AXFontSize": 13], "AXForegroundColor": color(0, 0, 0)]),
        ])
        let style = try XCTUnwrap(TextStyleReader.parse(s))
        XCTAssertEqual(style.textColor?.blue ?? 1, 0, accuracy: 0.01)
        // They are not recorded as links, but the paragraph says it has some (for the overlay's colors).
        XCTAssertTrue(try XCTUnwrap(TextStyleReader.runs(of: s)).resolve().hasLinkRuns)
        let plain = attributed([("See the documentation.", ["AXFont": ["AXFontSize": 13], "AXForegroundColor": color(0, 0, 0)])])
        XCTAssertFalse(try XCTUnwrap(TextStyleReader.runs(of: plain)).resolve().hasLinkRuns)
        // The segment's style carries it to the overlay.
        let segments = ["See the documentation for this feature now.", "See the documentation."].enumerated().map {
            RawSegment(text: $1, frame: .zero, role: "AXTextArea", isEditable: false, treeIndex: $0)
        }
        let reported = [
            try XCTUnwrap(TextStyleReader.runs(of: s)).resolve(), try XCTUnwrap(TextStyleReader.runs(of: plain)).resolve(),
        ]
        var styles = TextExtractor.resolveStyles(segments, reported: reported.map(\.text))
        TextExtractor.markLinkRuns(&styles, reported: reported)
        XCTAssertEqual(styles.map(\.style.hasLinkRuns), [true, false])
        XCTAssertEqual(styles[0].style.textColor?.blue ?? 1, 0, accuracy: 0.01, "still the text's own color")
    }

    // MARK: Link looks when the link's words also come elsewhere

    /// Gray text with one blue underlined link run at `link` (UTF-16 range of `text`).
    private func paragraph(_ text: String, link: Range<Int>) -> StyleRuns? {
        let gray: [String: Any] = ["AXFont": ["AXFontSize": 15], "AXForegroundColor": color(0.85, 0.85, 0.86)]
        let blue: [String: Any] = [
            "AXFont": ["AXFontSize": 15], "AXForegroundColor": color(0.1, 0.4, 0.95), "AXUnderline": 1,
        ]
        let ns = text as NSString
        func piece(_ lo: Int, _ hi: Int) -> String { ns.substring(with: NSRange(location: lo, length: hi - lo)) }
        var runs: [(String, [String: Any])] = []
        if link.lowerBound > 0 { runs.append((piece(0, link.lowerBound), gray)) }
        runs.append((piece(link.lowerBound, link.upperBound), blue))
        if link.upperBound < ns.length { runs.append((piece(link.upperBound, ns.length), gray)) }
        return TextStyleReader.runs(of: attributed(runs))
    }

    /// The UTF-16 range of the `n`th (from 0) occurrence of `word` in `text`.
    private func occurrence(_ word: String, in text: String, _ n: Int) -> Range<Int> {
        let ns = text as NSString
        var from = 0
        var r = NSRange(location: NSNotFound, length: 0)
        for _ in 0...n {
            r = ns.range(of: word, range: NSRange(location: from, length: ns.length - from))
            from = r.location + r.length
        }
        return r.location..<(r.location + r.length)
    }

    func testLinkLookIsReadWhereTheLinkIs() throws {
        // The link's words come earlier as plain text, or inside another word.
        let cases: [(text: String, word: String, nth: Int)] = [
            ("Where is it? Click here for the details.", "here", 1),
            ("The docs are out. Read the docs.", "docs", 1),
            ("詳細はこちら：こちら", "こちら", 1),
            ("Updated the design doc, see design doc", "design doc", 1),
            ("Release notes for v2.0 → Release notes for v2.0", "Release notes for v2.0", 1),
        ]
        for c in cases {
            let link = occurrence(c.word, in: c.text, c.nth)
            let runs = try XCTUnwrap(paragraph(c.text, link: link))
            let styles = runs.resolve(links: [LinkStyleProbe(text: c.word, offset: link.lowerBound)])
            XCTAssertEqual(styles.links.first??.color?.blue ?? 0, 0.95, accuracy: 0.01, c.text)
            XCTAssertEqual(styles.links.first??.isUnderlined, true, c.text)
            XCTAssertEqual(styles.text?.textColor?.blue ?? 0, 0.86, accuracy: 0.01, "the text outside the link: \(c.text)")
        }
    }

    func testLinkLookFoundNearWhereTheWalkPutIt() throws {
        // The app's text differs a little from the walk's (an image left out before the link): the nearest match.
        let app = "Hi \u{FFFC} the docs are old; see the new docs here"
        let link = occurrence("docs", in: app, 1)
        let runs = try XCTUnwrap(paragraph(app, link: link))
        let walkOffset = link.lowerBound - 2
        let styles = runs.resolve(links: [
            LinkStyleProbe(text: "docs", offset: walkOffset), LinkStyleProbe(text: "here", offset: walkOffset + 5),
        ])
        XCTAssertEqual(styles.links[0]?.isUnderlined, true)
        // The second link's offset moves with the first one's: found at its place right after it.
        XCTAssertEqual(StyleRuns.locate([
            LinkStyleProbe(text: "docs", offset: walkOffset), LinkStyleProbe(text: "here", offset: walkOffset + 5),
        ], in: app as NSString).map { $0?.location }, [link.lowerBound, link.lowerBound + 5])
        // Without a place, a whole word is taken before a piece of a longer one.
        XCTAssertEqual(
            StyleRuns.locate([LinkStyleProbe(text: "here", offset: nil)], in: "Where is it? Click here." as NSString)
                .map { $0?.location }, [19])
    }

    func testBlockParagraphLinksKnowWhereTheyAre() throws {
        // "The docs are old; see the new <a>docs</a>.": read as a whole block, the link is looked up at its place.
        let w = walk()
        let docs = LinkMark(element: element(64), kind: .link)
        let parts = [
            part("The docs are old; see the new ", rect(56, 324, 200, 18), element: 1),
            part("docs", rect(256, 324, 30, 18), element: 2, link: docs),
            part(".", rect(286, 324, 4, 18), element: 3),
        ]
        w.emitParagraph(parts, role: "AXGroup", index: 7, block: element(70))
        let s = try XCTUnwrap(w.segments.first)
        XCTAssertEqual(s.links.map(\.styleOffset), [30])
        let runs = try XCTUnwrap(paragraph(s.text, link: s.links[0].range))
        let styles = runs.resolve(links: s.links.map(\.styleProbe))
        XCTAssertEqual(styles.links.first??.isUnderlined, true)
        XCTAssertEqual(styles.text?.textColor?.blue ?? 0, 0.86, accuracy: 0.01)
    }

    // MARK: Links of a paragraph

    func testSeveralLinksInOneParagraph() throws {
        let w = walk()
        let old = LinkMark(element: element(60), kind: .link)
        let new = LinkMark(element: element(61), kind: .link)
        let parts = [
            part("Compare ", rect(56, 324, 67, 18), element: 1),
            part("the old design", rect(122, 324, 96, 18), element: 2, link: old),
            part(" with ", rect(217, 324, 37, 18), element: 3),
            part("the new proposal", rect(253, 324, 117, 18), element: 4, link: new),
            part(" and tell me which one you prefer.", rect(56, 324, 493, 40), element: 5),
        ]
        w.emitParagraph(parts, role: "AXGroup", index: 7, block: element(70))
        let s = try XCTUnwrap(w.segments.first)
        XCTAssertEqual(s.text, "Compare the old design with the new proposal and tell me which one you prefer.")
        XCTAssertEqual(s.links.map { LinkText.substring(s.text, $0.range) }, ["the old design", "the new proposal"])
        XCTAssertEqual(s.links.map(\.range), [8..<22, 28..<44])
        XCTAssertEqual(s.links.map(\.kind), [.link, .link])
        XCTAssertEqual(s.links.map(\.element), [element(60), element(61)])
        // The whole paragraph is read at once: its text's look and both links' looks.
        XCTAssertEqual(s.styleSource?.element, element(70))
        XCTAssertEqual(s.links.map(\.styleText), ["the old design", "the new proposal"])
        XCTAssertEqual(s.links[0].runs.map(\.frame), [rect(122, 324, 96, 18)])

        let links = TextExtractor.finishLinks(
            s, text: s.text, style: TextStyleHint(fontSize: 15, lineHeight: 22),
            reported: [ReportedLinkStyle(color: RGBAColor(red: 0, green: 0, blue: 1), isUnderlined: true), nil],
            urls: [URL(string: "https://example.com/design/old"), nil])
        XCTAssertEqual(links.map(\.text), ["the old design", "the new proposal"])
        XCTAssertEqual(links[0].frames, [rect(122, 324, 96, 18)])
        XCTAssertEqual(links[0].url?.absoluteString, "https://example.com/design/old")
        XCTAssertEqual(links[0].isUnderlined, true)
        XCTAssertEqual(links[0].color?.blue, 1)
        XCTAssertNil(links[1].color)
        XCTAssertNil(links[1].url)
    }

    func testNestedLinkIsOneLink() throws {
        // <a>the <strong>team wiki</strong> page</a>: three runs of one link.
        let w = walk()
        let wiki = LinkMark(element: element(80), kind: .link)
        let parts = [
            part("The schedule is on ", rect(56, 965, 131, 18), element: 1),
            part("the ", rect(186, 965, 26, 18), element: 2, link: wiki),
            part("team wiki", rect(211, 965, 70, 18), element: 3, link: wiki),
            part(" page", rect(280, 965, 38, 18), element: 4, link: wiki),
            part(" for everyone to see.", rect(318, 965, 137, 18), element: 5),
        ]
        w.emitParagraph(parts, role: "AXGroup", index: 3)
        let s = try XCTUnwrap(w.segments.first)
        XCTAssertEqual(s.links.count, 1)
        XCTAssertEqual(LinkText.substring(s.text, s.links[0].range), "the team wiki page")
        // No element holds exactly this paragraph: the longest run outside the link is read, and no link look.
        XCTAssertEqual(s.styleSource?.element, element(5))
        XCTAssertNil(s.links[0].styleText)
        let links = TextExtractor.finishLinks(s, text: s.text, style: TextStyleHint(fontSize: 15), reported: [], urls: [])
        XCTAssertEqual(links[0].frames, [rect(186, 965, 132, 18)], "one rectangle for the line")
    }

    func testLinkStyledButtonIsALink() throws {
        // Claude's file reference: a leaf AXButton drawn as a link inside the sentence.
        let w = walk()
        var info = AXNodeInfo(element: element(90))
        info.role = "AXButton"
        info.title = "TranslationCoordinator.swift"
        info.frame = rect(124, 705, 187, 22)
        info.domClasses = ["inline", "prose-link"]
        let state = ExtractionWalk.VisitState(
            depth: 1, clip: rect(0, 0, 800, 1000), inItem: true, itemsOnly: false, transform: nil, parentFrame: nil)
        guard case .block(let run, true, false) = w.visitContent(info, index: 2, state) else { return XCTFail() }
        XCTAssertEqual(run.parts.first?.link, LinkMark(element: element(90), kind: .button))

        let parts = [part("I updated ", rect(56, 707, 69, 18), element: 1)] + run.parts + [
            part(" so that drafts are cancelled correctly.", rect(56, 707, 441, 40), element: 3)
        ]
        w.emitParagraph(parts, role: "AXGroup", index: 1)
        let s = try XCTUnwrap(w.segments.first)
        XCTAssertEqual(s.links.map(\.kind), [.button])
        XCTAssertEqual(LinkText.substring(s.text, s.links[0].range), "TranslationCoordinator.swift")
        // Its obstacle lies inside the segment and is dropped.
        let segment = TextSegment(
            id: "s", text: s.text, axFrame: s.frame, role: "AXGroup", isEditable: false, order: 0)
        XCTAssertEqual(TextExtractor.keptObstacles(w.obstacles, segments: [segment]), [])
    }

    func testMentionButtonJoinsTheLineAsALink() throws {
        // Discord: a mention drawn as a button around its text, between two runs of the sentence.
        let w = walk()
        var button = AXNodeInfo(element: element(91))
        button.role = "AXButton"
        button.domClasses = ["mention", "wrapper_f61b3a"]
        let mention = part("@oscar", rect(109, 906, 54, 18), element: 2)
        let piece = w.combine(
            button, index: 5, pieces: [.inline(ExtractionWalk.Run(parts: [mention], role: "AXStaticText", treeIndex: 6))],
            isInline: false, isControl: true)
        guard case .block(let run, true, false) = piece else { return XCTFail("\(piece)") }
        XCTAssertEqual(run.parts.map(\.link), [LinkMark(element: element(91), kind: .button)])

        var group = AXNodeInfo(element: element(92))
        group.role = "AXGroup"
        let thanks = part("Thanks ", rect(56, 906, 53, 18), element: 1)
        let rest = part(" for reviewing the change so quickly.", rect(162, 906, 244, 18), element: 3)
        let line = w.combine(
            group, index: 4,
            pieces: [
                .inline(ExtractionWalk.Run(parts: [thanks], role: "AXStaticText", treeIndex: 1)), piece,
                .inline(ExtractionWalk.Run(parts: [rest], role: "AXStaticText", treeIndex: 3)),
            ], isInline: false, isControl: false)
        w.flush(line)
        let s = try XCTUnwrap(w.segments.first)
        XCTAssertEqual(s.text, "Thanks @oscar for reviewing the change so quickly.")
        XCTAssertEqual(s.links.map(\.kind), [.button])
        XCTAssertEqual(LinkText.substring(s.text, s.links[0].range), "@oscar")
        XCTAssertEqual(s.styleSource?.element, element(92), "the group holds exactly this paragraph")
    }

    func testMessageThatIsOnlyALink() throws {
        let w = walk()
        let handbook = LinkMark(element: element(95), kind: .link)
        w.emitParagraph(
            [part("Team handbook for new members", rect(56, 847, 229, 18), element: 2, link: handbook)], role: "AXLink",
            index: 9)
        let s = try XCTUnwrap(w.segments.first)
        XCTAssertEqual(s.links.map(\.range), [0..<29])
        // The link's own run is read: its size is the paragraph's, its color the link's.
        XCTAssertEqual(s.styleSource?.element, element(2))
        XCTAssertEqual(s.links[0].styleText, "Team handbook for new members")
        XCTAssertTrue(TextExtractor.isOnlyLinks(s.text, s.links))

        let blue = color(0.1, 0.67, 0.85)
        let read = attributed([("Team handbook for new members", ["AXFont": ["AXFontSize": 15], "AXForegroundColor": blue])])
        let styles = try XCTUnwrap(TextStyleReader.runs(of: read)).resolve(linkTexts: ["Team handbook for new members"])
        XCTAssertEqual(styles.text?.fontSize, 15)
        XCTAssertNil(styles.text?.textColor, "the link's color is not the paragraph's")
        XCTAssertEqual(styles.links[0]?.color?.blue ?? 0, 0.85, accuracy: 0.01)

        // The paragraph takes the text color of a neighbour of the same size, when there is one.
        let gray = RGBAColor(red: 0.85, green: 0.85, blue: 0.86)
        var hints: [(style: TextStyleHint, lineFrames: [CGRect])] = [
            (TextStyleHint(fontSize: 15, textColor: gray), []), (TextStyleHint(fontSize: 15), []),
            (TextStyleHint(fontSize: 12), []),
        ]
        TextExtractor.borrowTextColors(&hints, linkOnly: [false, true, true])
        XCTAssertEqual(hints[1].style.textColor, gray)
        XCTAssertNil(hints[2].style.textColor, "no neighbour of that size")
    }

    // MARK: Geometry

    func testWrappedLinkGetsOneRectanglePerLine() {
        // "… gone through <a>the complete checklist … hotfixes</a> carefully.": the link's run is the bounding box
        // of two lines; the runs around it tell where it starts and ends.
        let run = LinkRun(frame: rect(56, 405, 495, 40), before: rect(56, 405, 344, 18), after: rect(290, 427, 64, 18))
        let frames = ExtractionWalk.linkFrames([run], textHeight: 18, singleLineLimit: 25.5, pitch: 22)
        XCTAssertEqual(frames, [rect(400, 405, 151, 18), rect(56, 427, 234, 18)])
        // Three lines: the middle one is the link's whole width.
        let three = LinkRun(frame: rect(56, 405, 495, 62), before: rect(56, 405, 344, 18), after: nil)
        XCTAssertEqual(
            ExtractionWalk.linkFrames([three], textHeight: 18, singleLineLimit: 25.5, pitch: 22),
            [rect(400, 405, 151, 18), rect(56, 427, 495, 18), rect(56, 449, 495, 18)])
        // Unknown line height: the run as it is.
        XCTAssertEqual(ExtractionWalk.linkFrames([run], textHeight: nil, singleLineLimit: nil, pitch: nil), [run.frame])
    }

    // MARK: Text changes

    func testNormalizationMovesLinkRanges() {
        let raw = "  Read\u{200B}  the   setup guide \n\n\n\nnow  "
        let mapped = TextFilters.normalizeMapped(raw)
        XCTAssertEqual(mapped.text, TextFilters.normalize(raw))
        XCTAssertEqual(mapped.text, "Read the setup guide\n\nnow")
        let ns = raw as NSString
        let guide = ns.range(of: "setup guide ")
        let link = RawLink(range: guide.location..<(guide.location + guide.length), kind: .link, element: nil)
        let moved = LinkText.remap([link], with: mapped.map, in: mapped.text)
        XCTAssertEqual(moved.map { LinkText.substring(mapped.text, $0.range) }, ["setup guide"])
        // A link of spaces only is dropped.
        let spaces = RawLink(range: 0..<2, kind: .link, element: nil)
        XCTAssertEqual(LinkText.remap([spaces], with: mapped.map, in: mapped.text), [])
        // The same text as normalize for every shape it handles.
        for sample in ["a\r\nb", "x\u{00A0}\u{00A0}y", "\n\nfirst\n\n\nsecond\n", "emoji 👍🏽  ok", "", "   ", "字\t字"] {
            XCTAssertEqual(TextFilters.normalizeMapped(sample).text, TextFilters.normalize(sample), sample)
        }
    }

    func testMergedSplitParagraphKeepsItsLinks() {
        // A paragraph split in two by the walk (DESIGN §6 「重ならない」): the second half's link moves along.
        func raw(_ text: String, _ frame: CGRect, emit: Int, link: Range<Int>?) -> (segment: RawSegment, text: String) {
            var s = RawSegment(text: text, frame: frame, role: "AXGroup", isEditable: false, treeIndex: emit)
            s.blockIndex = 7
            s.emitIndex = emit
            s.runFrames = [frame]
            s.runIsWhole = [true]
            s.styleSource = StyleSource(element: element(Int32(emit)), location: nil, length: text.utf16.count)
            if let link { s.links = [RawLink(range: link, kind: .link, element: element(40 + Int32(emit)), styleText: "x")] }
            return (s, text)
        }
        let first = raw("See the guide", rect(120, 351, 140, 26), emit: 3, link: 4..<13)
        let second = raw("and the checklist before merging today.", rect(140, 356, 656, 68), emit: 4, link: 8..<17)
        let merged = SegmentMerger.merge(
            [first, second].sorted { TextExtractor.readingOrder($0.segment, $1.segment) }, maxCharacters: 2000)
        XCTAssertEqual(merged.items.count, 1)
        let (segment, text) = merged.items[0]
        XCTAssertEqual(text, "See the guide and the checklist before merging today.")
        XCTAssertEqual(segment.text, text)
        XCTAssertEqual(segment.links.map { LinkText.substring(text, $0.range) }, ["the guide", "checklist"])
        // The longer piece's style source is kept: only its link can be looked up in it.
        XCTAssertEqual(segment.links.map { $0.styleText != nil }, [false, true])
    }

    func testItemJoinKeepsEachParagraphsLinks() throws {
        var a = RawSegment(text: "Hello @frank", frame: rect(0, 0, 100, 18), role: "AXGroup", isEditable: false, treeIndex: 1)
        a.links = [RawLink(range: 6..<12, kind: .link, element: element(1), styleText: "@frank")]
        var b = RawSegment(
            text: "Please read the setup guide first.", frame: rect(0, 22, 300, 18), role: "AXGroup", isEditable: false,
            treeIndex: 2)
        b.links = [RawLink(range: 16..<27, kind: .link, element: element(2), styleText: "setup guide")]
        b.styleSource = StyleSource(element: element(3), location: nil, length: 34)
        let item = try XCTUnwrap(ExtractionWalk.itemSegment([a, b], role: "AXGroup", index: 0))
        XCTAssertEqual(item.links.map { LinkText.substring(item.text, $0.range) }, ["@frank", "setup guide"])
        XCTAssertEqual(item.links.map(\.styleText), [nil, "setup guide"], "only the longest paragraph is read")
    }

    // MARK: Terminals

    func testTerminalURLsAreDetected() throws {
        let screen = [
            "⏺ The deploy notes are at https://example.com/deploy/notes?id=42 and the",
            "  old ones at www.example.org/old. Mail me at someone@example.com or see",
            "  example.com for more.",
        ].joined(separator: "\n")
        let lines = TerminalSegmenter.lines(fromScreen: screen)
        let p = try XCTUnwrap(TerminalSegmenter.segment(lines).first)
        let byRow = Dictionary(uniqueKeysWithValues: lines.map { ($0.row, $0) })
        let links = TerminalSegmenter.detectLinks(in: p, lines: byRow)
        XCTAssertEqual(links.map { LinkText.substring(p.text, $0.range) }, ["https://example.com/deploy/notes?id=42", "www.example.org/old"])
        XCTAssertEqual(links[0].url.absoluteString, "https://example.com/deploy/notes?id=42")
        XCTAssertEqual(links[1].url.scheme, "http")
        // Cells: after "⏺ The deploy notes are at " on the first row.
        XCTAssertEqual(links[0].cells.map(\.row), [0])
        XCTAssertEqual(links[0].cells.first?.startCol, 26)
        XCTAssertEqual(links[0].cells.first?.endCol, 64)
    }

    func testURLCutAtTheWrapWidthStaysOneURL() throws {
        // A TUI that wraps its own output at 40 columns cuts a long URL in the middle.
        let screen = [
            "⏺ The fix is in https://github.com/exam",
            "  ple-org/example-repository/pull/12345",
            "  and it is ready for review today, ok.",
        ].joined(separator: "\n")
        let lines = TerminalSegmenter.lines(fromScreen: screen)
        let p = try XCTUnwrap(TerminalSegmenter.segment(lines).first)
        XCTAssertEqual(
            p.text, "The fix is in https://github.com/example-org/example-repository/pull/12345 and it is ready for review today, ok.")
        let byRow = Dictionary(uniqueKeysWithValues: lines.map { ($0.row, $0) })
        let link = try XCTUnwrap(TerminalSegmenter.detectLinks(in: p, lines: byRow).first)
        XCTAssertEqual(link.url.absoluteString, "https://github.com/example-org/example-repository/pull/12345")
        XCTAssertEqual(link.cells.map(\.row), [0, 1])
        XCTAssertEqual(link.cells.map(\.startCol), [16, 2])
        XCTAssertEqual(link.cells.map(\.endCol), [39, 39])

        // On a 9 x 17 cell grid: one rectangle per row.
        let grid = TerminalSegmenter.Grid(
            cell: CGSize(width: 9, height: 17), left: 100, anchorTop: 200, anchorRow: 0, wrapColumns: nil, lines: lines)
        let raw = try XCTUnwrap(ExtractionWalk.terminalLinks(p, lines: byRow, grid: grid) { $0 }.first)
        XCTAssertEqual(raw.kind, .detected)
        XCTAssertNil(raw.element)
        XCTAssertEqual(raw.frames, [rect(244, 200, 207, 17), rect(118, 217, 333, 17)])
        XCTAssertEqual(raw.styleText, "https://github.com/exam", "the part in the first row, which the style read covers")

        // The URL ends at the wrap width on the second row: the word after it is not glued to it ("… and it").
        XCTAssertFalse(TerminalSegmenter.continuesURL("https://e.com/pull/1", previousRight: 40, wrapRight: 40, next: "and it is"))
        XCTAssertTrue(TerminalSegmenter.continuesURL("see https://e.com/pu", previousRight: 40, wrapRight: 40, next: "ll/12 ok"))
        XCTAssertTrue(TerminalSegmenter.continuesURL("see https://e.com/pu", previousRight: 40, wrapRight: 40, next: "llrequests"))
        // A row that was not full, or text that is no URL.
        XCTAssertFalse(TerminalSegmenter.continuesURL("x https://e.com/a", previousRight: 30, wrapRight: 40, next: "b/c"))
        XCTAssertFalse(TerminalSegmenter.continuesURL("see the docs at", previousRight: 40, wrapRight: 40, next: "a/b"))
    }

    func testWordAfterAURLAtTheWrapWidthIsNotGluedToIt() throws {
        // The URL ends at the wrap width (the pane's longest row) and the next row starts a sentence word with
        // punctuation after it: the space stays, and the URL is only the URL.
        let cases: [(rows: [String], text: String, url: String)] = [
            (
                ["⏺ Read the setup notes at https://e.com/docs", "  today. Then run the installer and the", "  checks again."],
                "Read the setup notes at https://e.com/docs today. Then run the installer and the checks again.",
                "https://e.com/docs"
            ),
            (
                ["⏺ The release notes are at https://e.com/v2", "  below: three flags changed in this one", "  release."],
                "The release notes are at https://e.com/v2 below: three flags changed in this one release.",
                "https://e.com/v2"
            ),
            (
                ["⏺ The new manual is at https://e.com/manual", "  (v2.0) and it was released last week for", "  everyone."],
                "The new manual is at https://e.com/manual (v2.0) and it was released last week for everyone.",
                "https://e.com/manual"
            ),
        ]
        for c in cases {
            let lines = TerminalSegmenter.lines(fromScreen: c.rows.joined(separator: "\n"))
            let p = try XCTUnwrap(TerminalSegmenter.segment(lines).first)
            XCTAssertEqual(p.text, c.text)
            let byRow = Dictionary(uniqueKeysWithValues: lines.map { ($0.row, $0) })
            XCTAssertEqual(TerminalSegmenter.detectLinks(in: p, lines: byRow).map(\.url.absoluteString), [c.url])
        }
        for next in ["today. Then run", "below: three flags", "(v2.0) and released.", "first.", "v2.0 is out", "\"quoted\" text"] {
            XCTAssertFalse(TerminalSegmenter.continuesURL("see https://e.com/docs", previousRight: 40, wrapRight: 40, next: next), next)
        }
        // The rest of a cut URL, also when a sentence ends right after it.
        for next in ["ll/12.", "ll/12) and more", "ll?id=4, then", "llrequests"] {
            XCTAssertTrue(TerminalSegmenter.continuesURL("see https://e.com/pu", previousRight: 40, wrapRight: 40, next: next), next)
        }
        XCTAssertFalse(TerminalSegmenter.continuesURL("see https://e.com/pu", previousRight: 40, wrapRight: 40, next: "today."))
    }

    func testSoftWrappedURLInOneLogicalLine() throws {
        // The terminal itself wraps a long line onto two rows (AX reports one line): the grid splits the cells.
        let text = "see https://example.com/a/very/long/path ok"
        let lines = TerminalSegmenter.lines(fromScreen: text)
        let p = try XCTUnwrap(TerminalSegmenter.segment(lines, columns: 20).first)
        let byRow = Dictionary(uniqueKeysWithValues: lines.map { ($0.row, $0) })
        let grid = TerminalSegmenter.Grid(
            cell: CGSize(width: 10, height: 20), left: 0, anchorTop: 0, anchorRow: 0, wrapColumns: 20, lines: lines)
        let raw = try XCTUnwrap(ExtractionWalk.terminalLinks(p, lines: byRow, grid: grid) { $0 }.first)
        XCTAssertEqual(LinkText.substring(p.text, raw.range), "https://example.com/a/very/long/path")
        XCTAssertEqual(raw.frames, [rect(40, 0, 160, 20), rect(0, 20, 200, 20)])
    }
}
