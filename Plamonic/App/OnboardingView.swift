import SwiftUI

/// First-run window: Accessibility permission, then the default models.
struct OnboardingView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var models: ModelLibrary

    init(controller: AppController) {
        self.controller = controller
        self.models = controller.models
    }

    private static let defaultModels: [ModelSize] = [.b0_8, .b2]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plamonic へようこそ").font(.title2.bold())
                    Text("ほかのアプリの文章をその場で日本語などに翻訳して重ねて表示します。")
                        .foregroundStyle(.secondary)
                }
            }

            step(
                number: 1, title: "画面のテキストを読み取る許可",
                done: controller.accessibilityTrusted
            ) {
                Text("Slack や Discord、ターミナルなどに表示されている文章を読み取るために、アクセシビリティの許可が必要です。読み取った文章はこの Mac の中だけで翻訳し、外部には送信しません。")
                    .fixedSize(horizontal: false, vertical: true)
                if !controller.accessibilityTrusted {
                    Text("「システム設定」>「プライバシーとセキュリティ」>「アクセシビリティ」で Plamonic をオンにしてください。")
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("システム設定を開く") { controller.requestAccessibility() }
                            .buttonStyle(.borderedProminent)
                        ProgressView().controlSize(.small)
                        Text("許可されるのを待っています…").foregroundStyle(.secondary)
                    }
                }
            }

            step(number: 2, title: "翻訳モデル", done: controller.hasUsableModel && !models.isAnyDownloading) {
                Text("翻訳は PLaMo 3 Translate をこの Mac の上で動かして行います。まず小さな下書きモデル（0.8B）ですばやく訳し、続けて仕上げモデル（2B）で訳し直して差し替えます。")
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Self.defaultModels) { size in
                    modelRow(size)
                }
                if !Self.defaultModels.allSatisfy({ models.isInstalled($0) }) {
                    HStack {
                        Button("0.8B と 2B をダウンロード（約 3.4 GB）") { controller.downloadDefaultModels() }
                            .buttonStyle(.borderedProminent)
                            .disabled(Self.defaultModels.allSatisfy { models.isInstalled($0) || models.isDownloading($0) })
                        Button("ほかのサイズを選ぶ…") { controller.showSettings(pane: .models) }
                    }
                }
                Text("モデルは Preferred Networks が PLaMo Community License のもとで公開しています。商用で利用する場合は Preferred Networks への登録が必要です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PlamoLicenseButton()
                    .font(.caption)
            }

            step(number: 3, title: "見た目をなじませる（任意）", done: controller.screenRecordingAuthorized) {
                Text("訳文の背景色と文字色を元のアプリに合わせるために、画面収録の許可を使います。取り込んだ画面は色を測るためだけに使い、保存も送信もしません。")
                    .fixedSize(horizontal: false, vertical: true)
                if controller.screenRecordingAuthorized {
                    Text("許可されています。訳文の色を元の画面に合わせます。")
                        .foregroundStyle(.secondary)
                } else {
                    Text("許可しなくても翻訳はできます（訳文はテーマの色で表示します）。許可したあとは Plamonic の再起動が必要なことがあります。")
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)
                    Button("画面収録を許可…") { controller.requestScreenRecording() }
                }
            }

            Divider()
            HStack {
                Text("メニューバーのアイコンから、アプリごとの動作（オフ / 自動 / 手動）や設定を変えられます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(isReady ? "はじめる" : "あとで") { controller.closeOnboarding() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task { await models.refresh() }
    }

    private var isReady: Bool {
        controller.accessibilityTrusted && controller.hasUsableModel && !models.isAnyDownloading
    }

    @ViewBuilder
    private func step<Content: View>(
        number: Int, title: String, done: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ size: ModelSize) -> some View {
        let state = models.state(for: size)
        HStack {
            Text("\(size.displayName)（約 \(SettingsFormat.gigabytes(size.approxDownloadGB))）")
                .frame(width: 150, alignment: .leading)
            if state.downloading {
                ProgressView(value: state.progress).frame(width: 180)
                Text(SettingsFormat.percent(state.progress)).monospacedDigit().foregroundStyle(.secondary)
                Button("中止") { models.cancelDownload(size) }
            } else if state.installed {
                Label("インストール済み", systemImage: "checkmark").foregroundStyle(.green)
            } else if let error = state.error {
                Text(error).foregroundStyle(.orange).lineLimit(2)
            } else {
                Text("未インストール").foregroundStyle(.secondary)
            }
        }
    }
}
