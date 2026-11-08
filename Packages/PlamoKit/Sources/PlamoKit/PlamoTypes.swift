import Foundation

/// PLaMo 3 Translate MLX-4bit models: the sizes published by PFN, plus a compact 0.8B.
public enum PlamoModelVariant: String, CaseIterable, Sendable, Codable, Hashable {
    case b0_8 = "0.8b"
    /// An unofficial mlx-lm conversion of the 0.8B that also quantizes embed_tokens and lm_head:
    /// about half the memory of `b0_8`, with nearly the same translations.
    case b0_8Compact = "0.8b-compact"
    case b2 = "2b"
    case b8 = "8b"
    case b31 = "31b"

    /// Hugging Face repository, e.g. `pfnet/plamo-3-translate-2b-MLX-4bit`.
    public var repoID: String {
        switch self {
        case .b0_8Compact: "sizumita/plamo-3-translate-0.8b-mlx-4bit-compact"
        default: "pfnet/plamo-3-translate-\(rawValue)-MLX-4bit"
        }
    }

    public var displayName: String {
        switch self {
        case .b0_8: "0.8B"
        case .b0_8Compact: "0.8B 軽量版"
        case .b2: "2B"
        case .b8: "8B"
        case .b31: "31B"
        }
    }

    /// Approximate size of the downloadable files in bytes.
    public var approximateDownloadBytes: Int64 {
        switch self {
        case .b0_8: 980_000_000
        case .b0_8Compact: 505_000_000
        case .b2: 2_415_000_000
        case .b8: 6_070_000_000
        case .b31: 18_660_000_000
        }
    }
}

public struct PlamoGlossaryEntry: Hashable, Sendable, Codable {
    public var source: String
    public var target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

/// A previous source text and its translation, sent as conversation history.
public struct PlamoHistoryPair: Hashable, Sendable, Codable {
    public var source: String
    public var translation: String

    public init(source: String, translation: String) {
        self.source = source
        self.translation = translation
    }
}

public struct PlamoTranslationRequest: Hashable, Sendable, Codable {
    public var text: String
    /// PLaMo language code: "ja", "en", "zh-hans", "ja(easy)", ...
    public var targetLanguage: String
    /// nil lets the model detect the source language.
    public var sourceLanguage: String?
    /// Free text describing the situation (PFML3 `context`). Empty or nil = none.
    public var context: String?
    public var glossary: [PlamoGlossaryEntry]
    /// "plain" or "polite"; only valid when `targetLanguage == "ja"`.
    public var form: String?
    public var history: [PlamoHistoryPair]
    /// nil = `min(1024, 3 * text.count + 64)`.
    public var maxNewTokens: Int?

    public init(
        text: String,
        targetLanguage: String,
        sourceLanguage: String? = nil,
        context: String? = nil,
        glossary: [PlamoGlossaryEntry] = [],
        form: String? = nil,
        history: [PlamoHistoryPair] = [],
        maxNewTokens: Int? = nil
    ) {
        self.text = text
        self.targetLanguage = targetLanguage
        self.sourceLanguage = sourceLanguage
        self.context = context
        self.glossary = glossary
        self.form = form
        self.history = history
        self.maxNewTokens = maxNewTokens
    }

    /// Generation budget actually used for this request.
    public var effectiveMaxNewTokens: Int {
        if let maxNewTokens, maxNewTokens > 0 { return maxNewTokens }
        return min(1024, 3 * text.count + 64)
    }
}

public struct PlamoTimings: Hashable, Sendable, Codable {
    /// Time spent loading the model for this call (0 when it was already loaded).
    public var load: TimeInterval = 0
    public var tokenize: TimeInterval = 0
    /// Prompt processing up to the first generated token.
    public var prefill: TimeInterval = 0
    public var decode: TimeInterval = 0
    public var total: TimeInterval = 0

    public init() {}
}

public struct PlamoTranslationResult: Hashable, Sendable {
    public var text: String
    public var promptTokens: Int
    /// Prompt tokens whose KV cache was reused from the previous request.
    public var reusedPromptTokens: Int
    public var generatedTokens: Int
    /// true when generation stopped at `maxNewTokens` instead of a stop token.
    public var hitTokenLimit: Bool
    /// true when the first output looked wrong and the request was retried without history/context.
    public var retriedWithoutHistory: Bool
    /// true when the returned output still looks like it is not a translation.
    public var looksWrong: Bool
    public var timings: PlamoTimings

    public init(
        text: String, promptTokens: Int, reusedPromptTokens: Int, generatedTokens: Int, hitTokenLimit: Bool,
        retriedWithoutHistory: Bool, looksWrong: Bool, timings: PlamoTimings
    ) {
        self.text = text
        self.promptTokens = promptTokens
        self.reusedPromptTokens = reusedPromptTokens
        self.generatedTokens = generatedTokens
        self.hitTokenLimit = hitTokenLimit
        self.retriedWithoutHistory = retriedWithoutHistory
        self.looksWrong = looksWrong
        self.timings = timings
    }
}

public enum PlamoError: Error, LocalizedError, Sendable {
    case modelNotInstalled(PlamoModelVariant)
    case invalidModel(String)
    case invalidRequest(String)
    case downloadFailed(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let variant): "PLaMo \(variant.displayName) モデルがインストールされていません。"
        case .invalidModel(let reason): "モデルファイルを読み込めません: \(reason)"
        case .invalidRequest(let reason): "翻訳リクエストが不正です: \(reason)"
        case .downloadFailed(let reason): "モデルのダウンロードに失敗しました: \(reason)"
        case .inferenceFailed(let reason): "翻訳中にエラーが発生しました: \(reason)"
        }
    }
}
