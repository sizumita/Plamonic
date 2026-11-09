import SwiftUI

/// 設定「Webサイト」: how the browser extensions translate each site (DESIGN §9.4). The settings live here, in the
/// app, for every browser.
struct SitesSettingsPane: View {
    @ObservedObject var store: SettingsStore
    @State private var selection: String?
    @State private var adding = false
    @State private var newPattern = ""

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 250)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $adding) { addSheet }
    }

    private var customized: [SiteProfile] {
        store.snapshot.document.sites.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var presets: [SiteProfile] {
        SitePresets.all.filter { store.snapshot.userSite($0.pattern) == nil }
    }

    private var list: some View {
        List(selection: $selection) {
            Section("設定済み") {
                if customized.isEmpty { Text("まだありません").foregroundStyle(.secondary) }
                ForEach(customized) { row($0) }
            }
            Section("プリセット") {
                ForEach(presets) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    newPattern = ""
                    adding = true
                } label: {
                    Label("サイトを追加…", systemImage: "plus")
                }
                .help("サイトのアドレスを入れて、そのサイトの設定を作ります")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
            .background(.bar)
        }
    }

    private func row(_ site: SiteProfile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(site.displayName).lineLimit(1)
                Text("\(site.pattern) ・ \(site.mode.siteLabel)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .tag(site.pattern)
    }

    @ViewBuilder
    private var detail: some View {
        if let selection {
            SiteProfileEditor(store: store, pattern: selection) { newPattern in
                self.selection = newPattern
            }
            .id(selection)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "globe").font(.largeTitle).foregroundStyle(.secondary)
                Text("サイトを選んでください").foregroundStyle(.secondary)
                Text("Safari と Chrome の Plamonic 拡張機能が、サイトごとにここの設定で翻訳します。設定のないサイトは、拡張機能のメニューから「このページを翻訳」を選んだときにページ全体を訳します。")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            .padding()
        }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("サイトを追加").font(.headline)
            TextField("サイト", text: $newPattern, prompt: Text("例: example.com、*.example.com、example.com/docs"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
            Text("ホスト名か、その前に「*.」を付けたドメイン（サブドメインも含む）。後ろにパスを付けると、そのパスで始まるページだけになります。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(width: 360)
            HStack {
                Spacer()
                Button("キャンセル") { adding = false }.keyboardShortcut(.cancelAction)
                Button("追加") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(SitePattern.parse(newPattern) == nil)
            }
        }
        .padding(20)
    }

    private func add() {
        let pattern = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SitePattern.parse(pattern) != nil else { return }
        if store.snapshot.userSite(pattern) == nil, SitePresets.preset(for: pattern) == nil {
            store.upsertSite(SiteProfile(pattern: pattern, displayName: pattern))
        }
        adding = false
        selection = store.snapshot.userSite(pattern)?.pattern ?? SitePresets.preset(for: pattern)?.pattern ?? pattern
    }
}

/// Editor for one site. Edits are stored as a user profile (copy-on-write over the preset).
struct SiteProfileEditor: View {
    @ObservedObject var store: SettingsStore
    let pattern: String
    var patternChanged: (String) -> Void = { _ in }
    @State private var confirmRemove = false
    @State private var patternDraft = ""

    private var preset: SiteProfile? { SitePresets.preset(for: pattern) }
    private var source: ProfileSource { store.snapshot.siteSource(pattern) }

    private var profile: Binding<SiteProfile> {
        Binding(
            get: {
                store.snapshot.userSite(pattern) ?? preset ?? SiteProfile(pattern: pattern, displayName: pattern)
            },
            set: { store.upsertSite($0) })
    }

    var body: some View {
        Form {
            header
            Section {
                Picker("動作", selection: profile.mode) {
                    ForEach(TranslationMode.allCases) { Text($0.siteLabel).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("動作")
            } footer: {
                Text(profile.wrappedValue.mode.siteDescription)
            }
            Section {
                SettingsPatternListEditor(patterns: profile.includeSelectors, regularExpressions: false)
            } header: {
                Text("翻訳する場所（CSS セレクタ、1 行に 1 つ）")
            } footer: {
                Text("一致した要素の中の文章だけを訳します。空ならページ全体です。例: article、.comment-body、[data-testid=\"tweetText\"]")
            }
            Section {
                SettingsPatternListEditor(patterns: profile.excludeSelectors, regularExpressions: false)
            } header: {
                Text("翻訳しない場所（CSS セレクタ、1 行に 1 つ）")
            } footer: {
                Text("一致した要素の中は、翻訳する場所の中でも訳しません。コード、入力欄、翻訳しない印のある部分は、書かなくても訳しません。")
            }
            Section("翻訳") {
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("文脈（PLaMo に伝える状況の説明。ページのタイトルの前に付けます）")
                    SettingsDraftTextField("文脈", text: profile.context, prompt: "例: Developer documentation", axis: .vertical)
                        .labelsHidden()
                        .lineLimit(1...4)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { patternDraft = profile.wrappedValue.pattern }
        .confirmationDialog(removeTitle, isPresented: $confirmRemove) {
            Button(preset == nil ? "削除" : "プリセットに戻す", role: .destructive) {
                store.removeSite(pattern)
                if preset == nil { patternChanged("") }
            }
        }
    }

    private var header: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "globe").font(.largeTitle).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        SettingsDraftTextField("名前", text: profile.displayName, prompt: "名前")
                            .labelsHidden()
                            .font(.title3.weight(.semibold))
                        badge(source.settingsLabel)
                    }
                    if preset == nil {
                        TextField("サイト", text: $patternDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(renamePattern)
                        if SitePattern.parse(patternDraft) == nil {
                            Label("サイトの書き方が正しくありません", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Text(pattern).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                if source == .user {
                    Button(preset == nil ? "設定を削除…" : "プリセットに戻す…") { confirmRemove = true }
                }
            }
        }
    }

    /// A user site's pattern can change; its settings move with it.
    private func renamePattern() {
        let new = patternDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SitePattern.parse(new) != nil, new != pattern else { return }
        var site = profile.wrappedValue
        site.pattern = new
        store.upsertSite(site, replacing: pattern)
        patternChanged(new)
    }

    private var removeTitle: String {
        preset == nil
            ? "\(profile.wrappedValue.displayName) の設定を削除しますか？"
            : "\(profile.wrappedValue.displayName) の設定をプリセットに戻しますか？"
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
    }
}

extension TranslationMode {
    /// For websites: what each mode does in the browser.
    var siteLabel: String {
        switch self {
        case .off: "オフ"
        case .automatic: "自動"
        case .manual: "手動"
        }
    }

    var siteDescription: String {
        switch self {
        case .off: "このサイトのページは訳しません（YouTube の字幕の翻訳は拡張機能のメニューで切り替えます）。"
        case .automatic:
            "ページを開いたら翻訳します。ブラウザが拡張機能に許可を出すまでは訳せないので、最初に一度だけ、このサイトでブラウザの Plamonic メニューを開いてください（メニューの「このサイトを自動で翻訳」からも自動にできます）。メニューの「一時停止」で、このブラウザでだけ止められます。"
        case .manual: "拡張機能のメニューで「このページを翻訳」を選んだときに翻訳します。"
        }
    }
}
