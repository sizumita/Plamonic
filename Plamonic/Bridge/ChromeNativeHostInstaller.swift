import Foundation

/// Registers the Chrome native messaging host inside the app (`Contents/Helpers/plamonic-chrome-host`) with the
/// Chromium browsers on this Mac: each finds hosts by name in its own NativeMessagingHosts folder, and lets only the
/// listed extensions talk to them (DESIGN §9.1). Written at launch, so a moved app is found again; a manifest
/// already right is left alone.
enum ChromeNativeHostInstaller {
    /// What the extension passes to `sendNativeMessage` (BrowserExtension/scripts/build.mjs).
    static let hostName = "io.smdr.plamonic"
    static let helperPath = "Contents/Helpers/plamonic-chrome-host"
    /// Extensions allowed to use the host: the build from BrowserExtension/ (its manifest `key` fixes this ID).
    /// Add the Chrome Web Store's ID here when the extension is published there.
    static let extensionIDs = ["bdoanndchiakcnoejbbjabpenbgbkfcb"]

    struct Browser: Equatable, Sendable {
        var name: String
        /// Its data folder, under ~/Library/Application Support; the host manifest goes in NativeMessagingHosts.
        var folder: String
    }

    static let browsers: [Browser] = [
        Browser(name: "Google Chrome", folder: "Google/Chrome"),
        Browser(name: "Google Chrome Beta", folder: "Google/Chrome Beta"),
        Browser(name: "Google Chrome Dev", folder: "Google/Chrome Dev"),
        Browser(name: "Google Chrome Canary", folder: "Google/Chrome Canary"),
        Browser(name: "Chromium", folder: "Chromium"),
        Browser(name: "Microsoft Edge", folder: "Microsoft Edge"),
        Browser(name: "Brave", folder: "BraveSoftware/Brave-Browser"),
        Browser(name: "Arc", folder: "Arc/User Data"),
        Browser(name: "Vivaldi", folder: "Vivaldi"),
    ]

    static func manifest(helper: URL) -> Data {
        let object: [String: Any] = [
            "name": hostName,
            "description": "Plamonic",
            "path": helper.path,
            "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" },
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
    }

    /// Writes the host manifest for every browser that is installed (its data folder exists). Returns their names.
    @discardableResult
    static func install(appBundle: URL = Bundle.main.bundleURL, home: URL = BridgeLocation.realHome()) -> [String] {
        let helper = appBundle.appending(path: helperPath)
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return [] }
        let data = manifest(helper: helper)
        var installed: [String] = []
        for browser in browsers {
            let folder = home.appending(path: "Library/Application Support/\(browser.folder)")
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            let hosts = folder.appending(path: "NativeMessagingHosts")
            let file = hosts.appending(path: "\(hostName).json")
            do {
                if (try? Data(contentsOf: file)) != data {
                    try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
                    try data.write(to: file, options: .atomic)
                }
                installed.append(browser.name)
            } catch {
                continue
            }
        }
        return installed
    }

    /// The browsers whose manifest points at this app's host.
    static func installedBrowsers(appBundle: URL = Bundle.main.bundleURL, home: URL = BridgeLocation.realHome()) -> [String] {
        let expected = manifest(helper: appBundle.appending(path: helperPath))
        return browsers.filter { browser in
            let file = home.appending(
                path: "Library/Application Support/\(browser.folder)/NativeMessagingHosts/\(hostName).json")
            return (try? Data(contentsOf: file)) == expected
        }.map(\.name)
    }
}
