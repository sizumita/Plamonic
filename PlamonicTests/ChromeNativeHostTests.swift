import XCTest

@testable import Plamonic

/// Chrome's native messaging host and its registration (DESIGN §9.1).
final class ChromeNativeHostTests: XCTestCase {
    func testMessagesAreFramedWithTheirLength() throws {
        let body = Data(#"{"type":"hello"}"#.utf8)
        let framed = NativeMessaging.frame(body)
        XCTAssertEqual(framed.count, 4 + body.count)
        XCTAssertEqual(NativeMessaging.length(of: framed.prefix(4)), body.count)

        // Read back two messages from a stream that hands out a few bytes at a time, then the end.
        var stream = framed + NativeMessaging.frame(Data("{}".utf8))
        let read: (Int) -> Data = { count in
            let chunk = stream.prefix(min(count, 3))
            stream.removeFirst(chunk.count)
            return Data(chunk)
        }
        XCTAssertEqual(NativeMessaging.readMessage(read), body)
        XCTAssertEqual(NativeMessaging.readMessage(read), Data("{}".utf8))
        XCTAssertNil(NativeMessaging.readMessage(read))

        // A header announcing more than we take is refused.
        var huge = NativeMessaging.frame(Data())
        huge.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(NativeMessaging.maxMessageBytes + 1).littleEndian) { Data($0) })
        var hugeStream = huge
        XCTAssertNil(NativeMessaging.readMessage { count in
            let chunk = hugeStream.prefix(count)
            hugeStream.removeFirst(chunk.count)
            return Data(chunk)
        })
    }

    func testTheHostIsRegisteredWithInstalledBrowsersOnly() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "plamonic-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appending(path: "Library/Application Support")
        try FileManager.default.createDirectory(at: support.appending(path: "Google/Chrome"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: support.appending(path: "BraveSoftware/Brave-Browser"), withIntermediateDirectories: true)
        let app = home.appending(path: "Applications/Plamonic.app")
        let helper = app.appending(path: ChromeNativeHostInstaller.helperPath)
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: helper.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let installed = ChromeNativeHostInstaller.install(appBundle: app, home: home)
        XCTAssertEqual(installed, ["Google Chrome", "Brave"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appending(path: "Microsoft Edge").path))
        let file = support.appending(path: "Google/Chrome/NativeMessagingHosts/io.smdr.plamonic.json")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(manifest["name"] as? String, "io.smdr.plamonic")
        XCTAssertEqual(manifest["path"] as? String, helper.path)
        XCTAssertEqual(manifest["type"] as? String, "stdio")
        XCTAssertEqual(manifest["allowed_origins"] as? [String], ["chrome-extension://bdoanndchiakcnoejbbjabpenbgbkfcb/"])
        XCTAssertEqual(ChromeNativeHostInstaller.installedBrowsers(appBundle: app, home: home), ["Google Chrome", "Brave"])

        // The app moved: the manifests follow it.
        let moved = home.appending(path: "Moved/Plamonic.app")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: app, to: moved)
        XCTAssertEqual(ChromeNativeHostInstaller.installedBrowsers(appBundle: moved, home: home), [])
        ChromeNativeHostInstaller.install(appBundle: moved, home: home)
        XCTAssertEqual(ChromeNativeHostInstaller.installedBrowsers(appBundle: moved, home: home), ["Google Chrome", "Brave"])
    }

    func testTheHostLooksInTheGroupContainerFirst() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(
            BridgeLocation.candidatePaths(home: home),
            [
                "/Users/someone/Library/Group Containers/NBDP5VK335.io.smdr.Plamonic/bridge.sock",
                "/Users/someone/Library/Application Support/Plamonic/bridge.sock",
            ])
    }
}
