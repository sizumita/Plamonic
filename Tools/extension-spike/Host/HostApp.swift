import AppKit
import SafariServices

/// Stands in for Plamonic: serves the App Group socket, logs every request and answers with a fake translation.
/// It also writes the Chrome native messaging manifest pointing at the helper inside this app.
@main
final class HostApp: NSObject, NSApplicationDelegate {
    static let safariExtensionID = "io.smdr.PlamonicSpike.SafariExtension"
    static let nativeHostName = "io.smdr.plamonic.spike"
    static let chromeExtensionID = "bdoanndchiakcnoejbbjabpenbgbkfcb"

    private var window: NSWindow!
    private let textView = NSTextView()

    static func main() {
        let app = NSApplication.shared
        let delegate = HostApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        log("socket: \(SpikeSocket.socketPath)")
        if SpikeSocket.isServed {
            log("Plamonic is listening: the extension talks to it, this app only stands by")
        } else {
            serveStandIn()
        }
        writeChromeManifest()
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: Self.safariExtensionID) { state, error in
            DispatchQueue.main.async {
                self.log("Safari extension enabled: \(state.map { String($0.isEnabled) } ?? "?") \(error.map { "\($0)" } ?? "")")
            }
        }
    }

    /// Answers like Plamonic's `translate` with a fake translation, when Plamonic is not running.
    private func serveStandIn() {
        do {
            try SpikeSocket.serve { [weak self] request in
                let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any] ?? [:]
                let texts = object["texts"] as? [String] ?? []
                let browser = object["browser"] as? String ?? "?"
                DispatchQueue.main.async { self?.log("request from \(browser): \(texts.count) texts") }
                let reply: [String: Any] = [
                    "translations": texts.map { "[訳] \($0)" },
                    "hostPID": ProcessInfo.processInfo.processIdentifier,
                ]
                return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
            }
            log("listening as a stand-in for Plamonic")
        } catch {
            log("serve failed: \(error)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func writeChromeManifest() {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/MacOS/plamonic-spike-native-host").path
        let manifest: [String: Any] = [
            "name": Self.nativeHostName,
            "description": "Plamonic spike native host",
            "path": helper,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(Self.chromeExtensionID)/"],
        ]
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Google/Chrome/NativeMessagingHosts")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
            try data.write(to: directory.appending(path: "\(Self.nativeHostName).json"))
            log("Chrome manifest written → \(helper)")
        } catch {
            log("Chrome manifest failed: \(error)")
        }
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Plamonic Spike Host"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 44, width: 640, height: 316))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.frame = scroll.bounds
        scroll.documentView = textView
        let button = NSButton(title: "Safari の拡張機能設定を開く", target: self, action: #selector(openSafariSettings))
        button.frame = NSRect(x: 12, y: 8, width: 260, height: 28)
        window.contentView?.addSubview(scroll)
        window.contentView?.addSubview(button)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func openSafariSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: Self.safariExtensionID) { error in
            DispatchQueue.main.async { self.log("open Safari settings: \(error.map { "\($0)" } ?? "ok")") }
        }
    }

    private func log(_ line: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        textView.textStorage?.append(NSAttributedString(
            string: "\(stamp) \(line)\n",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.textColor]))
        textView.scrollToEndOfDocument(nil)
        NSLog("[spike-host] %@", line)
    }
}
