import Darwin
import Foundation

/// The other end of BridgeSocketServer: sends one request line and reads one response line. Used by the Safari
/// extension (and the Chrome native messaging host) to reach the app, and by the tests.
enum BridgeClient {
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// Nobody listens: the app is not running, or turned the extensions off.
        case notRunning
        case timedOut
        case system(String, Int32)

        var description: String {
            switch self {
            case .notRunning: "Plamonic が起動していません"
            case .timedOut: "Plamonic から応答がありません"
            case .system(let call, let code): "\(call): \(String(cString: strerror(code)))"
            }
        }
    }

    /// Sends `request` (one JSON object, without a newline) and returns the response line without its newline.
    static func send(_ request: Data, to path: String, timeout: TimeInterval = 120) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var time = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= BridgeLocation.maxPathBytes else { throw Failure.system("connect", ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            let code = errno
            throw code == ENOENT || code == ECONNREFUSED ? Failure.notRunning : Failure.system("connect", code)
        }

        let line = request + Data([0x0A])
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.system("write", errno) }
                offset += count
            }
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while response.firstIndex(of: 0x0A) == nil {
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { throw Failure.timedOut }
            guard count > 0 else { break }
            response.append(chunk, count: count)
        }
        if let newline = response.firstIndex(of: 0x0A) { response = response[response.startIndex..<newline] }
        return Data(response)
    }
}
