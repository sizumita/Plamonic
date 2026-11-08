import Foundation

// Shared settings types. Every module reads these; only the Settings module writes them.
// Decoding is lenient: missing keys fall back to defaults so old settings files keep loading.

enum ModelSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case b0_8 = "0.8b"
    /// An unofficial conversion of the 0.8B with every layer quantized: about half the memory.
    case b0_8Compact = "0.8b-compact"
    case b2 = "2b"
    case b8 = "8b"
    case b31 = "31b"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .b0_8: "0.8B"
        case .b0_8Compact: "0.8B 軽量版"
        case .b2: "2B"
        case .b8: "8B"
        case .b31: "31B"
        }
    }

    var repoID: String {
        switch self {
        case .b0_8Compact: "sizumita/plamo-3-translate-0.8b-mlx-4bit-compact"
        default: "pfnet/plamo-3-translate-\(rawValue)-MLX-4bit"
        }
    }

    /// Published by PFN. The others are conversions by someone else.
    var isOfficial: Bool { self != .b0_8Compact }

    /// Parameter count order. Sizes of the same rank are the same model, so neither is smaller
    /// than the other (段階翻訳 needs a smaller draft model).
    var rank: Int {
        switch self {
        case .b0_8, .b0_8Compact: 0
        case .b2: 1
        case .b8: 2
        case .b31: 3
        }
    }

    /// Approximate download size of the MLX-4bit weights.
    var approxDownloadGB: Double {
        switch self {
        case .b0_8: 0.98
        case .b0_8Compact: 0.51
        case .b2: 2.41
        case .b8: 6.07
        case .b31: 18.66
        }
    }

    /// Rough unified memory recommended to run this size comfortably.
    var recommendedMemoryGB: Int {
        switch self {
        case .b0_8, .b0_8Compact: 8
        case .b2: 8
        case .b8: 16
        case .b31: 48
        }
    }
}

enum TranslationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off        // never translate this app
    case automatic  // translate in real time
    case manual     // translate only when the "translate now" hotkey is pressed
    var id: String { rawValue }
}

enum TranslationScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case window          // all text in the focused window
    case rules           // only elements matched by the profile's extraction rules
    case focusedElement  // the focused UI element and its subtree
    case underMouse      // the text block under the mouse pointer
    case selection       // the selected text
    var id: String { rawValue }
}

enum SegmentGranularity: String, Codable, CaseIterable, Identifiable, Sendable {
    case paragraph  // merge inline runs (text + links) under their common block parent
    case element    // one segment per text element
    case item       // one segment per matched rule item (all text inside it joined)
    var id: String { rawValue }
}

/// How text areas (AXTextArea / AXTextField values) are split into segments.
enum TextAreaHandling: String, Codable, CaseIterable, Identifiable, Sendable {
    case whole  // the whole value is one segment over the whole element
    case paragraphs  // split by blank lines / newlines; frames from AXBoundsForRange
    case terminal  // terminal screen: visible range only, rejoin wrapped lines, drop TUI borders and spinners
    var id: String { rawValue }
}

enum DisplayStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case replace  // draw the translation over the original text
    case hover    // show the translation of the block under the mouse in a popup
    var id: String { rawValue }
}

enum JapaneseFormSetting: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, plain, polite
    var id: String { rawValue }
}

enum SameLanguagePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case skip       // leave text that is already in the target language alone
    case translate  // translate it anyway (e.g. to "ja(easy)" or to unify the style)
    var id: String { rawValue }
}

enum ModifierKey: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, option, control, command, shift, function
    var id: String { rawValue }
}

enum OverlayTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
}

struct GlossaryTerm: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var source: String
    var target: String

    init(id: UUID = UUID(), source: String, target: String) {
        self.id = id
        self.source = source
        self.target = target
    }

    // Hand-edited files may omit "id"; a fresh one is assigned.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = try c.decode(String.self, forKey: .source)
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case id, source, target }

    /// Both sides have text. A term without a target is unfinished and is never sent to PLaMo.
    var isUsable: Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A global hotkey: Carbon virtual key code + Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
