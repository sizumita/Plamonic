import SwiftUI

/// The menu of the menu bar item.
struct MenuBarContent: View {
    @ObservedObject var controller: AppController
    @ObservedObject var models: ModelLibrary
    /// Observed so the menu follows settings edited elsewhere.
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updates: UpdateController

    var body: some View {
        if !controller.accessibilityTrusted {
            Text("アクセシビリティの許可が必要です")
            Button("許可の手順を表示…") { controller.showOnboarding() }
            Divider()
        }

        if let update = updates.pendingUpdateMenuTitle {
            Button(update) { updates.checkForUpdates() }
            Divider()
        }

        Text(enabledLine)
        if let appLine { Text(appLine) }
        if let pause = controller.sessionStatus.passwordPause { Text(pause.menuLine) }
        ForEach(modelLines, id: \.self) { Text($0) }
        if let error = controller.hotkeyError { Text(error) }
        Divider()

        Toggle("翻訳を有効にする\(hint(settings.global.toggleHotkey))", isOn: enabledBinding)

        if let name = controller.sessionStatus.frontmostAppName {
            Picker("\(name) の動作", selection: modeBinding) {
                ForEach(TranslationMode.allCases) { mode in
                    Text(mode.settingsLabel).tag(mode)
                }
            }
            .pickerStyle(.inline)
        }

        Button(
            (controller.sessionStatus.manualActive ? "翻訳を閉じる" : "今すぐ翻訳")
                + hint(settings.global.translateNowHotkey)
        ) {
            controller.translateNow()
        }
        .disabled(!controller.accessibilityTrusted)

        Divider()
        if updates.isRunning {
            Button("アップデートを確認…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
        }
        Button("設定…") { controller.showSettings() }
            .keyboardShortcut(",", modifiers: .command)
        Button("Plamonic を終了") { controller.quit() }
            .keyboardShortcut("q", modifiers: .command)
    }

    /// Global hotkeys are shown in the title; a menu key equivalent would fire them twice.
    private func hint(_ spec: HotkeySpec?) -> String {
        guard let spec else { return "" }
        return "（\(spec.displayString)）"
    }

    private var enabledLine: String {
        settings.global.isEnabled ? "Plamonic: 翻訳オン" : "Plamonic: 翻訳オフ"
    }

    private var appLine: String? {
        let status = controller.sessionStatus
        guard let name = status.frontmostAppName else { return nil }
        let mode = status.frontmostMode?.settingsLabel ?? "—"
        return "前面のアプリ: \(name)（\(mode)）"
    }

    private var modelLines: [String] {
        var lines: [String] = []
        for size in ModelSize.allCases {
            let state = models.state(for: size)
            if state.downloading {
                lines.append("ダウンロード中: \(size.displayName) \(Int(state.progress * 100))%")
            }
        }
        if let loading = controller.loadActivity.loading {
            lines.append("モデルを読み込み中: \(loading.displayName)")
        }
        let activity = controller.activity
        if let running = activity.runningModel {
            let rest = activity.remainingJobs > 0 ? "（残り \(activity.remainingJobs) 件）" : ""
            lines.append("翻訳中: \(running.displayName)\(rest)")
        }
        if let pause = activity.refinementPauseNotice {
            lines.append(pause)
        }
        if let notice = activity.plan?.notice {
            lines.append(notice)
        } else if !controller.hasUsableModel {
            lines.append("翻訳モデルがありません。設定の「モデル」からダウンロードしてください。")
        }
        if let error = activity.lastError {
            lines.append("エラー: \(error)")
        }
        if let error = controller.launchAtLoginError { lines.append(error) }
        return lines
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.global.isEnabled },
            set: { newValue in
                if newValue != settings.global.isEnabled { controller.toggleEnabled() }
            })
    }

    private var modeBinding: Binding<TranslationMode> {
        Binding(
            get: {
                guard let bundleID = controller.sessionStatus.frontmostBundleID else { return .off }
                return settings.profile(
                    for: bundleID, appName: controller.sessionStatus.frontmostAppName
                ).mode
            },
            set: { controller.setFrontmostMode($0) })
    }
}
