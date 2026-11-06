import XCTest

@testable import Plamonic

/// The build's version and key from Info.plist, the feed choice and ベータ版を受け取る in settings.json.
@MainActor
final class UpdateChannelTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("settings.json") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateChannelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func load(_ json: String) throws -> SettingsStore {
        try Data(json.utf8).write(to: fileURL)
        return SettingsStore(fileURL: fileURL, saveDelay: 10)
    }

    private let release = BuildInfo(version: "0.2.0", build: "41", sparklePublicKey: "key")
    private let beta = BuildInfo(version: "0.2.1-beta.3", build: "44", sparklePublicKey: "key")

    // MARK: - BuildInfo

    func testReadsTheInfoDictionary() {
        let info = BuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.2.1-beta.3", "CFBundleVersion": "44",
            "SUPublicEDKey": " pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ= \n",
        ])
        XCTAssertEqual(info.version, "0.2.1-beta.3")
        XCTAssertEqual(info.build, "44")
        XCTAssertEqual(info.sparklePublicKey, "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ=", "trimmed")
        XCTAssertTrue(info.updatesItself)
        XCTAssertTrue(info.isBeta)
        XCTAssertEqual(info.displayVersion, "0.2.1-beta.3（ビルド 44）")
    }

    func testABuildWithoutAKeyDoesNotUpdateItself() {
        for key: Any? in [nil, "", "  ", "$(PLAMONIC_SPARKLE_PUBLIC_KEY)", 42] {
            var dictionary: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]
            dictionary["SUPublicEDKey"] = key
            let info = BuildInfo(infoDictionary: dictionary)
            XCTAssertEqual(info.sparklePublicKey, "", "\(String(describing: key))")
            XCTAssertFalse(info.updatesItself, "\(String(describing: key))")
        }
    }

    func testMissingValues() {
        let info = BuildInfo(infoDictionary: nil)
        XCTAssertEqual(info, BuildInfo(version: "", build: "", sparklePublicKey: ""))
        XCTAssertFalse(info.isBeta)
        XCTAssertEqual(info.displayVersion, "不明")
        XCTAssertEqual(BuildInfo(version: "0.1.0", build: "", sparklePublicKey: "").displayVersion, "0.1.0")
    }

    func testBetaVersions() {
        for version in ["0.2.1-beta.3", "1.0.0-beta.1", "1.0.0-beta", "2.0.0-Beta.7"] {
            XCTAssertTrue(BuildInfo(version: version, build: "1", sparklePublicKey: "").isBeta, version)
        }
        for version in ["0.2.0", "1.10.3", "", "0.1.0-rc.1"] {
            XCTAssertFalse(BuildInfo(version: version, build: "1", sparklePublicKey: "").isBeta, version)
        }
    }

    /// The app this test runs in: the project's own versions, no key (builds from source never update).
    func testTheTestHostIsABuildFromSource() {
        let main = BuildInfo.main
        XCTAssertFalse(main.version.isEmpty)
        XCTAssertFalse(main.build.isEmpty)
        XCTAssertFalse(main.version.contains("$("))
        XCTAssertFalse(main.updatesItself)
    }

    // MARK: - Feed choice

    func testFeedURLs() {
        XCTAssertEqual(
            UpdateChannel.stable.feedURL.absoluteString,
            "https://github.com/sizumita/Plamonic/releases/latest/download/appcast.xml")
        XCTAssertEqual(
            UpdateChannel.beta.feedURL.absoluteString,
            "https://github.com/sizumita/Plamonic/releases/download/beta/appcast.xml")
    }

    func testUnsetFollowsTheBuild() {
        XCTAssertEqual(UpdateChannel.current(receiveBetaUpdates: nil, build: release), .stable)
        XCTAssertEqual(UpdateChannel.current(receiveBetaUpdates: nil, build: beta), .beta)
    }

    func testTheSettingWins() {
        XCTAssertEqual(UpdateChannel.current(receiveBetaUpdates: true, build: release), .beta)
        XCTAssertEqual(UpdateChannel.current(receiveBetaUpdates: false, build: beta), .stable)
        XCTAssertEqual(UpdateChannel.current(receiveBetaUpdates: true, build: beta), .beta)
        XCTAssertEqual(UpdateChannel.current(receiveBetaUpdates: false, build: release), .stable)
    }

    // MARK: - GlobalSettings.receiveBetaUpdates

    func testUnsetByDefault() throws {
        XCTAssertNil(GlobalSettings().receiveBetaUpdates)
        XCTAssertNil(SettingsStore(fileURL: fileURL, saveDelay: 10).global.receiveBetaUpdates)
        XCTAssertNil(try load(#"{"global": {"targetLanguage": "ko"}}"#).global.receiveBetaUpdates)
    }

    func testEveryValueRoundTrips() throws {
        for value: Bool? in [nil, true, false] {
            var doc = SettingsDocument()
            doc.global.receiveBetaUpdates = value
            let data = try SettingsStore.encode(doc)
            let global = try XCTUnwrap(
                (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["global"] as? [String: Any])
            XCTAssertTrue(global.keys.contains("receiveBetaUpdates"), "nil is written as null")
            let decoded = try JSONDecoder().decode(SettingsDocument.self, from: data)
            XCTAssertEqual(decoded.global.receiveBetaUpdates, value)
            XCTAssertEqual(decoded, doc)
        }
    }

    func testOffSurvivesAReload() {
        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        store.updateGlobal { $0.receiveBetaUpdates = false }
        store.flush()
        let reloaded = SettingsStore(fileURL: fileURL, saveDelay: 10)
        XCTAssertEqual(reloaded.loadReport.source, .file)
        XCTAssertEqual(reloaded.global.receiveBetaUpdates, false)
    }

    func testDamagedValueIsDroppedAlone() throws {
        let store = try load(#"{"global": {"targetLanguage": "ko", "receiveBetaUpdates": "yes"}}"#)
        XCTAssertEqual(store.loadReport.source, .salvaged)
        XCTAssertEqual(store.loadReport.problems, ["global.receiveBetaUpdates"])
        XCTAssertEqual(store.global.targetLanguage, "ko")
        XCTAssertNil(store.global.receiveBetaUpdates)
    }

    func testResetFollowsTheBuildAgain() {
        let store = SettingsStore(fileURL: fileURL, saveDelay: 10)
        store.updateGlobal { $0.receiveBetaUpdates = true }
        store.resetAll()
        XCTAssertNil(store.global.receiveBetaUpdates)
    }
}
