import CoreGraphics
import XCTest

@testable import Plamonic

final class ExtractionMatcherTests: XCTestCase {
    private let message = ElementTraits(
        role: "AXGroup", subrole: "AXDocumentArticle", roleDescription: "message",
        domClasses: ["markup__75297", "messageContent_c19a55"], identifier: "chat-messages-123")

    func testEmptyAndBlankMatchersMatchNothing() {
        XCTAssertFalse(ElementMatcher().matches(message))
        XCTAssertFalse(ElementMatcher(domClassPrefixes: ["", "  "]).matches(message))
        XCTAssertFalse(ElementMatcher(domClassPrefixes: [""]).isUsable)
    }

    func testDOMClassPrefix() {
        XCTAssertTrue(ElementMatcher(domClassPrefixes: ["messageContent_"]).matches(message))
        XCTAssertFalse(ElementMatcher(domClassPrefixes: ["Content_"]).matches(message))
        XCTAssertTrue(ElementMatcher(domClassPrefixes: ["nope", "markup_"]).matches(message))
    }

    func testFieldsAreANDedValuesAreORed() {
        XCTAssertTrue(ElementMatcher(roles: ["AXGroup"], domClassPrefixes: ["markup_"]).matches(message))
        XCTAssertFalse(ElementMatcher(roles: ["AXLink"], domClassPrefixes: ["markup_"]).matches(message))
        XCTAssertTrue(ElementMatcher(roles: ["AXLink", "AXGroup"]).matches(message))
    }

    func testSubroleRoleDescriptionIdentifier() {
        XCTAssertTrue(ElementMatcher(subroles: ["AXDocumentArticle"]).matches(message))
        XCTAssertFalse(ElementMatcher(subroles: ["AXDocumentArticle"]).matches(ElementTraits(role: "AXGroup")))
        XCTAssertTrue(ElementMatcher(roleDescriptions: ["Message"]).matches(message))
        XCTAssertFalse(ElementMatcher(roleDescriptions: ["mess"]).matches(message))
        XCTAssertTrue(ElementMatcher(identifierPrefixes: ["chat-"]).matches(message))
        XCTAssertFalse(ElementMatcher(identifierPrefixes: ["x"]).matches(message))
    }

    func testRulesHelpers() {
        let rules = ExtractionRules(
            containers: [ElementMatcher(roles: [" "])], items: [ElementMatcher(roles: ["AXGroup"])],
            excludes: [ElementMatcher(roleDescriptions: ["message"])])
        XCTAssertFalse(rules.hasContainers)
        XCTAssertTrue(rules.hasItems)
        XCTAssertTrue(rules.usesRoleDescription)
        XCTAssertFalse(rules.usesIdentifier)
        XCTAssertTrue(CompiledMatcherSet(rules.items).matches(message))
        XCTAssertTrue(CompiledMatcherSet(rules.containers).isEmpty)
    }

    func testDescriptorTraits() {
        let d = ElementDescriptor(
            role: "AXGroup", subrole: nil, roleDescription: "group", domClasses: ["p-rich_text_section"],
            identifier: nil, axFrame: nil, textPreview: "")
        XCTAssertTrue(ElementMatcher(domClassPrefixes: ["p-rich_text_"]).matches(d.traits))
    }
}

final class ExtractionUnderMouseTests: XCTestCase {
    private func segment(_ text: String, y: CGFloat) -> RawSegment {
        RawSegment(
            text: text, frame: CGRect(x: 100, y: y, width: 300, height: 40), role: "AXGroup", isEditable: false,
            treeIndex: 0)
    }

    func testKeepsOnlyTheSegmentUnderThePointer() {
        let raw = [segment("a", y: 100), segment("b", y: 160), segment("c", y: 220)]
        XCTAssertEqual(TextExtractor.segments(near: CGPoint(x: 200, y: 170), in: raw).kept.map(\.text), ["b"])
        // In the gap between two paragraphs, a few points above the next one.
        XCTAssertEqual(TextExtractor.segments(near: CGPoint(x: 200, y: 214), in: raw).kept.map(\.text), ["c"])
        // Over a margin away from any text: nothing, not every paragraph of the block.
        XCTAssertEqual(TextExtractor.segments(near: CGPoint(x: 700, y: 170), in: raw).kept.map(\.text), [])
    }

