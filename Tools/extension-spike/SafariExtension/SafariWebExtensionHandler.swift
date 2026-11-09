import Foundation
import os
import SafariServices

/// Receives `browser.runtime.sendNativeMessage` from the extension (in this sandboxed app extension process) and
/// forwards it to the host app over the App Group socket.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let logger = Logger(subsystem: "io.smdr.PlamonicSpike", category: "safari-extension")

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] ?? [:]
        var reply: Any
        do {
            let body = try JSONSerialization.data(withJSONObject: message)
            let answer = try SpikeSocket.request(body)
            var object = (try JSONSerialization.jsonObject(with: answer)) as? [String: Any] ?? [:]
            object["via"] = "safari-appex → socket"
            reply = object
        } catch {
            logger.error("forward failed: \(String(describing: error), privacy: .public)")
            reply = ["error": String(describing: error), "via": "safari-appex", "socket": SpikeSocket.socketPath]
        }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response])
    }
}
