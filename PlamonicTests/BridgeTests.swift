import Darwin
import XCTest

@testable import Plamonic

private typealias F = TranslationTestFixtures

/// The browser extension bridge: messages, the service and the socket (DESIGN §9).
final class BridgeTests: XCTestCase {
    @MainActor
    private func makeService(
        _ backend: TranslationFakeBackend = TranslationFakeBackend(), configure: (inout GlobalSettings) -> Void = { _ in }
    ) -> BridgeService {
        var global = F.settings(draft: nil).global
        configure(&global)
        let coordinator = F.coordinator(backend)
        return BridgeService(
            coordinator: coordinator, globalSettings: { global }, isReady: { _ in true }, appVersion: "9.9.9")
    }

    @MainActor
    private func send(_ service: BridgeService, _ json: String) async throws -> [String: Any] {
        let data = await service.handle(line: Data(json.utf8))
        XCTAssertEqual(data.last, 0x0A)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testRequestsDecodeAndMalformedLinesKeepTheirID() {
        let line = #"{"id":"a1","type":"sync","client":"safari","document":"yt:x","focus":"c3","urgent":2}"#
        guard case .request(let request) = BridgeCoding.decodeRequest(Data(line.utf8)) else {
            return XCTFail("not decoded")
        }
        XCTAssertEqual(request.id, .string("a1"))
        XCTAssertEqual(request.type, .sync)
        XCTAssertEqual(request.focus, "c3")
        XCTAssertNil(request.items)

        guard case .failure(let failure) = BridgeCoding.decodeRequest(Data(#"{"id":7,"type":"fly"}"#.utf8)) else {
            return XCTFail("decoded an unknown type")
        }
        XCTAssertEqual(failure.id, .number(7))
        XCTAssertEqual(failure.error, "badRequest")
    }

    @MainActor
    func testHelloDescribesTheApp() async throws {
        let response = try await send(makeService(), #"{"id":1,"type":"hello","client":"chrome"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["id"] as? Int, 1)
        XCTAssertEqual(response["protocol"] as? Int, BridgeProtocol.version)
        XCTAssertEqual(response["version"] as? String, "9.9.9")
        XCTAssertEqual(response["enabled"] as? Bool, true)
        XCTAssertEqual(response["targetLanguage"] as? String, "ja")
        XCTAssertEqual(response["features"] as? [String], ["documents", "translate"])
    }

    @MainActor
    func testSyncSendsTextsOnceThenPollsResults() async throws {
        let service = makeService()
        let first = try await send(
            service,
            #"{"id":1,"type":"sync","client":"chrome","document":"yt:x","kind":"captions","items":[{"id":"c0","text":"Hello there, everyone."}],"focus":"c0"}"#
        )
        XCTAssertEqual(first["ok"] as? Bool, true)
        XCTAssertEqual((first["results"] as? [[String: Any]])?.first?["state"] as? String, "pending")

        var final: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            final = try await send(service, #"{"id":2,"type":"sync","client":"chrome","document":"yt:x","focus":"c0"}"#)
            if (final["results"] as? [[String: Any]])?.first?["state"] as? String == "final" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let result = try XCTUnwrap((final["results"] as? [[String: Any]])?.first)
        XCTAssertEqual(result["text"] as? String, TranslationFakeBackend.output(for: "Hello there, everyone.", model: .b2))
        XCTAssertEqual((final["progress"] as? [String: Any])?["done"] as? Int, 1)

        let unknown = try await send(service, #"{"id":3,"type":"sync","client":"safari","document":"yt:x"}"#)
        XCTAssertEqual(unknown["error"] as? String, "unknownDocument")
    }

    @MainActor
    func testTranslateAnswersEachText() async throws {
        let backend = TranslationFakeBackend()
        backend.fail("Broken text here", times: 9)
        let response = try await send(
            makeService(backend), #"{"id":1,"type":"translate","texts":["Good morning to you","Broken text here"]}"#)
        let translations = try XCTUnwrap(response["translations"] as? [Any])
        XCTAssertEqual(translations.first as? String, TranslationFakeBackend.output(for: "Good morning to you", model: .b2))
        XCTAssertTrue(translations.last is NSNull)
    }

    @MainActor
    func testNothingIsTranslatedWhileTurnedOff() async throws {
        let backend = TranslationFakeBackend()
        let service = makeService(backend) { $0.acceptBrowserExtensions = false }
        let hello = try await send(service, #"{"type":"hello"}"#)
        XCTAssertEqual(hello["enabled"] as? Bool, false)
        let sync = try await send(
            service, #"{"type":"sync","document":"d","items":[{"id":"1","text":"Hello there, everyone."}]}"#)
        XCTAssertEqual(sync["error"] as? String, "disabled")
        XCTAssertTrue(backend.calls.isEmpty)
    }

    /// 翻訳を有効にする is the overlays' switch; the extensions keep working while it is off.
    @MainActor
    func testTheOverlaySwitchDoesNotTurnTheExtensionsOff() async throws {
        let backend = TranslationFakeBackend()
        let service = makeService(backend) { $0.isEnabled = false }
        let hello = try await send(service, #"{"type":"hello"}"#)
        XCTAssertEqual(hello["enabled"] as? Bool, true)
        let response = try await send(service, #"{"type":"translate","texts":["Good morning to you"]}"#)
        XCTAssertEqual(response["ok"] as? Bool, true)
    }

    func testOldSettingsFilesTurnTheBridgeOn() throws {
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.acceptBrowserExtensions)
        var global = GlobalSettings()
        global.acceptBrowserExtensions = false
        let roundTrip = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(global))
        XCTAssertFalse(roundTrip.acceptBrowserExtensions)
    }

    // MARK: - Socket

    func testSocketAnswersEveryLineOfAConnection() throws {
        let path = NSTemporaryDirectory() + "plb-\(UUID().uuidString.prefix(8)).sock"
        let server = BridgeSocketServer(path: path) { line in
            Data("echo:".utf8) + line + Data([0x0A])
        }
        try server.start()
        defer { server.stop() }

        let fd = try connect(path)
        defer { close(fd) }
        write(fd, "one\ntwo\n")
        XCTAssertEqual(readLines(fd, count: 2), ["echo:one", "echo:two"])
        // The last request may come without a newline before the client stops writing.
        write(fd, "three")
        shutdown(fd, SHUT_WR)
        XCTAssertEqual(readLines(fd, count: 1), ["echo:three"])

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testOversizedRequestsAreRefused() throws {
        let path = NSTemporaryDirectory() + "plb-\(UUID().uuidString.prefix(8)).sock"
        let server = BridgeSocketServer(path: path, maxLineBytes: 16) { _ in Data("ok\n".utf8) }
        try server.start()
        defer { server.stop() }
        let fd = try connect(path)
        defer { close(fd) }
        write(fd, String(repeating: "x", count: 64))
        let line = try XCTUnwrap(readLines(fd, count: 1).first)
        XCTAssertTrue(line.contains("tooLarge"), line)
    }

    private func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func write(_ fd: Int32, _ text: String) {
        _ = Array(text.utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    private func readLines(_ fd: Int32, count: Int) -> [String] {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while buffer.filter({ $0 == 0x0A }).count < count {
            let got = read(fd, &chunk, chunk.count)
            if got <= 0 { break }
            buffer.append(chunk, count: got)
        }
        return String(decoding: buffer, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
