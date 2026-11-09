import Foundation
import SafariServices
import os

/// The native side of Plamonic's Safari extension (BrowserExtension/). Safari delivers every
/// `browser.runtime.sendNativeMessage` here; it is forwarded unchanged to the app's bridge socket and the app's
/// answer goes back to the extension (DESIGN §9). This extension is sandboxed: the App Group container is the only
/// place it shares with the app.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] ?? [:]
        let reply = Self.forward(message)
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    static func forward(_ message: Any) -> [String: Any] {
        guard BridgeLocation.usableAppGroup() != nil else {
            // Built without the team that owns the App Group (an ad hoc build): the app's socket is out of reach.
            return failure("appNotRunning", "このビルドの Safari 拡張機能は Plamonic に接続できません（チームの署名がありません）")
        }
        do {
            let request = try JSONSerialization.data(withJSONObject: message)
            let answer = try BridgeClient.send(request, to: BridgeLocation.socketURL().path)
            guard let object = try JSONSerialization.jsonObject(with: answer) as? [String: Any] else {
                return failure("badResponse", "Plamonic の応答を読めません")
            }
            return object
        } catch BridgeClient.Failure.notRunning {
            return failure("appNotRunning", BridgeClient.Failure.notRunning.description)
        } catch {
            Logger(subsystem: "io.smdr.Plamonic", category: "SafariExtension")
                .error("Forwarding failed: \(String(describing: error), privacy: .public)")
            return failure("unreachable", String(describing: error))
        }
    }

    private static func failure(_ error: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": error, "message": message]
    }
}