struct HotkeySpec: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
}

/// Matches an AX element. Every non-empty field must match; within a field any value may match.
struct ElementMatcher: Codable, Hashable, Sendable {
    var roles: [String] = []
    var subroles: [String] = []
    var roleDescriptions: [String] = []
    var domClassPrefixes: [String] = []
    var identifierPrefixes: [String] = []

    var isEmpty: Bool {
        roles.isEmpty && subroles.isEmpty && roleDescriptions.isEmpty && domClassPrefixes.isEmpty
            && identifierPrefixes.isEmpty
    }
}

struct ExtractionRules: Codable, Hashable, Sendable {
    /// Subtrees to search in. Empty = the whole window.
    var containers: [ElementMatcher] = []
    /// Elements that form one translation unit each. Empty = use the granularity heuristics.
    var items: [ElementMatcher] = []
    /// Subtrees to skip entirely (code blocks, timestamps, sidebars, ...).
    var excludes: [ElementMatcher] = []
}

struct OverlayAppearance: Codable, Hashable, Sendable {
    var theme: OverlayTheme = .system
    var backgroundOpacity: Double = 1.0
    /// Font size range used when the original text size is unknown (and as the floor when shrinking).
    var minFontSize: Double = 9
    var maxFontSize: Double = 16
    var showStateIndicator: Bool = true
    /// At most 2 pt (OverlayLayout.maximumCornerRadius, SettingsLimits.cornerRadius): rounder reads as a card.
    var cornerRadius: Double = 2
    /// Draw the translation in the original text's size, line spacing and color when the app reports them,
    /// so it reads as if the app itself showed it.
    var matchOriginalStyle: Bool = true
    /// Take the background (and text) color from the target window's own pixels.
    /// Needs Screen Recording permission; without it the theme colors are used.
    var matchBackgroundFromScreen: Bool = true
}

/// 段階翻訳: a small draft model translates first and shows at once, then the final model
/// (`GlobalSettings.finalModel`) translates again and replaces the draft.
struct ProgressiveTranslationSettings: Codable, Hashable, Sendable {
    var isEnabled: Bool = true
    /// Must be smaller than the final model; otherwise translation is single-stage.
    var draftModel: ModelSize = .b0_8
    var burstControl: BurstControlSettings = BurstControlSettings()
}

/// 混雑時の一時停止: while a lot of new text keeps arriving (fast scrolling, a flood of messages),
/// the final stage pauses so drafts keep up; it resumes once the flow stops or slows down.
struct BurstControlSettings: Codable, Hashable, Sendable {
    var isEnabled: Bool = true
    /// Pause the final stage when at least this many on-screen texts are waiting for their first
    /// translation, or when at least this many new untranslated texts appeared within the last 2 seconds.
    var threshold: Int = 8
    /// Resume when, for this long, at most one new text arrived and every on-screen text has a draft.
    var quietSeconds: Double = 1.5
}

/// What resting the pointer on a translation drawn over the original (replace style) shows.
enum HoverOriginalMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The translation fades out where it is drawn, so the original itself shows through (its links work).
    case inPlace
    /// The original appears in a small popup next to the text; the translation stays.
    case popup
    case off
    var id: String { rawValue }
}

/// Pointer and click behaviour of translations drawn over the original (replace style). DESIGN §6.1.
struct OverlayInteractionSettings: Codable, Hashable, Sendable {
    var hoverOriginal: HoverOriginalMode = .popup
    /// Seconds the pointer must rest on a translation, after moving onto it, before the original shows.
    var hoverDelay: Double = 0.4
    /// Links in a translation are drawn as links and can be clicked (they open what the original link opens),
    /// and a click on translated text never reaches an original link hidden under it.
    var clickableLinks: Bool = true
}

