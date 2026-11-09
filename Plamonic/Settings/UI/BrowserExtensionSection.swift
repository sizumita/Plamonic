import SafariServices
import SwiftUI

/// 設定「一般」の「ブラウザ」: whether the app translates for the extensions, and whether Safari's is turned on.
struct BrowserExtensionSection: View {
    @ObservedObject var store: SettingsStore
    @State private var safariEnabled: Bool?
    @State private var safariError: String?
    @State private var chromeBrowsers: [String] = []

    static let safariExtensionID = "io.smdr.Plamonic.SafariExtension"

    var body: some View {
        Section {
            Toggle("ブラウザの拡張機能に翻訳を提供する", isOn: $store.global.acceptBrowserExtensions)
            LabeledContent("Safari の拡張機能") {
                HStack {
                    switch safariEnabled {
                    case .some(true):
                        Label("オン", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .some(false):
                        Label("オフ", systemImage: "circle").foregroundStyle(.secondary)
                    case .none:
                        Text("確認中…").foregroundStyle(.secondary)
                    }
                    Button("Safari の設定を開く") { openSafariSettings() }
                }
            }
            LabeledContent("Chrome などの拡張機能") {
                if chromeBrowsers.isEmpty {
                    Text("Chromium 系のブラウザが見つかりません").foregroundStyle(.secondary)
                } else {
                    Label(chromeBrowsers.joined(separator: "、"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .lineLimit(2)
                }
            }
        } header: {
            Text("ブラウザ")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Safari と Chrome の Plamonic 拡張機能が、Web ページをこの Mac で翻訳できるようにします。Safari では「設定」の「機能拡張」で Plamonic をオンにしてください。Chrome、Edge、Brave などには、Plamonic が起動したときに拡張機能との接続を登録します（拡張機能はそれぞれのストアから入れます）。")
                if let safariError { Text(safariError).foregroundStyle(.orange) }
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        chromeBrowsers = ChromeNativeHostInstaller.installedBrowsers()
        do {
            let state = try await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: Self.safariExtensionID)
            safariEnabled = state.isEnabled
            safariError = nil
        } catch {
            safariEnabled = false
            safariError = "Safari の拡張機能の状態を読めません: \(error.localizedDescription)"
        }
    }

    private func openSafariSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: Self.safariExtensionID) { error in
            guard let error else { return }
            Task { @MainActor in safariError = "Safari の設定を開けません: \(error.localizedDescription)" }
        }
    }
}
