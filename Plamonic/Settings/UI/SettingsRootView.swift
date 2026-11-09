import AppKit
import SwiftUI

/// A running app offered in the Apps pane.
typealias SettingsRunningApp = (bundleID: String, name: String, icon: NSImage?)

/// Hooks the settings window needs from the rest of the app. All optional.
struct SettingsUIActions {
    /// Clears the translation cache (memory and disk).
    var clearCache: (@MainActor () -> Void)?
    /// Short status line for the cache, e.g. "1,234 件 (2.1 MB)".
    var cacheSummary: (@MainActor () -> String)?
    /// Whether Screen Recording is granted (used to match overlay colors to the window). nil = unknown.
    var screenRecordingAuthorized: (@MainActor () -> Bool)?
    /// Asks macOS for Screen Recording permission and opens System Settings.
    var requestScreenRecording: (@MainActor () -> Void)?

    init(
        clearCache: (@MainActor () -> Void)? = nil, cacheSummary: (@MainActor () -> String)? = nil,
        screenRecordingAuthorized: (@MainActor () -> Bool)? = nil, requestScreenRecording: (@MainActor () -> Void)? = nil
    ) {
        self.clearCache = clearCache
        self.cacheSummary = cacheSummary
        self.screenRecordingAuthorized = screenRecordingAuthorized
        self.requestScreenRecording = requestScreenRecording
    }
}

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general, translation, models, apps, sites, glossary, display, hotkeys, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "一般"
        case .translation: "翻訳"
        case .models: "モデル"
        case .apps: "アプリ"
        case .sites: "Webサイト"
        case .glossary: "用語集"
        case .display: "表示"
        case .hotkeys: "ホットキー"
        case .advanced: "詳細"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .translation: "character.bubble"
        case .models: "cpu"
        case .apps: "square.grid.2x2"
        case .sites: "globe"
        case .glossary: "book.closed"
        case .display: "textformat.size"
        case .hotkeys: "keyboard"
        case .advanced: "slider.horizontal.3"
        }
    }
}

/// The settings window content: a sidebar of panes and the selected pane.
struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var models: ModelLibrary
    let inspector: (any ElementInspecting)?
    let runningApps: () -> [SettingsRunningApp]
    let actions: SettingsUIActions
    let updates: UpdateController?
    @State private var selection: SettingsPane?

    init(
        store: SettingsStore,
        models: ModelLibrary,
        inspector: (any ElementInspecting)?,
        runningApps: @escaping () -> [SettingsRunningApp],
        actions: SettingsUIActions = SettingsUIActions(),
        updates: UpdateController? = nil,
        initialPane: SettingsPane = .general
    ) {
        self.store = store
        self.models = models
        self.inspector = inspector
        self.runningApps = runningApps
        self.actions = actions
        self.updates = updates
        self._selection = State(initialValue: initialPane)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.systemImage).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            pane(selection ?? .general)
                .navigationTitle((selection ?? .general).title)
        }
        .frame(minWidth: 780, minHeight: 540)
    }

    @ViewBuilder
    private func pane(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettingsPane(store: store, updates: updates)
        case .translation: TranslationSettingsPane(store: store)
        case .models: ModelSettingsPane(store: store, models: models)
        case .apps: AppsSettingsPane(store: store, inspector: inspector, runningApps: runningApps)
        case .sites: SitesSettingsPane(store: store)
        case .glossary: GlossarySettingsPane(store: store)
        case .display: DisplaySettingsPane(store: store, actions: actions)
        case .hotkeys: HotkeySettingsPane(store: store)
        case .advanced: AdvancedSettingsPane(store: store, actions: actions)
        }
    }
}
