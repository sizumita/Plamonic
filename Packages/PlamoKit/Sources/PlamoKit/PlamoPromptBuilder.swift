// Builds the prompts of chat_template.jinja from the PLaMo 3 Translate model repositories.
// See THIRD_PARTY_NOTICES.md.

import Foundation

/// Builds the PFML3 prompt exactly like the model's `chat_template.jinja`
/// (with `add_generation_prompt=True` and `bos_token = "<|plamo:bos|>"`).
public enum PlamoPromptBuilder {
    static let bos = "<|plamo:bos|>"
    static let reserved = "<|plamo:"

    /// Validates the request with the template's rules and returns the prompt text.
    /// Throws `PlamoError.invalidRequest` for empty text, bad language codes, a `form` without
    /// `targetLanguage == "ja"`, or any user string containing `<|plamo:`.
    public static func prompt(for request: PlamoTranslationRequest) throws -> String {
        for pair in request.history {
            try checkText(pair.source, "message content")
            try checkText(pair.translation, "message content")
        }
        try checkText(request.text, "message content")
        try checkLanguage(request.targetLanguage, "target_lang")
        if let source = request.sourceLanguage {
            try checkLanguage(source, "source_lang")
        }
        if let context = request.context {
            try checkText(context, "context", allowEmpty: true)
        }
        if let form = request.form {
            guard form == "polite" || form == "plain", request.targetLanguage == "ja" else {
                throw PlamoError.invalidRequest("form must be polite or plain and requires target_lang=\"ja\".")
            }
        }
        for term in request.glossary {
            try checkText(term.source, "glossary source")
            try checkText(term.target, "glossary target")
        }

        var out = bos + "<|plamo:tag|>dataset<|plamo:msg|>translation"
        if let context = request.context, !context.isEmpty {
            out += "<|plamo:tag|>context<|plamo:msg|>" + context
        }
        let sourceKey = request.sourceLanguage.map { "<|plamo:key|>lang<|plamo:val|>" + $0 } ?? ""
        for pair in request.history {
            out += "<|plamo:tag|>input" + sourceKey + "<|plamo:msg|>" + pair.source
            out += "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>" + request.targetLanguage
            out += "<|plamo:msg|>" + pair.translation
        }
        if !request.glossary.isEmpty {
            out += "<|plamo:tag|>glossary"
            for term in request.glossary {
                out += "<|plamo:index|>" + term.source + "<|plamo:item|>" + term.target
            }
        }
        out += "<|plamo:tag|>input" + sourceKey
        out += "<|plamo:msg|>" + request.text + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>"
        out += request.targetLanguage
        if let form = request.form {
            out += "<|plamo:key|>form<|plamo:val|>" + form
        }
        out += "<|plamo:msg|>"
        return out
    }

    /// true when `code` is accepted by the template as a language code.
    public static func isValidLanguageCode(_ code: String) -> Bool {
        (try? checkLanguage(code, "lang")) != nil
    }

    static func checkText(_ value: String, _ name: String, allowEmpty: Bool = false) throws {
        if !allowEmpty, value.unicodeScalars.allSatisfy({ PlamoTokenizer.isPythonWhitespace($0.value) }) {
            throw PlamoError.invalidRequest("\(name) must not be empty.")
        }
        if containsReservedMarker(value) {
            throw PlamoError.invalidRequest("\(name) must not contain reserved PFML tokens (<|plamo:...).")
        }
    }

    /// Code-point search (String.contains matches whole Characters, so a combining mark after
    /// the ":" would hide the marker).
    public static func containsReservedMarker(_ value: String) -> Bool {
        let needle = Array(reserved.unicodeScalars)
        let hay = Array(value.unicodeScalars)
        guard hay.count >= needle.count else { return false }
        for i in 0 ... hay.count - needle.count where hay[i] == needle[0] {
            if hay[i ..< i + needle.count].elementsEqual(needle) { return true }
        }
        return false
    }

    static func checkLanguage(_ value: String, _ name: String) throws {
        try checkText(value, name)
        guard value != "ja(easy)" else { return }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        let first = parts[0].unicodeScalars.count
        if parts.count > 2 || !(first == 2 || first == 3) || (parts.count == 2 && parts[1].unicodeScalars.count != 4) {
            throw PlamoError.invalidRequest(
                "\(name) must be a lowercase language code, e.g. en, ja, zh-hans, or ja(easy).")
        }
        for scalar in value.unicodeScalars where !(("a" ... "z").contains(scalar) || scalar == "-") {
            throw PlamoError.invalidRequest("\(name) must use lowercase language codes without region subtags.")
        }
    }
}
