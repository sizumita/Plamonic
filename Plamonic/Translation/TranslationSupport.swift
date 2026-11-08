import Foundation

/// Which installed models the coordinator actually uses for the current settings.
struct TranslationModelPlan: Equatable, Sendable {
    /// First-stage model (nil = single stage).
    var draft: ModelSize?
    /// Second-stage model (nil when the configured final model is not installed).
    var final: ModelSize?
    var configuredDraft: ModelSize?
    var configuredFinal: ModelSize

    var hasModel: Bool { draft != nil || final != nil }
    var isTwoStage: Bool { draft != nil && final != nil }
    /// Only the draft model is available, so no "final" upgrade will follow.
    var isDraftOnly: Bool { draft != nil && final == nil }
    /// Model whose translations count as the finished result (used for history).
    var resultModel: ModelSize? { final ?? draft }
    /// Models that can produce the first translation of a text.
    var firstStageModels: [ModelSize] { [draft, final].compactMap { $0 } }

    /// - draftModel nil, equal to the final model, or not installed: single stage with the final model.
    /// - final model not installed but the draft model is: draft only.
    /// The plan for one app: its 段階翻訳 override decides whether the draft model is used.
    static func make(settings: EffectiveSettings, isInstalled: (ModelSize) -> Bool) -> TranslationModelPlan {
        var global = settings.global
        global.draftModel = settings.draftModel
        return make(global: global, isInstalled: isInstalled)
    }

    static func make(global: GlobalSettings, isInstalled: (ModelSize) -> Bool) -> TranslationModelPlan {
        let finalInstalled = isInstalled(global.finalModel)
        var draft: ModelSize? = nil
        // The settings normalizer keeps the draft smaller, but a hand-edited file may not:
        // a draft as large as the final model would only add a slower second pass.
        if let configured = global.draftModel, isSmaller(configured, than: global.finalModel),
            isInstalled(configured)
        {
            draft = configured
        }
        return TranslationModelPlan(
            draft: draft, final: finalInstalled ? global.finalModel : nil,
            configuredDraft: global.draftModel, configuredFinal: global.finalModel)
    }

    private static func isSmaller(_ a: ModelSize, than b: ModelSize) -> Bool {
        a.rank < b.rank
    }

    /// User-facing explanation when the configured models cannot all be used (Japanese).
    var notice: String? {
        if !hasModel {
            return "翻訳モデル（\(configuredFinal.displayName)）がインストールされていません。設定の「モデル」からダウンロードしてください。"
        }
        if let draft, final == nil {
            return "仕上げモデル（\(configuredFinal.displayName)）がインストールされていないため、下書きモデル（\(draft.displayName)）だけで翻訳しています。"
        }
        if let configuredDraft, Self.isSmaller(configuredDraft, than: configuredFinal), draft == nil {
            return "下書きモデル（\(configuredDraft.displayName)）がインストールされていないため、\(configuredFinal.displayName) だけで翻訳しています。"
        }
        return nil
    }
}

/// Snapshot of the coordinator's work, for the menu bar / status UI.
struct TranslationActivity: Equatable, Sendable {
    var plan: TranslationModelPlan?
    /// Model of the backend call in progress.
    var runningModel: ModelSize?
    /// Distinct texts still waiting for a draft or final translation.
    var remainingJobs: Int = 0
    /// Last backend error message (cleared by the next success).
    var lastError: String?
    /// 混雑時の一時停止: the final stage of the app the status describes (the frontmost one when tracked) is
    /// paused because a lot of new text keeps arriving in it.
    var refinementPaused: Bool = false

    var isBusy: Bool { runningModel != nil }
    /// Status line for the menu while the final stage is paused (nil otherwise).
    var refinementPauseNotice: String? { refinementPaused ? "仕上げを一時停止中（新しい文章が多いため）" : nil }
}

/// Collects partial results from any thread and delivers the newest one on the main actor
/// at most once per `interval`. The first partial is delivered right away.
final class PartialRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: Duration
    private let deliver: @MainActor (String) -> Void
    private var latest: String?
    private var flushScheduled = false
    private var lastDelivery: ContinuousClock.Instant?
    private var cancelled = false

    init(interval: TimeInterval, deliver: @escaping @MainActor (String) -> Void) {
        self.interval = .milliseconds(Int64(max(0, interval) * 1000))
        self.deliver = deliver
    }

    func push(_ text: String) {
        var delay: Duration?
        lock.lock()
        if !cancelled {
            latest = text
            if !flushScheduled {
                flushScheduled = true
                let now = ContinuousClock.now
                if let lastDelivery, now - lastDelivery < interval {
                    delay = interval - (now - lastDelivery)
                } else {
                    delay = .zero
                }
            }
        }
        lock.unlock()
        guard let delay else { return }
        Task { @MainActor [self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            self.flush()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        latest = nil
        lock.unlock()
    }

    @MainActor private func flush() {
        lock.lock()
        let text = cancelled ? nil : latest
        latest = nil
        flushScheduled = false
        lastDelivery = ContinuousClock.now
        lock.unlock()
        if let text { deliver(text) }
    }
}

/// Request-building helpers shared by the coordinator and its tests.
enum TranslationRequestFactory {
    /// "plain" / "polite" only for target "ja" with a fixed form.
    static func form(targetLanguage: String, setting: JapaneseFormSetting) -> String? {
        guard targetLanguage.lowercased() == "ja" else { return nil }
        switch setting {
        case .auto: return nil
        case .plain: return "plain"
        case .polite: return "polite"
        }
    }

    /// Glossary terms with sanitized one-line values. Terms with an empty source or target are dropped:
    /// PLaMo rejects an empty glossary target, so one unfinished term would fail every text containing it.
    static func sanitizedGlossary(_ terms: [GlossaryTerm]) -> [GlossaryTerm] {
        terms.compactMap { term in
            let source = TextSanitizer.singleLine(term.source, maxLength: 200)
            let target = TextSanitizer.singleLine(term.target, maxLength: 200)
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            var copy = term
            copy.source = source
            copy.target = target
            return copy
        }
    }

    /// Only the terms whose source occurs in `text` are sent; unrelated terms would only slow
    /// prefill and needlessly invalidate cached translations when the glossary grows.
    static func relevantGlossary(_ terms: [GlossaryTerm], for text: String) -> [GlossaryTerm] {
        guard !terms.isEmpty else { return [] }
        return terms.filter { text.range(of: $0.source, options: [.caseInsensitive]) != nil }
    }

    static func maxNewTokens(for text: String) -> Int {
        min(4096, max(64, text.count * 2 + 128))
    }

    /// Keeps the most recent pairs whose combined length fits `limit` characters (oldest first).
    static func trimHistory(_ pairs: [TranslationHistoryPair], limit: Int) -> [TranslationHistoryPair] {
        var kept: [TranslationHistoryPair] = []
        var total = 0
        for pair in pairs.reversed() {
            let size = pair.source.count + pair.translation.count
            if total + size > limit { break }
            total += size
            kept.append(pair)
        }
        return kept.reversed()
    }

    /// Heuristics from plamo-ja: an untranslated echo or a runaway generation.
    static func looksWrong(source: String, translation: String, targetLanguage: String) -> Bool {
        if translation.isEmpty { return true }
        if translation.count > source.count * 3 + 200 { return true }
        if LanguageDetector.baseCode(targetLanguage) == "ja" {
            let sourceProfile = LanguageDetector.ScriptProfile(source)
            let outputProfile = LanguageDetector.ScriptProfile(translation)
            if sourceProfile.latin >= 40 && outputProfile.kana + outputProfile.han < 5 { return true }
        }
        return false
    }
}
