import AppKit
import SwiftUI

/// Editor for one app's profile. Edits are stored as a user profile (copy-on-write over the preset / defaults).
struct AppProfileEditor: View {
    @ObservedObject var store: SettingsStore
    let bundleID: String
    let appName: String?
    var icon: NSImage? = nil
    let inspector: (any ElementInspecting)?
    var onRemoved: () -> Void = {}

    @State private var confirmRemove = false

    private var profile: Binding<AppProfile> {
        Binding(
            get: { store.profile(for: bundleID, appName: appName) },
            set: { store.upsert($0) })
    }

    private var preset: AppPreset? { AppPresets.preset(for: bundleID) }
    private var source: ProfileSource { store.profileSource(for: bundleID) }

    var body: some View {
        Form {
            header
            behaviorSection
            rulesSection
            ignoreSection
            translationSection
            glossarySection
            displaySection
            accessibilitySection
        }
        .formStyle(.grouped)
        .confirmationDialog(removeTitle, isPresented: $confirmRemove) {
            Button(preset == nil ? "削除" : "プリセットに戻す", role: .destructive) {
                store.resetToPreset(bundleID: bundleID)
                onRemoved()
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                SettingsAppIcon(bundleID: bundleID, preferred: icon, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(profile.wrappedValue.displayName).font(.title3.weight(.semibold))
                        badge(source.settingsLabel)
                        if let preset {
                            badge(preset.verification.settingsLabel, warning: preset.verification != .verified)
                        }
                    }
                    Text(bundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let preset {
                        Text(preset.note).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !preset.coveredTools.isEmpty {
                            Text("対象: " + preset.coveredTools.joined(separator: "、"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if source == .user {
                    Button(preset == nil ? "設定を削除…" : "プリセットに戻す…") { confirmRemove = true }
                }
            }
        }
    }

    private var behaviorSection: some View {
        Section {
            Picker("動作", selection: profile.mode) {
                ForEach(TranslationMode.allCases) { Text($0.settingsLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("範囲", selection: profile.scope) {
                ForEach(TranslationScope.allCases) { Text($0.settingsLabel).tag($0) }
            }
            Picker("区切り方", selection: profile.granularity) {
                ForEach(SegmentGranularity.allCases) { Text($0.settingsLabel).tag($0) }
            }
            Picker("テキスト領域", selection: profile.textAreaHandling) {
                ForEach(TextAreaHandling.allCases) { Text($0.settingsLabel).tag($0) }
            }
            Toggle("ボタンやメニューの文字も訳す", isOn: profile.includeControls)
            Toggle("入力欄の文字も訳す（パスワード欄は常に除外）", isOn: profile.includeEditableText)
        } header: {
            Text("動作")
        } footer: {
            Text(
                [
                    profile.wrappedValue.mode.settingsDescription,
                    profile.wrappedValue.granularity.settingsDescription,
                    "テキスト領域: " + profile.wrappedValue.textAreaHandling.settingsDescription,
                ].joined(separator: "\n"))
        }
    }

    private var rulesSection: some View {
        Section {
            RulesEditor(rules: profile.rules, bundleID: bundleID, inspector: inspector)
        } header: {
            Text("抽出ルール")
        } footer: {
            Text("範囲が「ルールで指定した部分」のときに使います。各ルールは、空でない欄がすべて一致した要素に当てはまります（1 つの欄に複数書いた値はどれか 1 つに一致すればよい）。除外はほかの範囲でも使われます。")
        }
    }

    private var ignoreSection: some View {
        Section {
            SettingsPatternListEditor(patterns: profile.ignorePatterns)
        } header: {
            Text("無視するパターン（正規表現、1 行に 1 つ）")
        } footer: {
            Text("一致した段落（ターミナルでは行）は訳しません。スピナーやショートカットの案内などを除くのに使います。")
        }
    }

    private var translationSection: some View {
        Section {
            Picker("翻訳先", selection: profile.targetLanguageOverride) {
                Text("全体の設定に従う（\(LanguageCatalog.displayName(for: store.global.targetLanguage))）")
                    .tag(String?.none)
                Divider()
                ForEach(LanguageCatalog.targetLanguages) { Text($0.japaneseName).tag(String?.some($0.code)) }
            }
            Picker("文体", selection: profile.formOverride) {
                Text("全体の設定に従う（\(store.global.japaneseForm.settingsLabel)）").tag(JapaneseFormSetting?.none)
                ForEach(JapaneseFormSetting.allCases) { Text($0.settingsLabel).tag(JapaneseFormSetting?.some($0)) }
            }
            minTextLengthRow
            VStack(alignment: .leading, spacing: 4) {
                Text("文脈（PLaMo に伝える状況の説明）")
                SettingsDraftTextField(
                    "文脈", text: profile.context,
                    prompt: "例: Messages in a Slack workspace between software engineers.", axis: .vertical
                )
                .labelsHidden()
                .lineLimit(2...5)
            }
            Toggle("会話の履歴を使う", isOn: profile.useConversationHistory)
            Picker("段階翻訳", selection: profile.progressiveOverride) {
                Text(ProgressiveOverrideLabel.label(nil, global: store.global.progressive.isEnabled)).tag(Bool?.none)
                Text(ProgressiveOverrideLabel.label(true)).tag(Bool?.some(true))
                Text(ProgressiveOverrideLabel.label(false)).tag(Bool?.some(false))
            }
        } header: {
            Text("翻訳")
        } footer: {
            Text("文脈は英語で短く書くのがおすすめです。会話の履歴を使うと、直前のメッセージの原文と訳文も渡すので訳がそろいやすくなりますが、遅くなります。段階翻訳は下書きモデルで先に訳してから翻訳モデルの訳に差し替えます。下書きモデルと混雑時の一時停止は「モデル」の設定を使います。\(progressiveNote)")
        }
    }

    /// Why this app translates in one stage even though 段階翻訳 is on for it.
    private var progressiveNote: String {
        let effective = EffectiveSettings(profile: profile.wrappedValue, global: store.global)
        guard effective.progressive.isEnabled,
            SettingsNormalizer.draftChoices(below: store.global.finalModel).isEmpty
        else { return "" }
        return "（いまは翻訳モデルが最も小さい \(store.global.finalModel.displayName) なので、1 段で訳します。）"
    }

    private var minTextLengthRow: some View {
        let override = profile.minTextLengthOverride
        return HStack {
            Toggle(
                "最小文字数を変える",
                isOn: Binding(
                    get: { override.wrappedValue != nil },
                    set: { override.wrappedValue = $0 ? store.global.minTextLength : nil }))
            Spacer()
            if let value = override.wrappedValue {
                Stepper(
                    value: Binding(get: { value }, set: { override.wrappedValue = $0 }),
                    in: SettingsLimits.minTextLength
                ) {
                    Text("\(value) 文字").monospacedDigit()
                }
                .fixedSize()
            } else {
                Text("全体の設定（\(store.global.minTextLength) 文字）").foregroundStyle(.secondary)
            }
        }
    }

    private var glossarySection: some View {
        Section {
            SettingsGlossaryEditor(terms: profile.glossary)
        } header: {
            Text("このアプリの用語集")
        } footer: {
            Text("全アプリ共通の用語集に加えて使います。同じ原語があればこちらが優先されます。")
        }
    }

    private var displaySection: some View {
        Section("表示") {
            Picker("表示スタイル", selection: profile.displayStyleOverride) {
                Text("全体の設定に従う（\(store.global.displayStyle.settingsLabel)）").tag(DisplayStyle?.none)
                ForEach(DisplayStyle.allCases) { Text($0.settingsLabel).tag(DisplayStyle?.some($0)) }
            }
            Picker("切り替え後も翻訳を続ける", selection: profile.keepTranslatingWhenInactiveOverride) {
                Text("全体の設定に従う（\(store.global.keepTranslatingInactiveApps ? "続ける" : "続けない")）")
                    .tag(Bool?.none)
                Text("続ける").tag(Bool?.some(true))
                Text("続けない").tag(Bool?.some(false))
            }
        }
    }

    private var accessibilitySection: some View {
        Section {
            Toggle("AXManualAccessibility を設定する", isOn: profile.enableManualAccessibility)
            Toggle("AXEnhancedUserInterface を設定する", isOn: profile.enableEnhancedUserInterface)
        } header: {
            Text("アクセシビリティ")
        } footer: {
            Text("AXManualAccessibility は Electron / Chromium 製のアプリ（Slack、Discord など）で画面のテキストを読めるようにします。AXEnhancedUserInterface は一部のアプリで必要ですが、ウインドウのアニメーションが乱れることがあるので、必要なときだけオンにしてください。")
        }
    }

    // MARK: - Helpers

    private var removeTitle: String {
        preset == nil
            ? "\(profile.wrappedValue.displayName) の設定を削除しますか？"
            : "\(profile.wrappedValue.displayName) の設定をプリセットに戻しますか？"
    }

    private func badge(_ text: String, warning: Bool = false) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill((warning ? Color.orange : Color.secondary).opacity(0.18)))
    }
}
