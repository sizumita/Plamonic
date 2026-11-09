import Foundation

// Plamonic's native messaging host for Chrome and other Chromium browsers (DESIGN §9.1). The browser starts it
// with pipes when the extension sends a message (ChromeNativeHostInstaller registers it); it forwards each message
// to the Plamonic app's bridge socket unchanged and sends the app's answer back.

func forward(_ message: Data) -> Data {
    var failure = BridgeClient.Failure.notRunning
    for path in BridgeLocation.candidatePaths() {
        do {
            let answer = try BridgeClient.send(message, to: path)
            guard answer.count <= NativeMessaging.maxReplyBytes else {
                return NativeMessaging.failure("tooLarge", "Plamonic の応答が大きすぎます")
            }
            return answer
        } catch BridgeClient.Failure.notRunning {
            continue
        } catch let error as BridgeClient.Failure {
            failure = error
            break
        } catch {
            return NativeMessaging.failure("unreachable", String(describing: error))
        }
    }
    let code = failure == .notRunning ? "appNotRunning" : "unreachable"
    return NativeMessaging.failure(code, failure.description)
}

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
while let message = NativeMessaging.readMessage({ input.readData(ofLength: $0) }) {
    output.write(NativeMessaging.frame(forward(message)))
}
