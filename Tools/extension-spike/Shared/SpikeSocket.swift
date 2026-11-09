import Darwin
import Foundation

/// One request per connection over a Unix socket in the App Group container: the client writes JSON and shuts
/// down its writing side, the server answers with JSON and closes. Used by the host app (server), the sandboxed
/// Safari extension and the Chrome native host (clients).
enum SpikeSocket {
    /// Plamonic's own group and socket (DESIGN §9), so the spike extension talks to the real app.
    static let appGroup = "NBDP5VK335.io.smdr.Plamonic"

    enum Failure: Error, CustomStringConvertible {
        case system(String, Int32)
        case pathTooLong(String)

        var description: String {
            switch self {
            case let .system(call, code): "\(call): \(String(cString: strerror(code))) (\(code))"
            case let .pathTooLong(path): "socket path too long: \(path)"
            }
        }
    }

    /// The group container. A sandboxed process gets it from the entitlement; a process without the entitlement
    /// (the Chrome native host) builds the same path from the real home directory.
    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url
        }
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appending(path: "Library/Group Containers/\(appGroup)")
    }

    static var socketPath: String { containerURL.appending(path: "bridge.sock").path }

    /// Whether something (Plamonic) already listens on the socket.
    static var isServed: Bool { (try? request(Data(#"{"type":"hello"}"#.utf8))).map { !$0.isEmpty } ?? false }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw Failure.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if count <= 0 { return }
                offset += count
            }
        }
    }

    /// Client side.
    static func request(_ body: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        defer { close(fd) }
        var address = try address(socketPath)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw Failure.system("connect \(socketPath)", errno) }
        writeAll(fd, body)
        shutdown(fd, SHUT_WR)
        return readAll(fd)
    }

    /// Server side: binds and listens, then calls `handle` for each connection on a background thread.
    static func serve(handle: @escaping @Sendable (Data) -> Data) throws {
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        let path = socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        var address = try address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw Failure.system("bind \(path)", errno) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { throw Failure.system("listen", errno) }
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                DispatchQueue.global().async {
                    let request = readAll(client)
                    writeAll(client, handle(request))
                    close(client)
                }
            }
        }
    }
}
