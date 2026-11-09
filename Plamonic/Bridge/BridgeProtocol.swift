import Foundation

/// Messages between the browser extensions and the app, one JSON object per line over the bridge socket
/// (DESIGN §9). The Safari extension and the Chrome native messaging host forward the extension's messages as
/// they are; the app answers each request with one response carrying the same `id`.
enum BridgeProtocol {
    /// Raised when a message changes incompatibly. The extension compares it with the one it speaks.
    static let version = 1
    /// Longest request line; a whole video's captions fit easily.
    static let maxMessageBytes = 8 * 1024 * 1024
    static let maxItems = 10_000
    static let maxItemCharacters = 2_000
    static let maxContextCharacters = 1_000
    /// Texts from the focus that go before everything on screen.
    static let defaultUrgentCount = 3
    static let maxUrgentCount = 20
    /// Texts in one `translate` request.
    static let maxTranslateTexts = 20
    /// What this app answers, listed in `hello` so a newer extension can tell what an older app offers.
    static let features = ["documents", "translate"]
}

/// The `id` the extension chose; echoed in the response. A number or a string.
enum BridgeMessageID: Codable, Equatable, Sendable {
    case number(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        }
    }
}

struct BridgeRequest: Decodable, Equatable, Sendable {
    enum Kind: String, Decodable, Sendable {
        /// Who is there: the app's version, protocol and whether it translates now.
        case hello
        /// Sends a document's texts (optional after the first time) and its focus; answers with results.
        case sync
        /// The extension is done with a document.
        case close
        /// Translates a few texts once (a selection, a tooltip) ahead of background work; answers when done.
        case translate
    }

    struct Item: Decodable, Equatable, Sendable {
        var id: String
        var text: String
    }

    var id: BridgeMessageID?
    var type: Kind
    /// "chrome" or "safari": documents of different browsers never mix.
    var client: String?
    var document: String?
    /// What the document is: "captions" (one continuous talk: earlier lines go along as history) or "page"
    /// (independent paragraphs). Unknown kinds are treated as "page".
    var kind: String?
    var items: [Item]?
    /// Id of the item being shown.
    var focus: String?
    /// How many items from the focus are urgent.
    var urgent: Int?
    /// Items whose results the extension wants; nil = all of them.
    var want: [String]?
    /// Passed to the model as PFML3 context, such as the video's title and channel.
    var context: String?
    /// The source language as the page states it (a BCP 47 tag such as "en" or "pt-BR"); nil = detect.
    var sourceLanguage: String?
    /// For `translate`.
    var texts: [String]?
}

struct BridgeResponse: Encodable, Equatable, Sendable {
    struct Result: Encodable, Equatable, Sendable {
        var id: String
        var state: String
        /// Present for draft and final results.
        var text: String?
    }

    struct Progress: Encodable, Equatable, Sendable {
        var done: Int
        var total: Int
    }

    var id: BridgeMessageID?
    var ok: Bool
    /// Machine-readable reason when `ok` is false: badRequest, unknownDocument, disabled, tooLarge.
    var error: String?
    var message: String?

    // hello
    var `protocol`: Int?
    var app: String?
    var version: String?
    var enabled: Bool?
    var targetLanguage: String?
    /// Whether a model is installed to translate with.
    var ready: Bool?
    var features: [String]?

    // sync
    var results: [Result]?
    var progress: Progress?

    // translate: one entry per text, null where it failed
    var translations: [String?]?

    static func failure(_ id: BridgeMessageID?, _ error: String, _ message: String) -> BridgeResponse {
        BridgeResponse(id: id, ok: false, error: error, message: message)
    }
}

enum BridgeCoding {
    enum Decoded: Equatable {
        case request(BridgeRequest)
        /// The line is not a request; this is the answer to send back.
        case failure(BridgeResponse)
    }

    static func decodeRequest(_ line: Data) -> Decoded {
        do {
            return .request(try JSONDecoder().decode(BridgeRequest.self, from: line))
        } catch {
            // Echo the id when the rest is malformed, so the extension can match the error to its request.
            let id = (try? JSONDecoder().decode(IDOnly.self, from: line))?.id
            return .failure(.failure(id, "badRequest", "リクエストを読めません: \(error.localizedDescription)"))
        }
    }

    static func encode(_ response: BridgeResponse) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(response)) ?? Data(#"{"ok":false,"error":"internal"}"#.utf8)
        return data + Data([0x0A])
    }

    private struct IDOnly: Decodable {
        var id: BridgeMessageID?
    }
}
