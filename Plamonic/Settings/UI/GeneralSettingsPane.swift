import AppKit
import ApplicationServices
import SwiftUI

struct GeneralSettingsPane: View {
    @ObservedObject var store: SettingsStore
    var updates: UpdateController? = nil
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                Toggle("翻訳を有効にする", isOn: $store.global.isEnabled)
                Toggle("ログイン時に起動", isOn: $store.global.launchAtLogin)
            } footer: {
                Text("翻訳のオン・オフはホットキーやメニューバーからも切り替えられます。")
            }

            Section {
                Picker("動作", selection: $store.global.defaultMode) {
                    ForEach(TranslationMode.allCases) { Text($0.settingsLabel).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("範囲", selection: $store.global.defaultScope) {
                    ForEach(TranslationScope.allCases) { Text($0.settingsLabel).tag($0) }
                }
            } header: {
                Text("未登録のアプリ")
            } footer: {
                Text("プリセットも個別の設定もないアプリに使われます。\(store.global.defaultMode.settingsDescription)")
            }

            Section {
                Toggle("アプリを切り替えた後も翻訳を続ける", isOn: $store.global.keepTranslatingInactiveApps)
            } footer: {
                Text("オンにすると、前面でなくなったアプリのウインドウも監視して訳文を表示し続けます。背面のウインドウは「詳細」の背面アプリ用の間隔で走査します。")
            }

            Section {
                Toggle("パスワード入力中は読み取らない", isOn: $store.global.pauseDuringPasswordEntry)
            } header: {
                Text("プライバシー")
            } footer: {
                Text(Self.passwordPauseDescription)
            }

            Section {
                Toggle("ブラウザの拡張機能に翻訳を提供する", isOn: $store.global.acceptBrowserExtensions)
            } header: {
                Text("ブラウザ")
            } footer: {
                Text("Safari と Chrome の Plamonic 拡張機能が、YouTube の字幕などをこの Mac で翻訳できるようにします。")
            }

            Section("アクセシビリティ") {
                LabeledContent("画面のテキストの読み取り") {
                    if accessibilityTrusted {
                        Label("許可されています", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        HStack {
                            Label("許可されていません", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Button("システム設定を開く") { openAccessibilitySettings() }
                        }
                    }
                }
            }

            if let updates {
                UpdateSettingsSection(updates: updates, store: store)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
        }
    }

    static let passwordPauseDescription =
        "パスワード欄に入力しているときや、ロック解除などシステムのパスワード画面が出ているときは、ほかのアプリのテキストも画面も読み取りません。ターミナルではパスワードを待っているウインドウの読み取りを止めます。表示中の訳文はそのまま残ります。止めていることはメニューバーのメニューに表示します。パスワード欄の中身はこの設定に関係なく読み取りません。"

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

/// アップデート: the version, and Sparkle's settings when this build updates itself.
struct UpdateSettingsSection: View {
    @ObservedObject var updates: UpdateController
    /// Observed so ベータ版を受け取る follows settings edited elsewhere.
    @ObservedObject var store: SettingsStore

    var body: some View {
        Section {
            LabeledContent("バージョン", value: updates.build.displayVersion)
            if updates.isRunning {
                Toggle(
                    "自動でアップデートを確認する",
                    isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }))
                Toggle(
                    "ベータ版を受け取る",
                    isOn: Binding(
                        get: { updates.receivesBetaUpdates }, set: { updates.setReceivesBetaUpdates($0) }))
                LabeledContent {
                    Button("今すぐ確認") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                } label: {
                    Text(updates.pendingUpdateMenuTitle ?? "アップデートの確認")
                }
            }
        } header: {
            Text("アップデート")
        } footer: {
            Text(
                Self.footer(
                    state: updates.state, build: updates.build,
                    automaticChecks: updates.automaticallyChecksForUpdates))
        }
    }

    static let disabledDescription = "このビルドは自動アップデートしません（ソースからビルドしたため）"

    static let automaticCheckDescription =
        "アップデートは 1 日に 1 回確認し、見つかったときはメニューバーのメニューに表示します。"

    static let channelDescription =
        "ベータ版は正式版より先に新しい変更を試せるバージョンです。ベータ版を受け取るときも、新しい正式版が出ればそちらにアップデートします。"

    static let betaBuildDescription =
        "今使っているのはベータ版です。「ベータ版を受け取る」をオフにしても、このベータ版はそのまま使えます。これより新しい正式版が出たときに、その正式版にアップデートします。"

    static func footer(state: UpdateController.State, build: BuildInfo, automaticChecks: Bool) -> String {
        switch state {
        case .disabled:
            return disabledDescription
        case .failed(let message):
            return "アップデートの確認を始められませんでした: \(message)"
        case .idle, .running:
            return (automaticChecks ? automaticCheckDescription : "") + channelDescription
                + (build.isBeta ? betaBuildDescription : "")
        }
    }
}
