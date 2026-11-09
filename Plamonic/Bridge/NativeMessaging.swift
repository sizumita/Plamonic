import Foundation

/// Chrome's native messaging framing: each message is a 4-byte length in the machine's byte order followed by that
/// many bytes of UTF-8 JSON, both ways over the host's stdin and stdout. Chrome limits a message to the host at 1 MB
/// (DESIGN §9.1).
enum NativeMessaging {
    /// What Chrome accepts from a host.
    static let maxReplyBytes = 1024 * 1024
    /// What we read from Chrome (it allows up to 64 MiB; nothing we send is near that).
    static let maxMessageBytes = 16 * 1024 * 1024

    static func frame(_ body: Data) -> Data {
        var length = UInt32(body.count).littleEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// The length a 4-byte header announces, or nil when the header is short.
    static func length(of header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let value = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return Int(UInt32(littleEndian: value))
    }

    /// The next message from `read` (which returns up to the asked number of bytes, empty at the end), or nil at
    /// the end of input or for a message too large to take.
    static func readMessage(_ read: (Int) -> Data) -> Data? {
        guard let length = length(of: readExactly(4, read)), length <= maxMessageBytes else { return nil }
        let body = readExactly(length, read)
        return body.count == length ? body : nil
    }

    private static func readExactly(_ count: Int, _ read: (Int) -> Data) -> Data {
        var data = Data()
        while data.count < count {
            let chunk = read(count - data.count)
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }

    /// A reply Chrome accepts: `ok: false` with `error` and `message`, as the extension expects from the bridge.
    static func failure(_ error: String, _ message: String) -> Data {
        let object: [String: Any] = ["ok": false, "error": error, "message": message]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"ok":false}"#.utf8)
    }
}
