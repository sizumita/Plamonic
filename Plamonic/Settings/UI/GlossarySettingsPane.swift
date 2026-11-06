import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GlossarySettingsPane: View {
    @ObservedObject var store: SettingsStore
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                SettingsGlossaryEditor(terms: $store.global.glossary)
            } header: {
                Text("全アプリ共通の用語集")
            } footer: {
                Text("原語が原文に含まれるとき、訳語を使うよう PLaMo に指示します。訳語が空の用語は使われません。アプリ別の用語集に同じ原語があれば、そちらが優先されます。")
            }

            Section {
                HStack {
                    Button("JSON から読み込む…") { importGlossary() }
                    Button("JSON に書き出す…") { exportGlossary() }
                        .disabled(store.global.glossary.allSatisfy { $0.source.isEmpty })
                    Spacer()
                    if let message { Text(message).foregroundStyle(.secondary) }
                }
            } footer: {
                Text("形式: [{\"source\": \"原語\", \"target\": \"訳語\"}, …]。読み込むと同じ原語の訳語は上書きされます。")
            }
        }
        .formStyle(.grouped)
    }

    private func importGlossary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try GlossaryFile.importGlossary(from: Data(contentsOf: url))
            let merged = GlossaryFile.merge(store.global.glossary, with: imported.terms)
            store.updateGlobal { $0.glossary = merged.terms }
            var text = "\(merged.added) 件追加、\(merged.updated) 件更新しました"
            if imported.skippedWithoutTarget > 0 {
                text += "（訳語が空の \(imported.skippedWithoutTarget) 件は読み込みませんでした）"
            }
            message = text
        } catch {
            message = error.localizedDescription
        }
    }

    private func exportGlossary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Plamonic 用語集.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try GlossaryFile.export(store.global.glossary).write(to: url, options: .atomic)
            message = "書き出しました"
        } catch {
            message = "書き出せませんでした: \(error.localizedDescription)"
        }
    }
}