// Lenient decoding for the nested settings types: a hand-edited file or one written before a field
// existed keeps its other values. The decoders live in extensions so the memberwise initialisers stay.

extension ElementMatcher {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roles = try c.decodeIfPresent([String].self, forKey: .roles) ?? []
        subroles = try c.decodeIfPresent([String].self, forKey: .subroles) ?? []
        roleDescriptions = try c.decodeIfPresent([String].self, forKey: .roleDescriptions) ?? []
        domClassPrefixes = try c.decodeIfPresent([String].self, forKey: .domClassPrefixes) ?? []
        identifierPrefixes = try c.decodeIfPresent([String].self, forKey: .identifierPrefixes) ?? []
    }
}

extension ExtractionRules {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        containers = try c.decodeIfPresent([ElementMatcher].self, forKey: .containers) ?? []
        items = try c.decodeIfPresent([ElementMatcher].self, forKey: .items) ?? []
        excludes = try c.decodeIfPresent([ElementMatcher].self, forKey: .excludes) ?? []
    }
}

extension OverlayAppearance {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OverlayAppearance()
        theme = try c.decodeIfPresent(OverlayTheme.self, forKey: .theme) ?? d.theme
        backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? d.backgroundOpacity
        minFontSize = try c.decodeIfPresent(Double.self, forKey: .minFontSize) ?? d.minFontSize
        maxFontSize = try c.decodeIfPresent(Double.self, forKey: .maxFontSize) ?? d.maxFontSize
        showStateIndicator = try c.decodeIfPresent(Bool.self, forKey: .showStateIndicator) ?? d.showStateIndicator
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        matchOriginalStyle = try c.decodeIfPresent(Bool.self, forKey: .matchOriginalStyle) ?? d.matchOriginalStyle
        matchBackgroundFromScreen =
            try c.decodeIfPresent(Bool.self, forKey: .matchBackgroundFromScreen) ?? d.matchBackgroundFromScreen
    }
}

extension OverlayInteractionSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OverlayInteractionSettings()
        hoverOriginal = (try? c.decodeIfPresent(HoverOriginalMode.self, forKey: .hoverOriginal)) ?? d.hoverOriginal
        hoverDelay = try c.decodeIfPresent(Double.self, forKey: .hoverDelay) ?? d.hoverDelay
        clickableLinks = try c.decodeIfPresent(Bool.self, forKey: .clickableLinks) ?? d.clickableLinks
    }
}

extension ProgressiveTranslationSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProgressiveTranslationSettings()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
        draftModel = try c.decodeIfPresent(ModelSize.self, forKey: .draftModel) ?? d.draftModel
        burstControl = try c.decodeIfPresent(BurstControlSettings.self, forKey: .burstControl) ?? d.burstControl
    }
}

extension BurstControlSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BurstControlSettings()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
        threshold = try c.decodeIfPresent(Int.self, forKey: .threshold) ?? d.threshold
        quietSeconds = try c.decodeIfPresent(Double.self, forKey: .quietSeconds) ?? d.quietSeconds
    }
}

