import SwiftUI

enum RuleGroupKind: String, CaseIterable, Identifiable {
    case containers, items, excludes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: "コンテナ"
        case .items: "項目"
        case .excludes: "除外"
        }
    }

    var explanation: String {
        switch self {
        case .containers: "この中だけを探します。空ならウインドウ全体。ウインドウに見つからないときは、項目が設定されていればウインドウ全体から項目を探します。"
        case .items: "一致した要素を翻訳の単位にします。空なら区切り方の設定で自動的に分けます。"
        case .excludes: "一致した要素とその中身は訳しません（コードブロック、時刻など）。"
        }
    }

    var addButtonTitle: String {
        switch self {
        case .containers: "コンテナに追加"
        case .items: "項目に追加"
        case .excludes: "除外に追加"
        }
    }
}

/// Editor for an app's container / item / exclude matchers, with the "inspect element" helper.
struct RulesEditor: View {
    @Binding var rules: ExtractionRules
    let bundleID: String
    let inspector: (any ElementInspecting)?

    var body: some View {
        MatcherGroupEditor(kind: .containers, matchers: $rules.containers)
        MatcherGroupEditor(kind: .items, matchers: $rules.items)
        MatcherGroupEditor(kind: .excludes, matchers: $rules.excludes)
        ElementInspectorControl(inspector: inspector, expectedBundleID: bundleID) { matcher, kind in
            switch kind {
            case .containers: rules.containers.append(matcher)
            case .items: rules.items.append(matcher)
            case .excludes: rules.excludes.append(matcher)
            }
        }
    }
}

private struct MatcherGroupEditor: View {
    let kind: RuleGroupKind
    @Binding var matchers: [ElementMatcher]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.title).font(.headline)
                Text(kind.explanation).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    matchers.append(ElementMatcher())
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("\(kind.title)のルールを追加")
            }
            if matchers.isEmpty {
                Text("ルールなし").font(.callout).foregroundStyle(.tertiary)
            }
            // Index identity keeps text fields focused while the matcher's value changes.
            ForEach(0..<matchers.count, id: \.self) { index in
                MatcherRowEditor(
                    matcher: Binding(
                        get: { index < matchers.count ? matchers[index] : ElementMatcher() },
                        set: { if index < matchers.count { matchers[index] = $0 } }),
                    onDelete: { if index < matchers.count { matchers.remove(at: index) } })
            }
        }
        .padding(.vertical, 2)
    }
}

private struct MatcherRowEditor: View {
    @Binding var matcher: ElementMatcher
    let onDelete: () -> Void
    @State private var expanded: Bool

    init(matcher: Binding<ElementMatcher>, onDelete: @escaping () -> Void) {
        self._matcher = matcher
        self.onDelete = onDelete
        self._expanded = State(initialValue: matcher.wrappedValue.isEmpty)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                SettingsTokenListField("役割（AXRole）", values: $matcher.roles, prompt: "AXGroup, AXTextArea")
                SettingsTokenListField("サブロール（AXSubrole）", values: $matcher.subroles, prompt: "AXDocument")
                SettingsTokenListField(
                    "DOM クラスの接頭辞", values: $matcher.domClassPrefixes, prompt: "p-rich_text_section, messageContent_")
                SettingsTokenListField("識別子の接頭辞（AXIdentifier）", values: $matcher.identifierPrefixes)
                SettingsTokenListField(
                    "役割の説明（AXRoleDescription）", values: $matcher.roleDescriptions, prompt: "言語設定で変わるため非推奨")
            }
            .padding(.leading, 4)
            .padding(.top, 4)
        } label: {
            HStack {
                Text(matcher.isEmpty ? "（空のルール: 何にも一致しません）" : RuleSuggestions.summary(of: matcher))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(matcher.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("このルールを削除")
            }
        }
    }
}
