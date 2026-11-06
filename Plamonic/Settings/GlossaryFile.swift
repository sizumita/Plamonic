import Foundation

/// JSON import / export of glossaries.
///
/// Export format: `[{"source": "...", "target": "..."}, ...]`.
/// Import also accepts `{"terms": [...]}`, `{"glossary": [...]}`, a single entry without the brackets
/// and a plain `{"source": "target"}` object. Entries with an empty target are skipped and counted.
enum GlossaryFile {
    enum ImportError: LocalizedError {
        case unsupportedFormat

        var errorDescription: String? {
            "用語集の形式を読み取れませんでした。[{\"source\": \"原語\", \"target\": \"訳語\"}] の形の JSON にしてください。"
        }
    }

    private struct Entry: Codable {
        var source: String
        var target: String
    }

    static func export(_ terms: [GlossaryTerm]) throws -> Data {
        let entries = terms.filter { !$0.source.isEmpty }.map { Entry(source: $0.source, target: $0.target) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(entries)
    }

    /// The terms read from a file, plus how many entries were left out because their target was empty.
    struct Imported: Equatable {
        var terms: [GlossaryTerm]
        /// Entries with a source but no target: PLaMo cannot use them, so they are not imported.
        var skippedWithoutTarget: Int
    }

    static func importTerms(from data: Data) throws -> [GlossaryTerm] {
        try importGlossary(from: data).terms
    }

    static func importGlossary(from data: Data) throws -> Imported {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ImportError.unsupportedFormat
        }
        if let list = json as? [Any] { return try terms(fromList: list) }
        if let dict = json as? [String: Any] {
            if let list = (dict["terms"] ?? dict["glossary"]) as? [Any] { return try terms(fromList: list) }
            // One entry without the surrounding [ ] would otherwise read as the terms "source" and "target".
            if isEntry(dict) { return try terms(fromList: [dict]) }
            let pairs = dict.compactMap { key, value -> (String, String)? in
                guard let target = value as? String else { return nil }
                return (key, target)
            }
            if pairs.count == dict.count, !pairs.isEmpty {
                var result = Imported(terms: [], skippedWithoutTarget: 0)
                for (source, target) in pairs.sorted(by: { $0.0 < $1.0 }) {
                    add(source: source, target: target, to: &result)
                }
                return result
            }
        }
        throw ImportError.unsupportedFormat
    }

    private static let sourceKeys = ["source", "src", "from"]
    private static let targetKeys = ["target", "tgt", "to"]
    /// Keys an entry may carry: the source and target spellings, plus the id of terms copied from settings.json.
    private static let entryKeys = Set(sourceKeys + targetKeys + ["id"])

    /// True for an object shaped like one entry: a source key, a target key and nothing else.
    private static func isEntry(_ dict: [String: Any]) -> Bool {
        sourceKeys.contains { dict[$0] != nil } && targetKeys.contains { dict[$0] != nil }
            && dict.keys.allSatisfy(entryKeys.contains)
    }

    private static func terms(fromList list: [Any]) throws -> Imported {
        var result = Imported(terms: [], skippedWithoutTarget: 0)
        for item in list {
            guard let dict = item as? [String: Any] else { throw ImportError.unsupportedFormat }
            let source = sourceKeys.lazy.compactMap { dict[$0] }.first as? String
            let target = targetKeys.lazy.compactMap { dict[$0] }.first as? String
            guard let source, let target else { throw ImportError.unsupportedFormat }
            add(source: source, target: target, to: &result)
        }
        return result
    }

    /// Trims both sides; drops entries without a source and counts the ones without a target.
    private static func add(source: String, target: String, to result: inout Imported) {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        guard !target.isEmpty else {
            result.skippedWithoutTarget += 1
            return
        }
        result.terms.append(GlossaryTerm(source: source, target: target))
    }

    /// Adds imported terms; an imported term replaces an existing term with the same source.
    static func merge(_ existing: [GlossaryTerm], with imported: [GlossaryTerm]) -> (
        terms: [GlossaryTerm], added: Int, updated: Int
    ) {
        var terms = existing
        var added = 0
        var updated = 0
        for term in imported {
            if let index = terms.firstIndex(where: { $0.source == term.source }) {
                if terms[index].target != term.target {
                    terms[index].target = term.target
                    updated += 1
                }
            } else {
                terms.append(term)
                added += 1
            }
        }
        return (terms, added, updated)
    }
}
