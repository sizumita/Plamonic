import Foundation
import XCTest

@testable import PlamoKit

/// Reference data from the Python models run with mlx-lm (Fixtures/reference*.json).
/// The fixtures are output of PLaMo 3 Translate (PLaMo Community License); see THIRD_PARTY_NOTICES.md.
/// The license's terms also apply to any model trained using them.
struct ReferenceFile {
    struct Case {
        var kwargs: [String: Any]
        var messages: [[String: String]]
        var prompt: String
        var promptIDs: [Int]
        var output: String
        var top5: [Int]
        var top5Logits: [Double]

        /// The same request expressed with PlamoKit types.
        var request: PlamoTranslationRequest {
            var history = [PlamoHistoryPair]()
            var i = 0
            while i + 1 < messages.count {
                history.append(PlamoHistoryPair(source: messages[i]["content"]!, translation: messages[i + 1]["content"]!))
                i += 2
            }
            let glossary = (kwargs["glossary"] as? [[String: String]] ?? []).map {
                PlamoGlossaryEntry(source: $0["source"]!, target: $0["target"]!)
            }
            return PlamoTranslationRequest(
                text: messages.last!["content"]!,
                targetLanguage: kwargs["target_lang"] as! String,
                sourceLanguage: kwargs["source_lang"] as? String,
                context: kwargs["context"] as? String,
                glossary: glossary,
                form: kwargs["form"] as? String,
                history: history,
                maxNewTokens: 256)
        }
    }

    struct TokenizerCase {
        var text: String
        var ids: [Int]
        var decoded: String
    }

    var cases: [Case]
    var tokenizer: [TokenizerCase]

    static func load(_ name: String) throws -> ReferenceFile? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            return nil
        }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let cases = (json["cases"] as? [[String: Any]] ?? []).map { c in
            Case(
                kwargs: c["kwargs"] as? [String: Any] ?? [:],
                messages: c["messages"] as! [[String: String]],
                prompt: c["prompt"] as! String,
                promptIDs: (c["prompt_ids"] as! [NSNumber]).map(\.intValue),
                output: c["output"] as! String,
                top5: (c["top5"] as! [NSNumber]).map(\.intValue),
                top5Logits: (c["top5_logits"] as! [NSNumber]).map(\.doubleValue))
        }
        let tokenizer = (json["tokenizer"] as? [[String: Any]] ?? []).map { t in
            TokenizerCase(
                text: t["text"] as! String,
                ids: (t["ids"] as! [NSNumber]).map(\.intValue),
                decoded: t["decoded"] as! String)
        }
        return ReferenceFile(cases: cases, tokenizer: tokenizer)
    }
}

enum TestModels {
    static let store = PlamoModelStore()

    /// Directory of an installed variant, or nil (tests then skip).
    static func directory(_ variant: PlamoModelVariant) -> URL? {
        let dir = store.directory(for: variant)
        return PlamoModelStore.validationProblem(directory: dir) == nil ? dir : nil
    }
}

/// Code points, so that canonically equivalent but different strings do not compare equal.
func scalars(_ s: String) -> [UInt32] {
    s.unicodeScalars.map(\.value)
}
