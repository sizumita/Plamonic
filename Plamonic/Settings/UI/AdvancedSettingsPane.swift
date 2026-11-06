import AppKit
import SwiftUI

struct AdvancedSettingsPane: View {
    @ObservedObject var store: SettingsStore
    let actions: SettingsUIActions
    @State private var confirmReset = false
    @State private var cacheMessage: String?

    private static let idleChoices = [0, 5, 10, 15, 30, 60, 120]

    var body: some View {
        Form {
            Section {
                intervalRow(
                    "前面のアプリ", value: $store.global.scanInterval, range: SettingsLimits.scanInterval, step: 0.1)
                intervalRow(
                    "背面のアプリ", value: $store.global.backgroundScanInterval,
                    range: SettingsLimits.backgroundScanInterval, step: 0.5)
            } header: {
                Text("走査の間隔")
            } footer: {
                Text("画面の変化はふだんは通知で検出し、この間隔でも読み直します。短くすると反応が速くなりますが CPU を多く使います。")
            }

            Section {
                Stepper(value: $store.global.maxSegmentsPerScan, in: SettingsLimits.maxSegmentsPerScan, step: 10) {
                    LabeledContent("1 回に扱う最大の段落数", value: "\(store.global.maxSegmentsPerScan)")
                }
                Stepper(
                    value: $store.global.maxSegmentCharacters, in: SettingsLimits.maxSegmentCharacters, step: 100
                ) {
                    LabeledContent("1 段落の最大文字数", value: "\(store.global.maxSegmentCharacters)")
                }
                Stepper(value: $store.global.minTextLength, in: SettingsLimits.minTextLength) {
                    LabeledContent("翻訳する最小文字数", value: "\(store.global.minTextLength)")
                }
            } header: {
                Text("上限")
            } footer: {
                Text("最大文字数を超える段落は翻訳しません。最小文字数より短いテキスト（「OK」など）も翻訳しません。")
            }

            Section {
                Stepper(value: $store.global.cacheCapacity, in: SettingsLimits.cacheCapacity, step: 1000) {
                    LabeledContent("保存する訳文の件数", value: "\(store.global.cacheCapacity)")
                }
                Toggle("訳文をディスクに保存する", isOn: $store.global.persistCache)
                HStack {
                    if let summary = actions.cacheSummary?() {
                        Text(summary).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let cacheMessage { Text(cacheMessage).foregroundStyle(.secondary) }
                    Button("キャッシュを消去") {
                        actions.clearCache?()
                        cacheMessage = "消去しました"
                    }
                    .disabled(actions.clearCache == nil)
                }
            } header: {
                Text("キャッシュ")
            } footer: {
                Text("同じ原文はキャッシュから即座に表示します。ディスクに保存すると再起動後も使えます。")
            }

            Section {
                Picker("使われていないモデルを解放するまで", selection: $store.global.idleUnloadMinutes) {
                    ForEach(idleChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "解放しない" : "\(minutes) 分").tag(minutes)
                    }
                }
            } header: {
                Text("メモリ")
            } footer: {
                Text("しばらく翻訳しないとモデルをメモリから外します。次に翻訳するときは読み込みに数秒かかります。")
            }

            Section("設定ファイル") {
                LabeledContent("場所") {
                    Text(store.fileURL.path)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let error = store.lastSaveError {
                    Label("保存できませんでした: \(error)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Finder で表示") {
                        store.flush()
                        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                    }
                    Spacer()
                    Button("すべての設定を初期化…", role: .destructive) { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("すべての設定を初期化しますか？", isPresented: $confirmReset) {
            Button("初期化", role: .destructive) { store.resetAll() }
        } message: {
            Text("アプリ別の設定と用語集も消えます。ダウンロード済みのモデルは消えません。")
        }
    }

    private var idleChoices: [Int] {
        var choices = Self.idleChoices
        if !choices.contains(store.global.idleUnloadMinutes) {
            choices.append(store.global.idleUnloadMinutes)
            choices.sort()
        }
        return choices
    }

    private func intervalRow(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(maxWidth: 220)
                Text(SettingsFormat.seconds(value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }
}