struct GlobalSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool = true
    var targetLanguage: String = "ja"
    /// nil = detect automatically (the model detects the source language itself).
    var sourceLanguage: String? = nil
    var japaneseForm: JapaneseFormSetting = .auto
    var sameLanguagePolicy: SameLanguagePolicy = .skip
    /// The model whose translation is the finished result (the only model when 段階翻訳 is off).
    var finalModel: ModelSize = .b2
    /// 段階翻訳 (draft → final) and its burst control.
    var progressive: ProgressiveTranslationSettings = ProgressiveTranslationSettings()
    var keepTranslatingInactiveApps: Bool = false
    var defaultMode: TranslationMode = .manual
    var defaultScope: TranslationScope = .window
    var displayStyle: DisplayStyle = .replace
    var appearance: OverlayAppearance = OverlayAppearance()
    /// Hover to see the original, clickable links (replace style).
    var interaction: OverlayInteractionSettings = OverlayInteractionSettings()
    var showOriginalModifier: ModifierKey = .option
    var scanInterval: Double = 0.5
    var backgroundScanInterval: Double = 2.0
    var hideWhileScrolling: Bool = true
    /// Stop reading other apps' text while a password is being typed (secure input, a focused password field,
    /// a terminal password prompt). DESIGN §4.1.
    var pauseDuringPasswordEntry: Bool = true
    var streamPartialResults: Bool = true
    var maxSegmentsPerScan: Int = 80
    var maxSegmentCharacters: Int = 2000
    var minTextLength: Int = 2
    var idleUnloadMinutes: Int = 15
    var cacheCapacity: Int = 5000
    var persistCache: Bool = true
    var glossary: [GlossaryTerm] = []
    var toggleHotkey: HotkeySpec? = HotkeySpec(keyCode: 17, carbonModifiers: 0x1000 | 0x0800)  // ⌃⌥T
    var translateNowHotkey: HotkeySpec? = HotkeySpec(keyCode: 15, carbonModifiers: 0x1000 | 0x0800)  // ⌃⌥R
    var launchAtLogin: Bool = false
    /// ベータ版を受け取る: nil = follow the running build (on for a beta build). See UpdateChannel.
    var receiveBetaUpdates: Bool? = nil

    /// The draft model when 段階翻訳 is on, nil = single stage (setting nil turns 段階翻訳 off,
    /// setting a model turns it on with that draft model).
    var draftModel: ModelSize? {
        get { progressive.isEnabled ? progressive.draftModel : nil }
        set {
            if let newValue {
                progressive.isEnabled = true
                progressive.draftModel = newValue
            } else {
                progressive.isEnabled = false
            }
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GlobalSettings()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? d.targetLanguage
        sourceLanguage = try c.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? d.sourceLanguage
        japaneseForm = try c.decodeIfPresent(JapaneseFormSetting.self, forKey: .japaneseForm) ?? d.japaneseForm
        sameLanguagePolicy =
            try c.decodeIfPresent(SameLanguagePolicy.self, forKey: .sameLanguagePolicy) ?? d.sameLanguagePolicy
        finalModel = try c.decodeIfPresent(ModelSize.self, forKey: .finalModel) ?? d.finalModel
        if let progressive = try c.decodeIfPresent(ProgressiveTranslationSettings.self, forKey: .progressive) {
            self.progressive = progressive
        } else if c.contains(.draftModel) {
            // Files written before 段階翻訳 became its own setting: "draftModel": null meant single stage.
            // With the smallest final model the old normaliser forced null (nothing was smaller), so it was not
            // the user's choice: keep the switch on, and raising the final model makes it two-stage again.
            var migrated = d.progressive
            if let legacy = try c.decodeIfPresent(ModelSize.self, forKey: .draftModel) {
                migrated.draftModel = legacy
            } else if finalModel != ModelSize.allCases.first {
                migrated.isEnabled = false
            }
            progressive = migrated
        } else {
            progressive = d.progressive
        }
        keepTranslatingInactiveApps =
            try c.decodeIfPresent(Bool.self, forKey: .keepTranslatingInactiveApps) ?? d.keepTranslatingInactiveApps
        defaultMode = try c.decodeIfPresent(TranslationMode.self, forKey: .defaultMode) ?? d.defaultMode
        defaultScope = try c.decodeIfPresent(TranslationScope.self, forKey: .defaultScope) ?? d.defaultScope
        displayStyle = try c.decodeIfPresent(DisplayStyle.self, forKey: .displayStyle) ?? d.displayStyle
        appearance = try c.decodeIfPresent(OverlayAppearance.self, forKey: .appearance) ?? d.appearance
        interaction = try c.decodeIfPresent(OverlayInteractionSettings.self, forKey: .interaction) ?? d.interaction
        showOriginalModifier =
            try c.decodeIfPresent(ModifierKey.self, forKey: .showOriginalModifier) ?? d.showOriginalModifier
        scanInterval = try c.decodeIfPresent(Double.self, forKey: .scanInterval) ?? d.scanInterval
        backgroundScanInterval =
            try c.decodeIfPresent(Double.self, forKey: .backgroundScanInterval) ?? d.backgroundScanInterval
        hideWhileScrolling = try c.decodeIfPresent(Bool.self, forKey: .hideWhileScrolling) ?? d.hideWhileScrolling
        pauseDuringPasswordEntry =
            try c.decodeIfPresent(Bool.self, forKey: .pauseDuringPasswordEntry) ?? d.pauseDuringPasswordEntry
        streamPartialResults =
            try c.decodeIfPresent(Bool.self, forKey: .streamPartialResults) ?? d.streamPartialResults
        maxSegmentsPerScan = try c.decodeIfPresent(Int.self, forKey: .maxSegmentsPerScan) ?? d.maxSegmentsPerScan
        maxSegmentCharacters =
            try c.decodeIfPresent(Int.self, forKey: .maxSegmentCharacters) ?? d.maxSegmentCharacters
        minTextLength = try c.decodeIfPresent(Int.self, forKey: .minTextLength) ?? d.minTextLength
        idleUnloadMinutes = try c.decodeIfPresent(Int.self, forKey: .idleUnloadMinutes) ?? d.idleUnloadMinutes
        cacheCapacity = try c.decodeIfPresent(Int.self, forKey: .cacheCapacity) ?? d.cacheCapacity
        persistCache = try c.decodeIfPresent(Bool.self, forKey: .persistCache) ?? d.persistCache
        glossary = try c.decodeIfPresent([GlossaryTerm].self, forKey: .glossary) ?? d.glossary
        toggleHotkey =
            c.contains(.toggleHotkey) ? try c.decodeIfPresent(HotkeySpec.self, forKey: .toggleHotkey) : d.toggleHotkey
        translateNowHotkey =
            c.contains(.translateNowHotkey)
            ? try c.decodeIfPresent(HotkeySpec.self, forKey: .translateNowHotkey) : d.translateNowHotkey
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        receiveBetaUpdates = try c.decodeIfPresent(Bool.self, forKey: .receiveBetaUpdates)
    }

    // Optionals are encoded as explicit nulls so "nil" survives a round trip (it differs from "missing").
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(targetLanguage, forKey: .targetLanguage)
        try c.encode(sourceLanguage, forKey: .sourceLanguage)
        try c.encode(japaneseForm, forKey: .japaneseForm)
        try c.encode(sameLanguagePolicy, forKey: .sameLanguagePolicy)
        try c.encode(finalModel, forKey: .finalModel)
        try c.encode(progressive, forKey: .progressive)
        try c.encode(keepTranslatingInactiveApps, forKey: .keepTranslatingInactiveApps)
        try c.encode(defaultMode, forKey: .defaultMode)
        try c.encode(defaultScope, forKey: .defaultScope)
        try c.encode(displayStyle, forKey: .displayStyle)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(interaction, forKey: .interaction)
        try c.encode(showOriginalModifier, forKey: .showOriginalModifier)
        try c.encode(scanInterval, forKey: .scanInterval)
        try c.encode(backgroundScanInterval, forKey: .backgroundScanInterval)
        try c.encode(hideWhileScrolling, forKey: .hideWhileScrolling)
        try c.encode(pauseDuringPasswordEntry, forKey: .pauseDuringPasswordEntry)
        try c.encode(streamPartialResults, forKey: .streamPartialResults)
        try c.encode(maxSegmentsPerScan, forKey: .maxSegmentsPerScan)
        try c.encode(maxSegmentCharacters, forKey: .maxSegmentCharacters)
        try c.encode(minTextLength, forKey: .minTextLength)
        try c.encode(idleUnloadMinutes, forKey: .idleUnloadMinutes)
        try c.encode(cacheCapacity, forKey: .cacheCapacity)
        try c.encode(persistCache, forKey: .persistCache)
        try c.encode(glossary, forKey: .glossary)
        try c.encode(toggleHotkey, forKey: .toggleHotkey)
        try c.encode(translateNowHotkey, forKey: .translateNowHotkey)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(receiveBetaUpdates, forKey: .receiveBetaUpdates)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, targetLanguage, sourceLanguage, japaneseForm, sameLanguagePolicy, finalModel, progressive
        /// Legacy key (read only): the draft model, null = single stage.
        case draftModel
        case keepTranslatingInactiveApps, defaultMode, defaultScope, displayStyle, appearance, interaction
        case showOriginalModifier
        case scanInterval, backgroundScanInterval, hideWhileScrolling, streamPartialResults, maxSegmentsPerScan
        case pauseDuringPasswordEntry
        case maxSegmentCharacters, minTextLength, idleUnloadMinutes, cacheCapacity, persistCache, glossary
        case toggleHotkey, translateNowHotkey, launchAtLogin, receiveBetaUpdates
    }
}

