import AppKit
import SwiftUI

/// "要素を調べる" button: waits 3 seconds, inspects the element under the mouse and opens the matcher builder.
struct ElementInspectorControl: View {
    let inspector: (any ElementInspecting)?
    let expectedBundleID: String
    let onAdd: (ElementMatcher, RuleGroupKind) -> Void

    @State private var countdown: Int?
    @State private var result: InspectionResult?
    @State private var failure: String?

    private static let delaySeconds = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    start()
                } label: {
                    Label(countdown.map { "\($0) 秒後に調べます…" } ?? "要素を調べる…", systemImage: "scope")
                }
                .disabled(inspector == nil || countdown != nil)
                Spacer()
            }
            Text(
                inspector == nil
                    ? "要素を調べる機能は現在使えません。"
                    : "ボタンを押してから \(Self.delaySeconds) 秒以内に、対象のアプリで調べたいテキストの上にマウスを置いてください。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.orange)
            }
        }
        .sheet(item: $result) { result in
            ElementInspectorSheet(inspected: result.element, expectedBundleID: expectedBundleID, onAdd: onAdd)
        }
    }

    private func start() {
        guard let inspector else { return }
        let box = InspectorBox(inspector: inspector)
        failure = nil
        Task { @MainActor in
            for remaining in stride(from: Self.delaySeconds, to: 0, by: -1) {
                countdown = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            countdown = nil
            let point = Self.axPoint(fromCocoa: NSEvent.mouseLocation)
            // AX hit-testing is IPC to another process; keep it off the main thread.
            let found = await Task.detached(priority: .userInitiated) {
                box.inspector.inspectElement(atAX: point)
            }.value
            if let found, !found.path.isEmpty {
                result = InspectionResult(element: found)
            } else {
                failure = "マウスの下に要素が見つかりませんでした。アクセシビリティの権限と、マウスの位置を確認してください。"
            }
        }
    }

    /// Cocoa global (bottom-left origin) -> AX global (top-left of the primary screen).
    private static func axPoint(fromCocoa point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private struct InspectionResult: Identifiable {
        let id = UUID()
        let element: InspectedElement
    }

    private final class InspectorBox: @unchecked Sendable {
        let inspector: any ElementInspecting
        init(inspector: any ElementInspecting) { self.inspector = inspector }
    }
}

/// Shows the inspected element and its ancestors, and turns one of them into a matcher.
struct ElementInspectorSheet: View {
    let inspected: InspectedElement
    let expectedBundleID: String
    let onAdd: (ElementMatcher, RuleGroupKind) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int?
    @State private var draft: ElementMatcher
    @State private var addedMessage: String?

    init(inspected: InspectedElement, expectedBundleID: String, onAdd: @escaping (ElementMatcher, RuleGroupKind) -> Void) {
        self.inspected = inspected
        self.expectedBundleID = expectedBundleID
        self.onAdd = onAdd
        self._selectedIndex = State(initialValue: inspected.path.isEmpty ? nil : 0)
        self._draft = State(initialValue: inspected.path.first.map(RuleSuggestions.defaultMatcher) ?? ElementMatcher())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("調べた要素").font(.title3.weight(.semibold))
                Text("\(inspected.appName)（\(inspected.bundleID)）").font(.caption).foregroundStyle(.secondary)
            }
            if inspected.bundleID.caseInsensitiveCompare(expectedBundleID) != .orderedSame {
                Label("いま設定しているアプリ（\(expectedBundleID)）とは別のアプリの要素です。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 12) {
                List(selection: $selectedIndex) {
                    ForEach(Array(inspected.path.enumerated()), id: \.offset) { index, element in
                        PathRow(element: element, depth: index).tag(Optional(index))
                    }
                }
                .frame(width: 320)
                .listStyle(.bordered)

                if let element = selectedElement {
                    builder(for: element)
                } else {
                    Text("左から要素を選んでください。").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            HStack {
                if let addedMessage { Text(addedMessage).foregroundStyle(.secondary) }
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 860, height: 540)
        .onChange(of: selectedIndex) { _, index in
            if let index, index < inspected.path.count {
                draft = RuleSuggestions.defaultMatcher(for: inspected.path[index])
            }
        }
    }

    private var selectedElement: ElementDescriptor? {
        guard let selectedIndex, selectedIndex < inspected.path.count else { return nil }
        return inspected.path[selectedIndex]
    }

    private func builder(for element: ElementDescriptor) -> some View {
        Form {
            Section("この要素に一致させる条件") {
                Toggle("役割: \(element.role)", isOn: membership(element.role, in: \.roles))
                if let subrole = element.subrole, !subrole.isEmpty {
                    Toggle("サブロール: \(subrole)", isOn: membership(subrole, in: \.subroles))
                }
                if let identifier = element.identifier, !identifier.isEmpty {
                    Toggle("識別子の接頭辞: \(identifier)", isOn: membership(identifier, in: \.identifierPrefixes))
                }
                if let description = element.roleDescription, !description.isEmpty {
                    Toggle(isOn: membership(description, in: \.roleDescriptions)) {
                        VStack(alignment: .leading) {
                            Text("役割の説明: \(description)")
                            Text("言語設定で変わることがあるため、できるだけ使わないでください。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !element.domClasses.isEmpty {
                Section("DOM クラスの接頭辞（どれか 1 つに一致）") {
                    ForEach(uniquePrefixes(element.domClasses), id: \.self) { prefix in
                        Toggle(isOn: membership(prefix, in: \.domClassPrefixes)) {
                            Text(prefix).font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }
            Section("要素の情報") {
                if !element.textPreview.isEmpty {
                    LabeledContent("テキスト", value: element.textPreview)
                }
                if let frame = element.axFrame {
                    LabeledContent(
                        "位置とサイズ",
                        value: "x \(Int(frame.minX)), y \(Int(frame.minY)), \(Int(frame.width)) × \(Int(frame.height))")
                }
                LabeledContent("ルール") {
                    Text(draft.isEmpty ? "（条件を選んでください）" : RuleSuggestions.summary(of: draft))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Section {
                HStack {
                    ForEach(RuleGroupKind.allCases) { kind in
                        Button(kind.addButtonTitle) {
                            onAdd(draft, kind)
                            addedMessage = "\(kind.title)に追加しました: \(RuleSuggestions.summary(of: draft))"
                        }
                        .disabled(draft.isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func membership(_ value: String, in keyPath: WritableKeyPath<ElementMatcher, [String]>) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: keyPath].contains(value) },
            set: { on in
                draft[keyPath: keyPath].removeAll { $0 == value }
                if on { draft[keyPath: keyPath].append(value) }
            })
    }

    private func uniquePrefixes(_ classes: [String]) -> [String] {
        var seen = Set<String>()
        return classes.map(RuleSuggestions.suggestedPrefix(forClass:)).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

private struct PathRow: View {
    let element: ElementDescriptor
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(depth == 0 ? "▶︎" : "↑\(depth)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .leading)
                Text(element.subrole.map { "\(element.role)/\($0)" } ?? element.role)
                    .font(.system(.callout, design: .monospaced))
            }
            if !element.domClasses.isEmpty {
                Text(element.domClasses.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 28)
            }
            if !element.textPreview.isEmpty {
                Text(element.textPreview)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 2)
    }
}
