import AppKit
import SwiftUI

/// The PLaMo Community License, read from the copy bundled in Contents/Resources/LICENSES.
/// The official page needs JavaScript and sometimes shows only the PLaMo top page, so the text is shown here.
struct PlamoLicenseView: View {
    enum Language: String, CaseIterable, Identifiable {
        case japanese, english
        var id: Self { self }

        var label: String {
            switch self {
            case .japanese: "日本語"
            case .english: "English"
            }
        }

        var resourceName: String {
            switch self {
            case .japanese: "PLaMo-Community-License.ja"
            case .english: "PLaMo-Community-License"
            }
        }
    }

    static let officialURL = URL(string: "https://plamo.preferredai.jp/info/plamo-community-license")!

    @Environment(\.dismiss) private var dismiss
    @State private var language: Language = .japanese

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PLaMo Community License").font(.headline)
                Spacer()
                Picker("言語", selection: $language) {
                    ForEach(Language.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(16)

            Divider()

            ScrollView {
                Text(Self.text(for: language) ?? missingMessage)
                    .font(.callout)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .id(language)  // Back to the top when the language changes.

            Divider()

            HStack {
                Text("商用で利用する場合は Preferred Networks への登録が必要です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Link("公式ページを開く", destination: Self.officialURL)
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
    }

    private var missingMessage: String {
        "ライセンスの本文が見つかりませんでした。「公式ページを開く」から確認してください。"
    }

    static func text(for language: Language) -> String? {
        guard let url = Bundle.main.url(
            forResource: language.resourceName, withExtension: "txt", subdirectory: "LICENSES")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// A button that shows the bundled PLaMo Community License in a sheet.
struct PlamoLicenseButton: View {
    var title: String = "PLaMo Community License を読む"
    @State private var isPresented = false

    var body: some View {
        Button(title) { isPresented = true }
            .buttonStyle(.link)
            .sheet(isPresented: $isPresented) { PlamoLicenseView() }
    }
}
