import Darwin
import Foundation
import os

/// A Unix socket that answers newline-delimited JSON requests, one response line per request line. Each
/// connection may send several requests; the Safari extension and the Chrome host usually send one and close.
///
/// Only processes of the same user may connect (the socket is 0600 and the peer's uid is checked). Accepting
/// and reading block, so they run on their own threads; `handle` runs wherever its caller chooses.
final class BridgeSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (Data) async -> Data

    enum Failure: Error, CustomStringConvertible {
        case system(String, Int32)
        case pathTooLong(String)

        var description: String {
            switch self {
            case .system(let call, let code): "\(call): \(String(cString: strerror(code)))"
            case .pathTooLong(let path): "ソケットのパスが長すぎます: \(path)"
            }
        }
    }

    let path: String
    private let handler: Handler
    private let maxLineBytes: Int
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var clients: Set<Int32> = []
    private let log = Logger(subsystem: "io.smdr.Plamonic", category: "Bridge")

    init(path: String, maxLineBytes: Int = BridgeProtocol.maxMessageBytes, handler: @escaping Handler) {
        self.path = path
        self.maxLineBytes = maxLineBytes
        self.handler = handler
    }

    deinit { stop() }

    var isRunning: Bool { locked { listener >= 0 } }

    func start() throws {
        guard !isRunning else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var address = try Self.address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        // A socket file left by a run that crashed refuses bind; nobody listens on it any more.
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw Failure.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw Failure.system("listen", code)
        }
        locked { listener = fd }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "Plamonic bridge accept"
        thread.start()
        log.info("Bridge listening at \(self.path, privacy: .public)")
    }

    func stop() {
        let (fd, open) = locked { () -> (Int32, Set<Int32>) in
            defer {
                listener = -1
                clients.removeAll()
            }
            return (listener, clients)
        }
        guard fd >= 0 else { return }
        // shutdown wakes the threads blocked in accept and read.
        shutdown(fd, SHUT_RDWR)
        close(fd)
        for client in open { shutdown(client, SHUT_RDWR) }
        unlink(path)
    }

    // MARK: - Connections

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            guard locked({ listener == fd }) else {
                close(client)
                return
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // A client that stops talking is dropped after a while instead of holding a thread forever.
            var timeout = timeval(tv_sec: 60, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            locked { _ = clients.insert(client) }
            let thread = Thread { [weak self] in
                self?.serve(client)
                close(client)
            }
            thread.name = "Plamonic bridge client"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { locked { _ = clients.remove(fd) } }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) else { continue }
                guard write(Self.respond(to: Data(line), handler: handler), to: fd) else { return }
            }
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 {
                // End of input: a last request without a newline still gets its answer.
                if count == 0, !buffer.isEmpty { _ = write(Self.respond(to: buffer, handler: handler), to: fd) }
                return
            }
            buffer.append(chunk, count: count)
            if buffer.count > maxLineBytes, buffer.firstIndex(of: 0x0A) == nil {
                let response = BridgeResponse.failure(nil, "tooLarge", "リクエストが大きすぎます")
                _ = write(BridgeCoding.encode(response), to: fd)
                return
            }
        }
    }

    /// Runs the async handler from this blocking thread.
    private static func respond(to line: Data, handler: @escaping Handler) -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        Task.detached {
            box.value = await handler(line)
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base + offset, raw.count - offset)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= BridgeLocation.maxPathBytes else { throw Failure.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private final class ResponseBox: @unchecked Sendable {
        var value = Data()
    }
}
