import Foundation

// Japanese labels for the settings enums. Other modules (menu bar, onboarding) may reuse them.

extension TranslationMode {
    var settingsLabel: String {
        switch self {
        case .off: "オフ"
        case .automatic: "自動"
        case .manual: "手動"
        }
    }

    var settingsDescription: String {
        switch self {
        case .off: "このアプリは翻訳しません。"
        case .automatic: "画面の変化に合わせてリアルタイムに翻訳します。"
        case .manual: "「今すぐ翻訳」のホットキーを押したときだけ翻訳します。"
        }
    }
}

extension TranslationScope {
    var settingsLabel: String {
        switch self {
        case .window: "ウインドウ全体"
        case .rules: "ルールで指定した部分"
        case .focusedElement: "フォーカス中の要素"
        case .underMouse: "マウスの下のブロック"
        case .selection: "選択したテキスト"
        }
    }
}

extension SegmentGranularity {
    var settingsLabel: String {
        switch self {
        case .paragraph: "段落ごと"
        case .element: "要素ごと"
        case .item: "項目ごと"
        }
    }

    var settingsDescription: String {
        switch self {
        case .paragraph: "リンクや太字などのインライン要素を親ブロックでまとめて 1 つの段落として訳します。"
        case .element: "テキスト要素を 1 つずつ別々に訳します。"
        case .item: "ルールの「項目」に一致した要素の中身をまとめて 1 つとして訳します。"
        }
    }
}

extension TextAreaHandling {
    var settingsLabel: String {
        switch self {
        case .whole: "全体をひとまとめ"
        case .paragraphs: "段落ごと"
        case .terminal: "ターミナル"
        }
    }

    var settingsDescription: String {
        switch self {
        case .whole: "テキスト領域の内容全体を 1 つとして訳します。"
        case .paragraphs: "空行や改行で段落に分けて、段落ごとの位置に訳文を重ねます。"
        case .terminal: "見えている行だけを対象にし、折り返しをつなぎ直し、TUI の罫線やスピナーを除きます。"
        }
    }
}

extension DisplayStyle {
    var settingsLabel: String {
        switch self {
        case .replace: "原文に重ねる"
        case .hover: "マウスの下だけ表示"
        }
    }
}

extension JapaneseFormSetting {
    var settingsLabel: String {
        switch self {
        case .auto: "自動"
        case .plain: "常体（だ・である）"
        case .polite: "敬体（です・ます）"
        }
    }
}

extension SameLanguagePolicy {
    var settingsLabel: String {
        switch self {
        case .skip: "訳さない"
        case .translate: "訳す"
        }
    }
}

extension ModifierKey {
    var settingsLabel: String {
        switch self {
        case .none: "なし"
        case .option: "⌥ Option"
        case .control: "⌃ Control"
        case .command: "⌘ Command"
        case .shift: "⇧ Shift"
        case .function: "fn"
        }
    }
}

extension HoverOriginalMode {
    var settingsLabel: String {
        switch self {
        case .inPlace: "その場で原文を見せる"
        case .popup: "吹き出しで原文を見せる"
        case .off: "何もしない"
        }
    }

    var settingsDescription: String {
        switch self {
        case .inPlace:
            "ポインタを動かして訳文の上で止めると、その訳文が消えて下の原文が見えます（原文のリンクもそのまま押せます）。ポインタが離れると訳文に戻ります。"
        case .popup: "ポインタを動かして訳文の上で止めると、訳文を残したまま原文を吹き出しで表示します。ポインタが離れると消えます。"
        case .off: "ポインタを置いても原文は表示しません。"
        }
    }
}

extension OverlayTheme {
    var settingsLabel: String {
        switch self {
        case .system: "システムに合わせる"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }
}

extension ProfileSource {
    var settingsLabel: String {
        switch self {
        case .user: "カスタム"
        case .preset: "プリセット"
        case .defaults: "未設定"
        }
    }
}

extension PresetVerification {
    var settingsLabel: String {
        switch self {
        case .verified: "動作確認済み"
        case .unverified: "未検証"
        case .unsupported: "非対応"
        }
    }
}

/// Labels for an app's 段階翻訳 override (nil = follow the global switch).
enum ProgressiveOverrideLabel {
    static func label(_ isEnabled: Bool) -> String { isEnabled ? "使う" : "使わない" }

    static func label(_ override: Bool?, global: Bool) -> String {
        override.map { label($0) } ?? "全体の設定に従う（\(label(global))）"
    }
}
