import SwiftUI

struct HotkeySettingsPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                LabeledContent("翻訳のオン・オフ") {
                    HotkeyRecorder(spec: $store.global.toggleHotkey)
                }
                LabeledContent("今すぐ翻訳") {
                    HotkeyRecorder(spec: $store.global.translateNowHotkey)
                }
                if let toggle = store.global.toggleHotkey, toggle == store.global.translateNowHotkey {
                    Label("2 つの操作に同じショートカットが割り当てられています。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("「今すぐ翻訳」は前面のウインドウを 1 回だけ翻訳します。動作が「手動」のアプリではこのキーで翻訳します。記録中は Esc で取り消し、Delete でショートカットを削除します。")
            }

            Section {
                Button("既定のショートカットに戻す") {
                    let defaults = GlobalSettings()
                    store.updateGlobal {
                        $0.toggleHotkey = defaults.toggleHotkey
                        $0.translateNowHotkey = defaults.translateNowHotkey
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
