import XCTest

@testable import Plamonic

private typealias F = TranslationTestFixtures

/// Website profiles for the browser extensions (DESIGN §9.4).
final class SiteProfileTests: XCTestCase {
    private var written: (TranslationMode, URL)?
    private func url(_ string: String) -> URL { URL(string: string)! }

    func testPatternsMatchHostsDomainsAndPathPrefixes() {
        XCTAssertNotNil(SitePattern.specificity("www.youtube.com", url: url("https://www.youtube.com/watch?v=x")))
        XCTAssertNil(SitePattern.specificity("www.youtube.com", url: url("https://m.youtube.com/")))
        XCTAssertNotNil(SitePattern.specificity("*.wikipedia.org", url: url("https://ja.wikipedia.org/wiki/A")))
        XCTAssertNotNil(SitePattern.specificity("*.wikipedia.org", url: url("https://wikipedia.org/")))
        XCTAssertNil(SitePattern.specificity("*.wikipedia.org", url: url("https://notwikipedia.org/")))
        XCTAssertNotNil(SitePattern.specificity("github.com/apple", url: url("https://github.com/apple/swift")))
        XCTAssertNil(SitePattern.specificity("github.com/apple", url: url("https://github.com/google")))
        XCTAssertNotNil(SitePattern.specificity("HTTPS://Example.com", url: url("https://example.com/a")))
        XCTAssertNil(SitePattern.parse("exa mple.com"))
        XCTAssertNil(SitePattern.parse("*"))
        XCTAssertEqual(SitePattern.suggested(for: url("https://www.example.com/a")), "www.example.com")
    }

    func testTheMostSpecificProfileWinsAndUnknownSitesAreManual() {
        var document = SettingsDocument()
        var github = SiteProfile(pattern: "github.com", displayName: "GitHub (mine)")
        github.mode = .automatic
        var docs = SiteProfile(pattern: "github.com/apple", displayName: "Apple on GitHub")
        docs.mode = .off
        document.sites = [github, docs]
        let snapshot = SettingsSnapshot(document: document)

        XCTAssertEqual(snapshot.siteProfile(for: url("https://github.com/apple/swift")).profile.displayName, "Apple on GitHub")
        let other = snapshot.siteProfile(for: url("https://github.com/google/x"))
        XCTAssertEqual(other.profile.displayName, "GitHub (mine)")
        XCTAssertEqual(other.source, .user)
        // A preset the user has not edited.
        let wiki = snapshot.siteProfile(for: url("https://en.wikipedia.org/wiki/Swift"))
        XCTAssertEqual(wiki.source, .preset)
        XCTAssertFalse(wiki.profile.includeSelectors.isEmpty)
        // No settings: manual, for the whole page.
        let unknown = snapshot.siteProfile(for: url("https://www.example.com/post"))
        XCTAssertEqual(unknown.source, .defaults)
        XCTAssertEqual(unknown.profile.mode, .manual)
        XCTAssertEqual(unknown.profile.pattern, "www.example.com")
        XCTAssertTrue(unknown.profile.includeSelectors.isEmpty)
    }

    @MainActor
    func testEditingAPresetStoresACopyAndUndoingItGoesBack() throws {
        let store = SettingsStore(fileURL: F.temporaryFileURL("settings.json"))
        var youtube = try XCTUnwrap(SitePresets.preset(for: "www.youtube.com"))
        youtube.mode = .automatic
        store.upsertSite(youtube)
        XCTAssertEqual(store.snapshot.siteSource("www.youtube.com"), .user)
        youtube.mode = SitePresets.preset(for: "www.youtube.com")!.mode
        store.upsertSite(youtube)
        XCTAssertEqual(store.snapshot.siteSource("www.youtube.com"), .preset)
        XCTAssertTrue(store.snapshot.document.sites.isEmpty)

        var mine = SiteProfile(pattern: "example.com", displayName: "Example")
        mine.includeSelectors = ["article", "  "]
        store.upsertSite(mine)
        XCTAssertEqual(store.snapshot.userSite("example.com")?.includeSelectors, ["article"])
        mine.pattern = "*.example.com"
        store.upsertSite(mine, replacing: "example.com")
        XCTAssertNil(store.snapshot.userSite("example.com"))
        XCTAssertNotNil(store.snapshot.userSite("*.example.com"))
    }