struct AppProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String { bundleID }
    var bundleID: String
    var displayName: String
    var mode: TranslationMode = .automatic
    var scope: TranslationScope = .window
    var rules: ExtractionRules = ExtractionRules()
    var granularity: SegmentGranularity = .paragraph
    var textAreaHandling: TextAreaHandling = .paragraphs
    /// Regular expressions; a segment (or, in terminal mode, a line) matching any of them is not translated.
    var ignorePatterns: [String] = []
    var includeControls: Bool = false
    var includeEditableText: Bool = false
    var targetLanguageOverride: String? = nil
    var formOverride: JapaneseFormSetting? = nil
    /// Passed to PLaMo as PFML3 `context` (e.g. "Slack conversation between software engineers").
    var context: String = ""
    var glossary: [GlossaryTerm] = []
    var displayStyleOverride: DisplayStyle? = nil
    var minTextLengthOverride: Int? = nil
    /// Send the previous segments of the same window as translation history (better consistency, slower).
    var useConversationHistory: Bool = false
    /// Set AXManualAccessibility on the app (needed for Electron / Chromium apps to expose their AX tree).
    var enableManualAccessibility: Bool = true
    /// Set AXEnhancedUserInterface (some apps need it; may disable window animations).
    var enableEnhancedUserInterface: Bool = false
    /// nil = follow GlobalSettings.keepTranslatingInactiveApps.
    var keepTranslatingWhenInactiveOverride: Bool? = nil
    /// 段階翻訳 for this app: nil = follow GlobalSettings.progressive.isEnabled.
    var progressiveOverride: Bool? = nil

    init(bundleID: String, displayName: String) {
        self.bundleID = bundleID
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? bundleID
        let d = AppProfile(bundleID: bundleID, displayName: displayName)
        mode = try c.decodeIfPresent(TranslationMode.self, forKey: .mode) ?? d.mode
        scope = try c.decodeIfPresent(TranslationScope.self, forKey: .scope) ?? d.scope
        rules = try c.decodeIfPresent(ExtractionRules.self, forKey: .rules) ?? d.rules
        granularity = try c.decodeIfPresent(SegmentGranularity.self, forKey: .granularity) ?? d.granularity
        textAreaHandling =
            try c.decodeIfPresent(TextAreaHandling.self, forKey: .textAreaHandling) ?? d.textAreaHandling
        ignorePatterns = try c.decodeIfPresent([String].self, forKey: .ignorePatterns) ?? d.ignorePatterns
        includeControls = try c.decodeIfPresent(Bool.self, forKey: .includeControls) ?? d.includeControls
        includeEditableText = try c.decodeIfPresent(Bool.self, forKey: .includeEditableText) ?? d.includeEditableText
        targetLanguageOverride = try c.decodeIfPresent(String.self, forKey: .targetLanguageOverride)
        formOverride = try c.decodeIfPresent(JapaneseFormSetting.self, forKey: .formOverride)
        context = try c.decodeIfPresent(String.self, forKey: .context) ?? d.context
        glossary = try c.decodeIfPresent([GlossaryTerm].self, forKey: .glossary) ?? d.glossary
        displayStyleOverride = try c.decodeIfPresent(DisplayStyle.self, forKey: .displayStyleOverride)
        minTextLengthOverride = try c.decodeIfPresent(Int.self, forKey: .minTextLengthOverride)
        useConversationHistory =
            try c.decodeIfPresent(Bool.self, forKey: .useConversationHistory) ?? d.useConversationHistory
        enableManualAccessibility =
            try c.decodeIfPresent(Bool.self, forKey: .enableManualAccessibility) ?? d.enableManualAccessibility
        enableEnhancedUserInterface =
            try c.decodeIfPresent(Bool.self, forKey: .enableEnhancedUserInterface) ?? d.enableEnhancedUserInterface
        keepTranslatingWhenInactiveOverride =
            try c.decodeIfPresent(Bool.self, forKey: .keepTranslatingWhenInactiveOverride)
        progressiveOverride = try c.decodeIfPresent(Bool.self, forKey: .progressiveOverride)
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID, displayName, mode, scope, rules, granularity, textAreaHandling, ignorePatterns
        case includeControls, includeEditableText
        case targetLanguageOverride, formOverride, context, glossary, displayStyleOverride, minTextLengthOverride
        case useConversationHistory, enableManualAccessibility, enableEnhancedUserInterface
        case keepTranslatingWhenInactiveOverride, progressiveOverride
    }
}

