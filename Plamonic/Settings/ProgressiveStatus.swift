import Foundation

/// Why 段階翻訳 cannot run as configured right now. The Models pane shows it under the switch,
/// so the user is not left wondering why no draft appears.
enum ProgressiveIssue: Equatable, Sendable {
    /// Nothing is smaller than the final model, so there is no draft stage.
    case finalIsSmallest(final: ModelSize)
    /// The draft model is not on disk yet (or still downloading): the final model translates alone.
    case draftNotInstalled(draft: ModelSize, final: ModelSize, downloading: Bool)
    /// Only the draft model is on disk: drafts are shown and never replaced.
    case finalNotInstalled(draft: ModelSize, final: ModelSize, downloading: Bool)

    /// Japanese explanation for the settings UI.
    var message: String {
        switch self {
        case .finalIsSmallest(let final):
            return "翻訳モデルが最も小さい \(final.displayName) なので、段階翻訳は使われず \(final.displayName) だけで訳します。翻訳モデルを大きくすると使えます。"
        case .draftNotInstalled(let draft, let final, let downloading):
            return downloading
                ? "下書きモデル（\(draft.displayName)）をダウンロードしています。終わるまでは翻訳モデル（\(final.displayName)）だけで訳します。"
                : "下書きモデル（\(draft.displayName)）がダウンロードされていないため、翻訳モデル（\(final.displayName)）だけで訳します。下の一覧からダウンロードすると段階翻訳が始まります。"
        case .finalNotInstalled(let draft, let final, let downloading):
            let reason = downloading ? "をダウンロードしている間" : "がダウンロードされていないため"
            return "翻訳モデル（\(final.displayName)）\(reason)は、下書きモデル（\(draft.displayName)）だけで訳します。下書きは仕上げに差し替わりません。"
        }
    }
}

enum ProgressiveStatus {
    /// The first reason 段階翻訳 cannot run as configured, or nil when it runs (or is not used at all).
    /// Mirrors how the translation plan picks models: a draft that is missing or not smaller than the
    /// final model means single stage, a missing final model means drafts only.
    static func issue(
        global: GlobalSettings, isInstalled: (ModelSize) -> Bool, isDownloading: (ModelSize) -> Bool = { _ in false }
    ) -> ProgressiveIssue? {
        let final = global.finalModel
        let draft = global.progressive.draftModel
        if SettingsNormalizer.draftChoices(below: final).isEmpty { return .finalIsSmallest(final: final) }
        // Normalized settings always have a smaller draft; anything else is single stage without a note.
        guard SettingsNormalizer.isSmaller(draft, than: final) else { return nil }
        let draftInstalled = isInstalled(draft)
        let finalInstalled = isInstalled(final)
        if !draftInstalled, finalInstalled {
            return .draftNotInstalled(draft: draft, final: final, downloading: isDownloading(draft))
        }
        if draftInstalled, !finalInstalled {
            return .finalNotInstalled(draft: draft, final: final, downloading: isDownloading(final))
        }
        // Neither installed: the final model's own "not downloaded" note covers it.
        return nil
    }

    /// Models the app may load: the final model, plus the draft model when two stages can run for some app.
    static func modelsInUse(_ snapshot: SettingsSnapshot) -> [ModelSize] {
        let global = snapshot.global
        let draft = global.progressive.draftModel
        guard snapshot.isProgressiveInUse, SettingsNormalizer.isSmaller(draft, than: global.finalModel) else {
            return [global.finalModel]
        }
        return [draft, global.finalModel]
    }
}