    func testSitesSurviveARoundTripAndADamagedFile() throws {
        var document = SettingsDocument()
        var site = SiteProfile(pattern: "example.com", displayName: "Example")
        site.mode = .automatic
        site.excludeSelectors = ["nav"]
        document.sites = [site]
        let decoded = try JSONDecoder().decode(SettingsDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.sites, [site])
        XCTAssertEqual(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)).sites, [])

        let damaged = Data(#"{"sites":[{"pattern":"a.com","mode":"sometimes"},{"displayName":"no pattern"},{"pattern":"b.com"}]}"#.utf8)
        let salvaged = try XCTUnwrap(SettingsFileRecovery.salvage(damaged))
        XCTAssertEqual(salvaged.document.sites.map(\.pattern), ["a.com", "b.com"])
        XCTAssertEqual(salvaged.document.sites.first?.mode, .manual)
        XCTAssertTrue(salvaged.problems.contains("sites[0].mode"))
        XCTAssertTrue(salvaged.problems.contains("sites[1]"))
    }

    @MainActor
    func testTheMenuCanSetASitesModeInTheSettings() throws {
        let store = SettingsStore(fileURL: F.temporaryFileURL("settings.json"))
        let site = store.setSiteMode(.automatic, for: url("https://www.example.com/post/1"))
        XCTAssertEqual(site.pattern, "www.example.com")
        XCTAssertEqual(store.snapshot.userSite("www.example.com")?.mode, .automatic)
        // The new profile is the one the page (and the site's other pages) get from now on.
        XCTAssertEqual(store.snapshot.siteProfile(for: url("https://www.example.com/other")).profile.mode, .automatic)
        // A preset site keeps its places; only the mode changes.
        let reddit = store.setSiteMode(.automatic, for: url("https://www.reddit.com/r/swift"))
        XCTAssertEqual(reddit.pattern, "*.reddit.com")
        XCTAssertEqual(reddit.includeSelectors, SitePresets.preset(for: "*.reddit.com")?.includeSelectors)
        store.setSiteMode(.manual, for: url("https://www.reddit.com/r/swift"))
        XCTAssertEqual(store.snapshot.siteSource("*.reddit.com"), .preset)
    }

    // MARK: Bridge

    @MainActor
    private func service(_ backend: TranslationFakeBackend, sites: [SiteProfile]) -> BridgeService {
        var document = SettingsDocument()
        document.global = F.settings(draft: nil).global
        document.sites = sites
        let snapshot = SettingsSnapshot(document: document)
        return BridgeService(
            coordinator: F.coordinator(backend), settings: { snapshot }, isReady: { _ in true },
            setSiteMode: { mode, url in self.written = (mode, url) }, appVersion: "1")
    }

    @MainActor
    private func send(_ service: BridgeService, _ json: String) async throws -> [String: Any] {
        let data = await service.handle(line: Data(json.utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    func testTheBridgeAnswersSiteSettingsAndAppliesTheirOverrides() async throws {
        var site = SiteProfile(pattern: "example.com", displayName: "Example")
        site.mode = .automatic
        site.includeSelectors = ["article"]
        site.targetLanguageOverride = "ko"
        site.context = "Developer documentation"
        let backend = TranslationFakeBackend()
        let service = service(backend, sites: [site])

        // The page's target language is its site's.
        let hello = try await send(service, #"{"type":"hello","url":"https://example.com/docs/a"}"#)
        XCTAssertEqual(hello["targetLanguage"] as? String, "ko")
        let elsewhere = try await send(service, #"{"type":"hello","url":"https://other.org/"}"#)
        XCTAssertEqual(elsewhere["targetLanguage"] as? String, "ja")

        let answer = try await send(service, #"{"type":"site","url":"https://example.com/docs/a"}"#)
        let info = try XCTUnwrap(answer["site"] as? [String: Any])
        XCTAssertEqual(info["mode"] as? String, "automatic")
        XCTAssertEqual(info["include"] as? [String], ["article"])
        XCTAssertEqual(info["source"] as? String, "user")

        let list = try await send(service, #"{"type":"sites"}"#)
        let patterns = (list["sites"] as? [[String: Any]])?.compactMap { $0["pattern"] as? String }
        XCTAssertEqual(patterns, ["example.com"])

        _ = try await send(
            service,
            #"{"type":"translate","url":"https://example.com/docs/a","context":"Install guide","texts":["Hello there, everyone."]}"#)
        let request = try XCTUnwrap(backend.calls.first?.request)
        XCTAssertEqual(request.targetLanguage, "ko")
        XCTAssertEqual(request.context, "Developer documentation / Install guide")

        let set = try await send(service, #"{"type":"setSite","url":"https://news.example.org/a","mode":"automatic"}"#)
        XCTAssertEqual(set["ok"] as? Bool, true)
        XCTAssertEqual(written?.0, .automatic)
        XCTAssertEqual(written?.1.host(), "news.example.org")
        let bad = try await send(service, #"{"type":"setSite","url":"https://x.org","mode":"sometimes"}"#)
        XCTAssertEqual(bad["error"] as? String, "badRequest")
    }
}
