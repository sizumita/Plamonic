import AppKit
import SwiftUI

struct DisplaySettingsPane: View {
    @ObservedObject var store: SettingsStore
    var actions: SettingsUIActions = SettingsUIActions()
    /// nil = the app cannot tell (no hook).
    @State private var screenRecordingAuthorized: Bool?

    private var appearance: Binding<OverlayAppearance> { $store.global.appearance }

    var body: some View {
        Form {
            Section {
                Picker("表示スタイル", selection: $store.global.displayStyle) {
                    ForEach(DisplayStyle.allCases) { Text($0.settingsLabel).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("「原文に重ねる」は訳文を原文の位置に重ねます。「マウスの下だけ表示」はマウスを置いたブロックの訳文だけをポップアップします。")
            }

            Section {
                Toggle("原文の見た目に合わせる", isOn: appearance.matchOriginalStyle)
                Toggle("背景色を画面から取る", isOn: appearance.matchBackgroundFromScreen)
                if store.global.appearance.matchBackgroundFromScreen {
                    LabeledContent("画面収録の許可") { screenRecordingStatus }
                }
            } header: {
                Text("原文になじませる")
            } footer: {
                Text("「原文の見た目に合わせる」は、アプリが公開している原文の文字の大きさ・行間・文字色を使い、原文の 1 行目の位置から訳文を書きます（ターミナルでは等幅の文字）。収まらないときは下の空きに行を足し、それでも入らなければ少し縮めて末尾を「…」にします（マウスを少し置くと全文を吹き出しで表示）。ほかの段落にも、訳さない名前・時刻・ボタン・枠線にも重ねません。\n「背景色を画面から取る」は、訳す対象のウインドウの画素から背景色と文字色を測ります。画面収録の許可が必要です。取り込んだ画像は色を測るだけで、保存も送信もしません。許可がないときは、原文の文字色から明るい背景か暗い背景かを決めてテーマの色を使います。ターミナルのように文字色を公開していないアプリでは、テーマ（「システムに合わせる」ならシステムの外観）の色になるので、配色が違うときは画面収録を許可するかテーマを選んでください。")
            }

            Section {
                OverlayPreview(appearance: store.global.appearance, screenColors: usesScreenColors)
                    .frame(maxWidth: .infinity)
            } header: {
                Text("プレビュー")
            } footer: {
                Text(previewCaption)
            }

            Section {
                Picker("テーマ", selection: appearance.theme) {
                    ForEach(OverlayTheme.allCases) { Text($0.settingsLabel).tag($0) }
                }
                LabeledContent("背景の不透明度") {
                    HStack {
                        Slider(value: appearance.backgroundOpacity, in: SettingsLimits.backgroundOpacity)
                            .frame(maxWidth: 220)
                        Text(SettingsFormat.percent(store.global.appearance.backgroundOpacity))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                Stepper(value: appearance.minFontSize, in: SettingsLimits.fontSize, step: 1) {
                    LabeledContent("最小の文字サイズ", value: "\(Int(store.global.appearance.minFontSize)) pt")
                }
                Stepper(value: appearance.maxFontSize, in: SettingsLimits.fontSize, step: 1) {
                    LabeledContent("最大の文字サイズ", value: "\(Int(store.global.appearance.maxFontSize)) pt")
                }
                Stepper(value: appearance.cornerRadius, in: SettingsLimits.cornerRadius, step: 1) {
                    LabeledContent("角の丸み", value: "\(Int(store.global.appearance.cornerRadius)) pt")
                }
                Toggle("下書きの印を表示する（小さな点）", isOn: appearance.showStateIndicator)
            } header: {
                Text("見た目")
            } footer: {
                Text("文字サイズの範囲は、原文の文字の大きさが分からないとき（「原文の見た目に合わせる」がオフのときも）だけ使い、訳文が原文の範囲に収まるようにこの間で調整します。テーマは画面から色を取れないときの色です。下書きの印はあとで翻訳モデルの訳に差し替わる訳文に付きます。")
            }

            Section {
                Picker("押している間は原文を表示", selection: $store.global.showOriginalModifier) {
                    ForEach(ModifierKey.allCases) { Text($0.settingsLabel).tag($0) }
                }
                Toggle("スクロール中は訳文を隠す", isOn: $store.global.hideWhileScrolling)
            } header: {
                Text("操作")
            } footer: {
                Text("スクロールやウインドウの移動が止まると、すぐに読み直して表示し直します。")
            }

            interactionSection
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshScreenRecording)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Coming back from System Settings.
            refreshScreenRecording()
        }
    }

    // MARK: - ポインタとリンク

    private var interactionSection: some View {
        let interaction = $store.global.interaction
        let current = store.global.interaction
        return Section {
            Group {
                Picker("ポインタを置いたとき", selection: interaction.hoverOriginal) {
                    ForEach(HoverOriginalMode.allCases) { Text($0.settingsLabel).tag($0) }
                }
                Stepper(value: interaction.hoverDelay, in: SettingsLimits.hoverDelay, step: 0.1) {
                    LabeledContent("待ち時間", value: SettingsFormat.seconds(current.hoverDelay))
                }
                .disabled(current.hoverOriginal == .off)
                Toggle("訳文のリンクを押せるようにする", isOn: interaction.clickableLinks)
            }
            .disabled(!store.snapshot.isReplaceStyleInUse)
            if let note = displayStyleNote {
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("ポインタとリンク")
        } footer: {
            Text(interactionFooter)
        }
    }

    /// These settings apply to 原文に重ねる only; says where they do not (or, under マウスの下だけ表示, where they do).
    private var displayStyleNote: String? {
        let replace = DisplayStyle.replace.settingsLabel
        let hover = DisplayStyle.hover.settingsLabel
        let snapshot = store.snapshot
        func names(_ apps: [AppProfile]) -> String {
            apps.map { "「\($0.displayName)」" }.joined(separator: "、")
        }
        if store.global.displayStyle == .hover {
            let apps = snapshot.appsOverridingDisplayStyle(to: .replace)
            return apps.isEmpty
                ? "表示スタイルが「\(hover)」のあいだは使いません。「\(replace)」にすると使えます。"
                : "表示スタイルは「\(hover)」ですが、\(names(apps))では「\(replace)」なので、この設定を使います。"
        }
        let apps = snapshot.appsOverridingDisplayStyle(to: .hover)
        return apps.isEmpty ? nil : "\(names(apps))は「\(hover)」なので、この設定を使いません。"
    }

    /// What clickable links do (the footer's link part).
    static let linksDescription =
        "訳文の中のリンクの部分だけを原文のリンクの色で書き、押すと原文のリンクと同じように開きます。リンクの上ではカーソルが指の形になり、下線が出ます（もともと下線のあるリンクは色が少し変わります）。右クリックすると原文のリンクのメニューが出ます。訳文の下に隠れた原文のリンクは押されず（ネイティブアプリのテキスト表示の中のリンクは除く）、そこをクリックするとその場で原文が見えます。オフにするとリンクの色付けもせず、訳文の上のクリックはすべて下のアプリに届きます。"

    private var interactionFooter: String {
        let g = store.global
        var text =
            g.interaction.hoverOriginal.settingsDescription
            + "末尾を「…」で切った訳文は、どの設定でも全文と原文を吹き出しで表示します。\n"
            + Self.linksDescription
        if g.showOriginalModifier != .none {
            text += "\n\(g.showOriginalModifier.settingsLabel) を押している間は、ポインタの位置に関係なくすべての原文が見えます。"
        }
        return text
    }

    @ViewBuilder
    private var screenRecordingStatus: some View {
        HStack {
            switch screenRecordingAuthorized {
            case true?:
                Label("許可されています", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case false?:
                Label("許可されていません", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case nil:
                Text("確認できません").foregroundStyle(.secondary)
            }
            if screenRecordingAuthorized != true, let request = actions.requestScreenRecording {
                Button("許可する…") {
                    request()
                    refreshScreenRecording()
                }
                .help("システム設定の「画面収録」で Plamonic を許可します。許可したあと Plamonic の再起動が必要なことがあります。")
            }
        }
    }

    private var previewCaption: String {
        let a = store.global.appearance
        let size = a.matchOriginalStyle ? "原文と同じ大きさと文字色" : "文字サイズの範囲とテーマの文字色"
        let background =
            usesScreenColors
            ? "背景はウインドウから測った色"
            : a.matchBackgroundFromScreen && screenRecordingAuthorized != true
                ? "画面収録の許可がないので背景はテーマの色" : "背景はテーマの色"
        return "架空のアプリに重ねた例です（\(size)、\(background)）。"
    }

    /// Colors come from the window's pixels only when the setting is on and macOS allows it.
    private var usesScreenColors: Bool {
        store.global.appearance.matchBackgroundFromScreen && screenRecordingAuthorized == true
    }

    private func refreshScreenRecording() {
        screenRecordingAuthorized = actions.screenRecordingAuthorized?()
    }
}

/// Rough preview of translations drawn over a made-up app window; the real drawing lives in the Overlay module.
/// Shows what the switches change: size and color taken from the original or not, background taken from
/// the window or from the theme, and that each translation stays inside its own paragraph.
private struct OverlayPreview: View {
    let appearance: OverlayAppearance
    let screenColors: Bool
    @Environment(\.colorScheme) private var colorScheme

    private static let originalSize: Double = 13
    private static let paragraphs: [(original: String, translation: String, isDraft: Bool)] = [
        (
            "The quick brown fox jumps over the lazy dog. It was a bright, sunny afternoon.",
            "すばやい茶色の狐がのろまな犬を飛び越えた。よく晴れた明るい午後のことだった。", false
        ),
        ("Translations never cover the next paragraph.", "訳文が次の段落にかぶることはありません。", true),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.paragraphs.indices, id: \.self) { index in
                let paragraph = Self.paragraphs[index]
                Text(paragraph.original)
                    .font(.system(size: Self.originalSize))
                    .foregroundStyle(appText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(alignment: .topLeading) {
                        translation(paragraph.translation, isDraft: paragraph.isDraft)
                    }
            }
        }
        .multilineTextAlignment(.leading)
        .padding(10)
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(appBackground))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private func translation(_ text: String, isDraft: Bool) -> some View {
        Text(text)
            .font(.system(size: fontSize))
            .foregroundStyle(appearance.matchOriginalStyle ? appText : themeText)
            .minimumScaleFactor(appearance.matchOriginalStyle ? 0.85 : min(1, appearance.minFontSize / fontSize))
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(overlayBackground.opacity(appearance.backgroundOpacity))
            )
            .overlay(alignment: .topTrailing) {
                if isDraft, appearance.showStateIndicator {
                    Circle().fill(themeAccent).frame(width: 4, height: 4).padding(1)
                }
            }
    }

    /// Clamped like OverlayLayout.effectiveCornerRadius, so the preview shows the corner the overlay draws.
    private var cornerRadius: Double {
        min(max(0, appearance.cornerRadius), SettingsLimits.cornerRadius.upperBound)
    }

    /// The original size when the app reports it; otherwise somewhere in the user's range.
    private var fontSize: Double {
        if appearance.matchOriginalStyle { return Self.originalSize }
        return min(max(Self.originalSize, appearance.minFontSize), appearance.maxFontSize)
    }

    // The made-up app follows the system appearance.
    private var appIsDark: Bool { colorScheme == .dark }
    private var appBackground: Color {
        appIsDark ? Color(red: 0.17, green: 0.17, blue: 0.19) : Color(red: 0.97, green: 0.96, blue: 0.94)
    }
    private var appText: Color { appIsDark ? Color(white: 0.86) : Color(white: 0.16) }

    /// Without screen colors the overlay uses theme colors; matching the original picks light or dark
    /// from the original text color, as the overlay does.
    private var overlayIsDark: Bool {
        if appearance.matchOriginalStyle { return appIsDark }
        switch appearance.theme {
        case .system: return appIsDark
        case .light: return false
        case .dark: return true
        }
    }
    private var overlayBackground: Color {
        if screenColors { return appBackground }
        return overlayIsDark ? Color(red: 0.125, green: 0.125, blue: 0.137) : Color(red: 0.988, green: 0.988, blue: 0.98)
    }
    private var themeText: Color { overlayIsDark ? Color(white: 0.95) : Color(white: 0.1) }
    private var themeAccent: Color { overlayIsDark ? Color(red: 0.39, green: 0.68, blue: 1) : Color(red: 0, green: 0.42, blue: 0.85) }
}