struct SettingsDocument: Codable, Equatable, Sendable {
    var version: Int = 1
    var global: GlobalSettings = GlobalSettings()
    /// Profiles the user created or edited. Presets that were never edited are not stored here.
    var profiles: [AppProfile] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        global = try c.decodeIfPresent(GlobalSettings.self, forKey: .global) ?? GlobalSettings()
        profiles = try c.decodeIfPresent([AppProfile].self, forKey: .profiles) ?? []
    }

    private enum CodingKeys: String, CodingKey { case version, global, profiles }
}

/// The settings that apply to one app after merging its profile with the global settings.
struct EffectiveSettings: Equatable, Sendable {
    var profile: AppProfile
    var global: GlobalSettings

    var mode: TranslationMode { global.isEnabled ? profile.mode : .off }
    var targetLanguage: String { profile.targetLanguageOverride ?? global.targetLanguage }
    var japaneseForm: JapaneseFormSetting { profile.formOverride ?? global.japaneseForm }
    var displayStyle: DisplayStyle { profile.displayStyleOverride ?? global.displayStyle }
    var minTextLength: Int { profile.minTextLengthOverride ?? global.minTextLength }
    var keepTranslatingWhenInactive: Bool {
        profile.keepTranslatingWhenInactiveOverride ?? global.keepTranslatingInactiveApps
    }
    /// 段階翻訳 after the app's override (the draft model and burst control stay global).
    var progressive: ProgressiveTranslationSettings {
        var p = global.progressive
        if let override = profile.progressiveOverride { p.isEnabled = override }
        return p
    }
    /// Draft model for this app, nil = single stage with `global.finalModel`.
    var draftModel: ModelSize? { progressive.isEnabled ? progressive.draftModel : nil }
    /// Global glossary first, then the app's terms (app terms win on duplicate sources).
    /// Unfinished terms (empty source or target) are left out: PLaMo rejects an empty target.
    var glossary: [GlossaryTerm] {
        var bySource: [String: GlossaryTerm] = [:]
        var order: [String] = []
        for term in global.glossary + profile.glossary where term.isUsable {
            if bySource[term.source] == nil { order.append(term.source) }
            bySource[term.source] = term
        }
        return order.compactMap { bySource[$0] }
    }
}
