import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppsSettingsPane: View {
    @ObservedObject var store: SettingsStore
    let inspector: (any ElementInspecting)?
    let runningApps: () -> [SettingsRunningApp]

    @State private var selection: String?
    @State private var running: [RunningAppRow] = []

    var body: some View {
        HStack(spacing: 0) {
            appList
                .frame(width: 250)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: reloadRunningApps)
    }

    // MARK: - List

    private var appList: some View {
        List(selection: $selection) {
            Section("設定済み") {
                if customized.isEmpty {
                    Text("まだありません").foregroundStyle(.secondary)
                }
                ForEach(customized, id: \.bundleID) { profile in
                    row(bundleID: profile.bundleID, name: profile.displayName, icon: runningIcon(profile.bundleID))
                }
            }
            Section("プリセット") {
                ForEach(uncustomizedPresets) { preset in
                    row(bundleID: preset.bundleID, name: preset.displayName, icon: runningIcon(preset.bundleID))
                }
            }
            Section("実行中のアプリ") {
                ForEach(unconfiguredRunning) { app in
                    row(bundleID: app.bundleID, name: app.name, icon: app.icon)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    addAppFromPanel()
                } label: {
                    Label("アプリを追加…", systemImage: "plus")
                }
                .help("アプリケーションを選んで個別の設定を作ります")
                Spacer()
                Button {
                    reloadRunningApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("実行中のアプリを読み直す")
            }
            .buttonStyle(.borderless)
            .padding(8)
            .background(.bar)
        }
    }

    private func row(bundleID: String, name: String, icon: NSImage?) -> some View {
        let profile = store.profile(for: bundleID, appName: name)
        let source = store.profileSource(for: bundleID)
        return HStack(spacing: 8) {
            SettingsAppIcon(bundleID: bundleID, preferred: icon, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                Text(source == .defaults ? "未設定（\(profile.mode.settingsLabel)）" : profile.mode.settingsLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(bundleID)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let bundleID = selection {
            AppProfileEditor(
                store: store, bundleID: bundleID, appName: name(for: bundleID), icon: runningIcon(bundleID),
                inspector: inspector,
                onRemoved: { if store.profileSource(for: bundleID) == .defaults && !isRunning(bundleID) { selection = nil } }
            )
            .id(bundleID)
        } else {
            ContentUnavailableView(
                "アプリを選んでください", systemImage: "square.grid.2x2",
                description: Text("左の一覧からアプリを選ぶと、そのアプリでの翻訳のしかたを設定できます。"))
        }
    }

    // MARK: - Data

    private struct RunningAppRow: Identifiable {
        var bundleID: String
        var name: String
        var icon: NSImage?
        var id: String { bundleID }
    }

    private var customized: [AppProfile] {
        store.profiles.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var uncustomizedPresets: [AppPreset] {
        AppPresets.all.filter { store.userProfile(for: $0.bundleID) == nil }
    }

    private var unconfiguredRunning: [RunningAppRow] {
        running.filter { store.profileSource(for: $0.bundleID) == .defaults }
    }

    private func isRunning(_ bundleID: String) -> Bool { running.contains { $0.bundleID == bundleID } }

    private func runningIcon(_ bundleID: String) -> NSImage? {
        running.first { $0.bundleID == bundleID }?.icon
    }

    private func name(for bundleID: String) -> String? {
        store.userProfile(for: bundleID)?.displayName
            ?? AppPresets.preset(for: bundleID)?.displayName
            ?? running.first { $0.bundleID == bundleID }?.name
    }

    private func reloadRunningApps() {
        var seen = Set<String>()
        running = runningApps()
            .filter { !$0.bundleID.isEmpty && seen.insert($0.bundleID).inserted }
            .map { RunningAppRow(bundleID: $0.bundleID, name: $0.name, icon: $0.icon) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func addAppFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
            let bundleID = bundle.bundleIdentifier
        else { return }
        let name =
            (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        if store.profileSource(for: bundleID) == .defaults {
            store.upsert(store.profile(for: bundleID, appName: name))
        }
        selection = bundleID
    }
}
