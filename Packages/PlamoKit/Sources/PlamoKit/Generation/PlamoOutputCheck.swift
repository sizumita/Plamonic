import Foundation

/// Heuristics for outputs that are clearly not a translation of the input
/// (the model echoing history, continuing the conversation, or looping).
public enum PlamoOutputCheck {
    public static func looksWrong(input: String, output: String, targetLanguage: String) -> Bool {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOutput.isEmpty { return !trimmedInput.isEmpty }

        let inputCount = trimmedInput.count
        if trimmedOutput.count > 3 * inputCount + 200 { return true }

        if targetLanguage == "ja" || targetLanguage == "ja(easy)" {
            let inputLatin = latinLetterCount(trimmedInput)
            let outputJapanese = japaneseCharacterCount(trimmedOutput)
            // A long Latin-script input translated to Japanese must contain some Japanese.
            if inputLatin >= 24, outputJapanese == 0, latinLetterCount(trimmedOutput) > 0 {
                return true
            }
        }
        return false
    }

    static func latinLetterCount(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { n, u in
            switch u.value {
            case 0x41 ... 0x5A, 0x61 ... 0x7A, 0xC0 ... 0x24F: n + 1
            default: n
            }
        }
    }

    static func japaneseCharacterCount(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { n, u in
            switch u.value {
            case 0x3040 ... 0x30FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF, 0xFF66 ... 0xFF9F: n + 1
            default: n
            }
        }
    }
}
