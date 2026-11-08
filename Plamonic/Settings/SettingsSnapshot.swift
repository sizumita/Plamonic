import Foundation

/// Where the profile used for an app comes from.
enum ProfileSource: String, Sendable {
    case user  // stored in settings.json (created or edited by the user)
    case preset  // built-in preset, never edited
    case defaults  // unknown app: built from GlobalSettings.defaultMode / defaultScope
}

/// An immutable copy of the settings. Value type, safe to hand to background queues.
struct SettingsSnapshot: Equatable, Sendable {
    var document: SettingsDocument

    init(document: SettingsDocument = SettingsDocument()) {
        self.document = document
    }

    var global: GlobalSettings { document.global }

    /// The stored (user) profile for an app, if any. Bundle IDs are matched case-insensitively.
    func userProfile(for bundleID: String) -> AppProfile? {
        document.profiles.last { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    func profileSource(for bundleID: String) -> ProfileSource {
        if userProfile(for: bundleID) != nil { return .user }
        if AppPresets.preset(for: bundleID) != nil { return .preset }
        return .defaults
    }

    /// Apps whose profile (stored, or a preset the user has not edited) sets 段階翻訳 to `value`
    /// instead of following the global switch, sorted by name.
    func appsOverridingProgressive(to value: Bool) -> [AppProfile] {
        appProfiles { $0.progressiveOverride == value }
    }

    /// Apps whose profile (stored, or a preset the user has not edited) sets the display style to `style`
    /// instead of following the global one, sorted by name.
    func appsOverridingDisplayStyle(to style: DisplayStyle) -> [AppProfile] {
        appProfiles { $0.displayStyleOverride == style }
    }

    /// Whether any app may draw translations over the original: the global style is 置き換え, or an app
    /// chooses it for itself. The pointer and link settings (`GlobalSettings.interaction`) matter only then.
    var isReplaceStyleInUse: Bool {
        global.displayStyle == .replace || !appsOverridingDisplayStyle(to: .replace).isEmpty
    }

    /// Stored profiles and unedited presets that satisfy `predicate`, sorted by name.
    private func appProfiles(where predicate: (AppProfile) -> Bool) -> [AppProfile] {
        var apps = document.profiles.filter(predicate)
        for preset in AppPresets.all where userProfile(for: preset.bundleID) == nil && predicate(preset.profile) {
            apps.append(preset.profile)
        }
        return apps.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Whether any app may translate in two stages: the global switch is on, or an app turns it on for itself.
    /// The draft model and burst control settings matter only then.
    var isProgressiveInUse: Bool {
        global.progressive.isEnabled || !appsOverridingProgressive(to: true).isEmpty
    }

    /// Resolution order: user profile -> preset -> default profile from the global settings.
    func profile(for bundleID: String, appName: String? = nil) -> AppProfile {
        if let user = userProfile(for: bundleID) { return user }
        if let preset = AppPresets.preset(for: bundleID) { return preset.profile }
        return Self.defaultProfile(bundleID: bundleID, appName: appName, global: global)
    }

    func effectiveSettings(bundleID: String, appName: String? = nil) -> EffectiveSettings {
        EffectiveSettings(profile: profile(for: bundleID, appName: appName), global: global)
    }

    /// The profile used for apps without a preset or a user profile.
    static func defaultProfile(bundleID: String, appName: String?, global: GlobalSettings) -> AppProfile {
        let name = appName.flatMap { $0.isEmpty ? nil : $0 } ?? bundleID
        var profile = AppProfile(bundleID: bundleID, displayName: name)
        profile.mode = global.defaultMode
        profile.scope = global.defaultScope
        return profile
    }
}

/// Allowed ranges for numeric settings. The settings UI uses the same bounds.
enum SettingsLimits {
    static let backgroundOpacity: ClosedRange<Double> = 0.3...1.0
    static let fontSize: ClosedRange<Double> = 6...48
    /// Overlays never draw a rounder corner than 2 pt (OverlayLayout.maximumCornerRadius), so a larger
    /// value would change nothing on screen.
    static let cornerRadius: ClosedRange<Double> = 0...2
    static let scanInterval: ClosedRange<Double> = 0.1...5
    static let backgroundScanInterval: ClosedRange<Double> = 0.5...30
    static let maxSegmentsPerScan: ClosedRange<Int> = 5...500
    static let maxSegmentCharacters: ClosedRange<Int> = 100...10_000
    static let minTextLength: ClosedRange<Int> = 1...50
    /// 0 = never unload.
    static let idleUnloadMinutes: ClosedRange<Int> = 0...1_440
    /// The cache also holds what is on screen (two models x up to 500 segments per window), so a tiny
    /// capacity would evict visible translations and re-translate them forever (the coordinator also
    /// raises the effective capacity above what is shown). The upper bound keeps each rewrite of the
    /// cache file, which re-encodes every entry, reasonably small.
    static let cacheCapacity: ClosedRange<Int> = 1_000...50_000
    /// 混雑時の一時停止: how many new texts at once pause the final stage. Below 3 an ordinary new message
    /// would pause it; above 40 it would hardly ever pause.
    static let burstThreshold: ClosedRange<Int> = 3...40
    /// 混雑時の一時停止: how long the flow of new text must stay quiet before the final stage resumes.
    static let burstQuietSeconds: ClosedRange<Double> = 0.5...10
    /// ポインタを置いたとき: how long the pointer rests on a translation before the original shows.
    /// Shorter flickers while the pointer crosses text; longer feels unresponsive.
    static let hoverDelay: ClosedRange<Double> = 0.1...1.5
}

/// Brings loaded or edited values back into valid ranges.
enum SettingsNormalizer {
    static func normalized(_ document: SettingsDocument) -> SettingsDocument {
        var doc = document
        doc.global = normalized(doc.global)
        // One profile per bundle ID; the last one wins (matches userProfile(for:)).
        var seen = Set<String>()
        var profiles: [AppProfile] = []
        for profile in doc.profiles.reversed() where !profile.bundleID.isEmpty {
            if seen.insert(profile.bundleID.lowercased()).inserted {
                profiles.append(normalized(profile))
            }
        }
        doc.profiles = profiles.reversed()
        return doc
    }

    static func normalized(_ global: GlobalSettings) -> GlobalSettings {
        var g = global
        if !LanguageCatalog.isValidTarget(g.targetLanguage) { g.targetLanguage = GlobalSettings().targetLanguage }
        if let source = g.sourceLanguage, !LanguageCatalog.isValidSource(source) { g.sourceLanguage = nil }
        g.progressive = normalized(g.progressive, finalModel: g.finalModel)

        var a = g.appearance
        a.backgroundOpacity = clamp(a.backgroundOpacity, SettingsLimits.backgroundOpacity)
        a.minFontSize = clamp(a.minFontSize, SettingsLimits.fontSize)
        a.maxFontSize = clamp(a.maxFontSize, a.minFontSize...SettingsLimits.fontSize.upperBound)
        a.cornerRadius = clamp(a.cornerRadius, SettingsLimits.cornerRadius)
        g.appearance = a
        g.interaction = normalized(g.interaction)

        g.scanInterval = clamp(g.scanInterval, SettingsLimits.scanInterval)
        g.backgroundScanInterval = clamp(g.backgroundScanInterval, SettingsLimits.backgroundScanInterval)
        g.maxSegmentsPerScan = clamp(g.maxSegmentsPerScan, SettingsLimits.maxSegmentsPerScan)
        g.maxSegmentCharacters = clamp(g.maxSegmentCharacters, SettingsLimits.maxSegmentCharacters)
        g.minTextLength = clamp(g.minTextLength, SettingsLimits.minTextLength)
        g.idleUnloadMinutes = clamp(g.idleUnloadMinutes, SettingsLimits.idleUnloadMinutes)
        g.cacheCapacity = clamp(g.cacheCapacity, SettingsLimits.cacheCapacity)
        return g
    }

    /// The draft model must be smaller than the final model, otherwise two-stage translation is pointless.
    /// A draft that is not smaller becomes the largest smaller size, so lowering the final model keeps
    /// 段階翻訳 working; when the final model is already the smallest, the draft becomes that same size
    /// (single stage) until the final model grows again. The on/off switch is never changed here.
    static func normalized(
        _ progressive: ProgressiveTranslationSettings, finalModel: ModelSize
    ) -> ProgressiveTranslationSettings {
        var p = progressive
        if !isSmaller(p.draftModel, than: finalModel) {
            // the official model when two sizes share the largest rank
            let choices = draftChoices(below: finalModel)
            p.draftModel = choices.first { $0.rank == choices.last?.rank } ?? ModelSize.allCases[0]
        }
        p.burstControl.threshold = clamp(p.burstControl.threshold, SettingsLimits.burstThreshold)
        p.burstControl.quietSeconds = clamp(p.burstControl.quietSeconds, SettingsLimits.burstQuietSeconds)
        return p
    }

    /// The delay is kept in range and rounded to hundredths, so 0.1 s steps do not store 0.7999999999999999.
    static func normalized(_ interaction: OverlayInteractionSettings) -> OverlayInteractionSettings {
        var i = interaction
        i.hoverDelay = (clamp(i.hoverDelay, SettingsLimits.hoverDelay) * 100).rounded() / 100
        return i
    }

    /// Sizes that can be the draft model for `finalModel`, smallest first.
    static func draftChoices(below finalModel: ModelSize) -> [ModelSize] {
        ModelSize.allCases.filter { isSmaller($0, than: finalModel) }
    }

    static func normalized(_ profile: AppProfile) -> AppProfile {
        var p = profile
        if let target = p.targetLanguageOverride, !LanguageCatalog.isValidTarget(target) {
            p.targetLanguageOverride = nil
        }
        if let minLength = p.minTextLengthOverride {
            p.minTextLengthOverride = clamp(minLength, SettingsLimits.minTextLength)
        }
        if p.displayName.isEmpty { p.displayName = p.bundleID }
        return p
    }

    static func isSmaller(_ a: ModelSize, than b: ModelSize) -> Bool {
        a.rank < b.rank
    }

    private static func clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
    }
}
