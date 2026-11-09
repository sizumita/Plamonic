import Darwin
import Foundation

// Chrome native messaging host: Chrome starts this with stdin/stdout pipes. Each message is a 4-byte length in
// native byte order followed by UTF-8 JSON. Every message is forwarded to the host app over the App Group socket.

func readExactly(_ count: Int) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: count)
    while data.count < count {
        let got = read(STDIN_FILENO, &buffer, count - data.count)
        if got <= 0 { return nil }
        data.append(buffer, count: got)
    }
    return data
}

func send(_ object: Any) {
    guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
    var length = UInt32(body.count)
    let header = Data(bytes: &length, count: 4)
    SpikeSocket.writeAll(STDOUT_FILENO, header + body)
}

while let header = readExactly(4) {
    let length = header.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
    guard let body = readExactly(length) else { break }
    do {
        let answer = try SpikeSocket.request(body)
        var object = (try JSONSerialization.jsonObject(with: answer)) as? [String: Any] ?? [:]
        object["via"] = "chrome-native-host → socket"
        send(object)
    } catch {
        send(["error": String(describing: error), "via": "chrome-native-host", "socket": SpikeSocket.socketPath])
    }
}