    func testOtherParagraphsOfTheBlockStayVisible() {
        var lined = segment("c", y: 220)
        lined.lineFrames = [
            CGRect(x: 100, y: 220, width: 300, height: 20), CGRect(x: 100, y: 240, width: 120, height: 20),
        ]
        let raw = [segment("a", y: 100), segment("b", y: 160), lined]
        let near = TextExtractor.segments(near: CGPoint(x: 200, y: 170), in: raw)
        // The hovered paragraph's translation must not grow over the next one: its lines are obstacles.
        XCTAssertEqual(near.others, [raw[0].frame] + lined.lineFrames)
        XCTAssertEqual(TextExtractor.segments(near: CGPoint(x: 700, y: 170), in: raw).others.count, 4)
    }

    func testTranslationsStayInsideTheElementTheScopeRead() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let block = CGRect(x: 100, y: 150, width: 300, height: 60)
        // A list marker sticks out to the left of its item: the clip grows to take it in.
        let item = TextSegment(
            id: "p", text: "1. Item", axFrame: CGRect(x: 80, y: 155, width: 200, height: 20), role: "AXGroup",
            isEditable: false, order: 0)
        XCTAssertEqual(
            TextExtractor.elementClip(block, segments: [item], window: window),
            CGRect(x: 80, y: 150, width: 320, height: 60))
        XCTAssertEqual(TextExtractor.elementClip(block, segments: [], window: window), block)
        // Unknown or empty frame: only the segments.
        XCTAssertEqual(TextExtractor.elementClip(nil, segments: [item], window: window), item.axFrame)
        XCTAssertEqual(TextExtractor.elementClip(.zero, segments: [item], window: window), item.axFrame)
        XCTAssertNil(TextExtractor.elementClip(nil, segments: [], window: window))
        // Never outside the window.
        XCTAssertEqual(
            TextExtractor.elementClip(CGRect(x: 700, y: 500, width: 300, height: 300), segments: [], window: window),
            CGRect(x: 700, y: 500, width: 100, height: 100))
    }
}

final class ExtractionInlineJoinTests: XCTestCase {
    private func part(_ s: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> ExtractionWalk.Part {
        ExtractionWalk.Part(
            text: s, frame: CGRect(x: x, y: y, width: w, height: h), visible: true, role: "AXStaticText", treeIndex: 0)
    }

    func testJoin() {
        XCTAssertEqual(ExtractionWalk.join([part("Hello ", 0, 0, 40, 20), part("world", 40, 0, 40, 20)]), "Hello world")
        XCTAssertEqual(ExtractionWalk.join([part("foo", 0, 0, 30, 20), part("bar", 40, 0, 30, 20)]), "foo bar")
        XCTAssertEqual(ExtractionWalk.join([part("Title", 0, 0, 50, 18), part("Body", 0, 30, 40, 18)]), "Title\nBody")
        XCTAssertEqual(ExtractionWalk.join([part("字字", 0, 0, 20, 20), part("字", 20, 0, 10, 20)]), "字字字")
        XCTAssertEqual(
            ExtractionWalk.join([part("see ", 0, 0, 300, 40), part("link", 10, 20, 30, 20), part(" now", 40, 20, 30, 20)]),
            "see link now")
    }

    func testFrameTransformDetectsScaledWebArea() throws {
        let host = CGRect(x: 545, y: 93, width: 1470, height: 923)
        let web = CGRect(x: 545, y: 93, width: 735, height: 462)
        let t = try XCTUnwrap(FrameTransform.detect(webArea: web, host: host))
        XCTAssertEqual(t.scale, 2, accuracy: 0.01)
        let fixed = t.apply(CGRect(x: 812, y: 410, width: 148, height: 9))
        XCTAssertEqual(fixed.minX, 1079, accuracy: 1)
        XCTAssertEqual(fixed.minY, 727, accuracy: 1)
        XCTAssertEqual(fixed.width, 296, accuracy: 1)
        XCTAssertNil(FrameTransform.detect(webArea: host, host: host))
        XCTAssertNil(FrameTransform.detect(webArea: CGRect(x: 545, y: 150, width: 735, height: 462), host: host))
    }
}
