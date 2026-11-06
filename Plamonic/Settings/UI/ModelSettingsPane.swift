import SwiftUI

struct ModelSettingsPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var models: ModelLibrary
    @State private var pendingDelete: ModelSize?

    static let licenseURL = URL(string: "https://plamo.preferredai.jp/info/plamo-community-license")!

    var body: some View {
        Form {
            Section {
                Picker("翻訳モデル", selection: $store.global.finalModel) {
                    ForEach(ModelSize.allCases) { Text(choiceLabel($0)).tag($0) }
                }
                if let missing = missingFinalModel {
                    Label("\(missing.displayName) はまだダウンロードされていません。下の一覧からダウンロードしてください。", systemImage: "arrow.down.circle")
                        .foregroundStyle(.orange)
                }
                LabeledContent(modelsInUse.count > 1 ? "使うメモリの目安（下書きモデルを含む）" : "使うメモリの目安") {
                    Text(memoryEstimate).foregroundStyle(memoryWarning ? .orange : .secondary)
                }
            } header: {
                Text("翻訳モデル")
            } footer: {
                Text("訳文の完成形を出すモデルです。段階翻訳がオフのときは、このモデルだけで訳します。大きいほど訳は正確になりますが、遅くなり、多くのメモリを使います。")
            }

            progressiveSection
            burstControlSection

            Section {
                ForEach(ModelSize.allCases) { size in
                    ModelRow(
                        size: size, state: models.state(for: size),
                        download: { models.download(size) },
                        cancel: { models.cancelDownload(size) },
                        delete: { pendingDelete = size })
                }
                HStack {
                    Text("このMacのメモリ: \(SettingsFormat.physicalMemoryGB) GB")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("モデルをメモリから解放") {
                        Task { await models.unloadAll() }
                    }
                    .disabled(!models.states.values.contains { $0.loaded })
                }
            } header: {
                Text("ダウンロード")
            } footer: {
                Text("モデルは ~/Library/Application Support/Plamonic/Models に保存されます。ダウンロードが途中で失敗したときは、済んだファイルを残して次回はその続きから始めます（キャンセルや削除で消えます）。サイズが大きいほど訳文の質は上がりますが、遅くなり、多くのメモリを使います。")
            }

            Section("ライセンス") {
                Text("PLaMo 3 Translate のモデルは Preferred Networks が PLaMo Community License のもとで公開しています。ダウンロードして使う前にライセンスを確認してください。商用で利用する場合は Preferred Networks への登録が必要です。")
                    .fixedSize(horizontal: false, vertical: true)
                Link("PLaMo Community License を読む", destination: Self.licenseURL)
                Text("Built with PLaMo")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await models.refresh() }
        .confirmationDialog(
            "\(pendingDelete?.displayName ?? "") のモデルを削除しますか？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { size in
            Button("削除", role: .destructive) {
                Task { await models.delete(size) }
            }
        } message: { size in
            Text(deleteMessage(size))
        }
    }

    // MARK: - 段階翻訳

    private var progressiveSection: some View {
        Section {
            Toggle("段階翻訳を使う", isOn: $store.global.progressive.isEnabled)
            if draftChoices.isEmpty {
                LabeledContent("下書きモデル") {
                    Text("なし（翻訳モデルより小さいサイズがありません）").foregroundStyle(.secondary)
                }
            } else {
                Picker("下書きモデル", selection: $store.global.progressive.draftModel) {
                    ForEach(draftChoices) { Text(choiceLabel($0)).tag($0) }
                }
                .disabled(!progressiveInUse)
            }
            if progressiveInUse, let issue = progressiveIssue {
                Label(issue.message, systemImage: issueSymbol(issue))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let overrides = overrideNote {
                Label(overrides, systemImage: "square.grid.2x2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("段階翻訳")
        } footer: {
            Text("まず小さく速い下書きモデルで訳してすぐに表示し、続けて翻訳モデルで訳し直して差し替えます。下書きモデルは翻訳モデルより小さいサイズだけ選べます。オフにすると翻訳モデルだけで訳すので、訳文が出るまでの時間が長くなります。アプリごとの使う・使わないは「アプリ」で変えられます。")
        }
    }

    private var burstControlSection: some View {
        let burst = $store.global.progressive.burstControl
        return Section {
            Toggle("新しい文章が多いときは仕上げを一時停止する", isOn: burst.isEnabled)
            Stepper(value: burst.threshold, in: SettingsLimits.burstThreshold) {
                Text("一度に \(burst.wrappedValue.threshold) 件以上の新しい文章が来たら仕上げを止める")
                    .monospacedDigit()
            }
            .disabled(!burst.wrappedValue.isEnabled)
            Stepper(value: burst.quietSeconds, in: SettingsLimits.burstQuietSeconds, step: 0.5) {
                Text("新しい文章が \(SettingsFormat.seconds(burst.wrappedValue.quietSeconds))ほとんど来なくなったら再開")
                    .monospacedDigit()
            }
            .disabled(!burst.wrappedValue.isEnabled)
        } header: {
            Text("混雑時の一時停止")
        } footer: {
            Text("スクロールやメッセージの連投で新しい文章が一度にたくさん現れると、翻訳モデルが訳し直している間、新しい文章の下書きが待たされます。そのあいだは仕上げを止めて下書きを先に出し、流れが止まるかゆっくりになったら、画面にある文章を上から順に仕上げます。ログが流れ続けている間は下書きのままです。")
        }
        .disabled(!progressiveInUse)
    }

    private var snapshot: SettingsSnapshot { store.snapshot }

    /// The draft settings matter: 段階翻訳 is on, or some app turns it on for itself.
    private var progressiveInUse: Bool { snapshot.isProgressiveInUse }

    private var draftChoices: [ModelSize] {
        SettingsNormalizer.draftChoices(below: store.global.finalModel)
    }

    private var progressiveIssue: ProgressiveIssue? {
        ProgressiveStatus.issue(
            global: store.global, isInstalled: { models.state(for: $0).installed },
            isDownloading: { models.state(for: $0).downloading })
    }

    private func issueSymbol(_ issue: ProgressiveIssue) -> String {
        switch issue {
        case .finalIsSmallest: "info.circle"
        case .draftNotInstalled, .finalNotInstalled: "arrow.down.circle"
        }
    }

    /// Apps that do not follow the global switch, so turning it off (or on) is not the whole story.
    private var overrideNote: String? {
        let enabled = store.global.progressive.isEnabled
        let others = snapshot.appsOverridingProgressive(to: !enabled).map(\.displayName)
        guard !others.isEmpty else { return nil }
        let names = others.map { "「\($0)」" }.joined(separator: "、")
        return enabled
            ? "\(names)では段階翻訳を使わない設定です。"
            : "全体ではオフですが、\(names)では段階翻訳を使う設定です。下書きモデルと混雑時の一時停止はそのアプリに使われます。"
    }

    // MARK: - Memory

    private var modelsInUse: [ModelSize] { ProgressiveStatus.modelsInUse(snapshot) }

    private var missingFinalModel: ModelSize? {
        let state = models.state(for: store.global.finalModel)
        return state.installed || state.downloading ? nil : store.global.finalModel
    }

    private var memoryNeededGB: Double {
        // Weights plus KV cache and activations; a rough factor that matches the recommendations.
        modelsInUse.reduce(0) { $0 + $1.approxDownloadGB * 1.3 }
    }

    private var memoryWarning: Bool {
        let recommended = modelsInUse.map(\.recommendedMemoryGB).max() ?? 0
        return SettingsFormat.physicalMemoryGB < recommended
            || memoryNeededGB > Double(SettingsFormat.physicalMemoryGB) * 0.6
    }

    private var memoryEstimate: String {
        let base = "約 \(SettingsFormat.gigabytes(memoryNeededGB))"
        return memoryWarning ? base + "（このMacには大きすぎる可能性があります）" : base
    }

    private func deleteMessage(_ size: ModelSize) -> String {
        let state = models.state(for: size)
        if !state.installed, state.partialBytes > 0 {
            return "途中までダウンロードしたファイル（\(SettingsFormat.bytes(state.partialBytes))）を削除します。次のダウンロードは最初からになります。"
        }
        return "約 \(SettingsFormat.gigabytes(size.approxDownloadGB)) の空きができます。使うときはもう一度ダウンロードが必要です。"
    }

    private func choiceLabel(_ size: ModelSize) -> String {
        let state = models.state(for: size)
        let suffix = state.installed ? "" : state.downloading ? "（ダウンロード中）" : "（未ダウンロード）"
        return "\(size.displayName)\(suffix)"
    }
}

private struct ModelRow: View {
    let size: ModelSize
    let state: ModelInstallState
    let download: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("PLaMo 3 Translate \(size.displayName)")
                    if state.loaded {
                        Text("読み込み済み")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if SettingsFormat.physicalMemoryGB < size.recommendedMemoryGB {
                    Text("このMacのメモリでは重くなる可能性があります。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = state.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if state.downloading {
                ProgressView(value: state.progress)
                    .frame(width: 120)
                Text(SettingsFormat.percent(state.progress))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                Button("キャンセル", action: cancel)
            } else if state.installed {
                Label("ダウンロード済み", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help("ダウンロード済み")
                Button("削除", role: .destructive, action: delete)
            } else if state.partialBytes > 0 {
                // A failed download kept its finished files; downloading again resumes from them.
                Button("続きからダウンロード", action: download)
                Button("削除", role: .destructive, action: delete)
                    .help("途中までダウンロードしたファイルを削除します")
            } else {
                Button("ダウンロード", action: download)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts = ["約 \(SettingsFormat.gigabytes(size.approxDownloadGB))", "推奨メモリ \(size.recommendedMemoryGB) GB 以上"]
        if state.installed, state.bytesOnDisk > 0 {
            parts.append("ディスク使用量 \(SettingsFormat.bytes(state.bytesOnDisk))")
        } else if !state.installed, !state.downloading, state.partialBytes > 0 {
            parts.append("途中までダウンロード済み \(SettingsFormat.bytes(state.partialBytes))")
        }
        return parts.joined(separator: " ・ ")
    }
}
