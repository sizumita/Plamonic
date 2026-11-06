import SwiftUI

struct TranslationSettingsPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("言語") {
                Picker("翻訳先", selection: $store.global.targetLanguage) {
                    ForEach(LanguageCatalog.targetLanguages) { Text($0.japaneseName).tag($0.code) }
                }
                Picker("翻訳元", selection: $store.global.sourceLanguage) {
                    Text("自動判定").tag(String?.none)
                    Divider()
                    ForEach(LanguageCatalog.sourceLanguages) { Text($0.japaneseName).tag(String?.some($0.code)) }
                }
            }

            Section {
                Picker("文体", selection: $store.global.japaneseForm) {
                    ForEach(JapaneseFormSetting.allCases) { Text($0.settingsLabel).tag($0) }
                }
                .disabled(!LanguageCatalog.supportsForm(store.global.targetLanguage))
            } header: {
                Text("日本語の文体")
            } footer: {
                Text("翻訳先が日本語のときだけ使われます。「自動」は原文に合わせてモデルが選びます。")
            }

            Section {
                Picker("翻訳先と同じ言語のテキスト", selection: $store.global.sameLanguagePolicy) {
                    ForEach(SameLanguagePolicy.allCases) { Text($0.settingsLabel).tag($0) }
                }
                .pickerStyle(.segmented)
                if store.global.targetLanguage == LanguageCatalog.easyJapaneseCode,
                    store.global.sameLanguagePolicy == .skip
                {
                    Label("日本語のテキストをやさしい日本語に言い換えるには「訳す」を選んでください。", systemImage: "lightbulb")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("同じ言語のテキスト")
            } footer: {
                Text("ふつうは「訳さない」で、すでに翻訳先の言語で書かれたテキストはそのままにします。「訳す」にすると、それも PLaMo で訳します。翻訳先を「やさしい日本語」にして難しい日本語を言い換えたいときや、文体（常体・敬体）をそろえたいときに便利です。処理する量が増えるぶん遅くなります。")
            }

            Section {
                Toggle("生成途中の訳文を表示する", isOn: $store.global.streamPartialResults)
            } footer: {
                Text("訳文ができあがるのを待たずに、生成された部分から順に表示します。")
            }
        }
        .formStyle(.grouped)
    }
}
