import AppKit
import SwiftUI

extension View {
    /// Writes a free-text field's draft back to the settings when editing ends, not on every keystroke:
    /// the live session re-reads the settings after every change, and a half-typed context, glossary term,
    /// class prefix or ignore pattern would re-translate, or hide, everything on screen while the user types.
    /// Editing ends on focus loss, when a window resigns key (the user goes to look at the translated app),
    /// when the field goes away, and when the store saves for good (`SettingsStore.flush()`).
    /// `commit` must do nothing when the draft equals the stored value.
    func settingsDraftCommit(isFocused: Bool, _ commit: @escaping () -> Void) -> some View {
        self
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onDisappear(perform: commit)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in commit() }
            .onReceive(NotificationCenter.default.publisher(for: SettingsStore.willFlushNotification)) { _ in commit() }
    }
}

/// A text field whose edits reach the binding on Return or when editing ends (see `settingsDraftCommit`).
struct SettingsDraftTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String = ""
    var axis: Axis = .horizontal
    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>, prompt: String = "", axis: Axis = .horizontal) {
        self.title = title
        self._text = text
        self.prompt = prompt
        self.axis = axis
        self._draft = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        TextField(title, text: $draft, prompt: Text(prompt), axis: axis)
            .focused($isFocused)
            .onSubmit(commit)
            .settingsDraftCommit(isFocused: isFocused, commit)
            .onChange(of: text) { _, newText in
                // Changed elsewhere (reset to the preset, an import): show it.
                if newText != draft { draft = newText }
            }
    }

    private func commit() {
        if draft != text { text = draft }
    }
}

/// Edits a string list as comma-separated text. Keeps its own text so typing "a," is not reformatted mid-edit,
/// and commits it on Return or when editing ends.
struct SettingsTokenListField: View {
    let title: String
    @Binding var values: [String]
    var prompt: String = ""
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(_ title: String, values: Binding<[String]>, prompt: String = "") {
        self.title = title
        self._values = values
        self.prompt = prompt
        self._text = State(initialValue: Self.join(values.wrappedValue))
    }

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .focused($isFocused)
            .onSubmit(commit)
            .settingsDraftCommit(isFocused: isFocused, commit)
            .onChange(of: values) { _, newValues in
                if Self.parse(text) != newValues { text = Self.join(newValues) }
            }
    }

    private func commit() {
        let parsed = Self.parse(text)
        if parsed != values { values = parsed }
    }

    static func parse(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func join(_ values: [String]) -> String { values.joined(separator: ", ") }
}

/// Edits a list of regular expressions, one per line, and flags the ones that do not compile.
/// Return starts a new line, so the list is committed when editing ends.
struct SettingsPatternListEditor: View {
    @Binding var patterns: [String]
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(patterns: Binding<[String]>) {
        self._patterns = patterns
        self._text = State(initialValue: patterns.wrappedValue.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90, maxHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
                .focused($isFocused)
                .settingsDraftCommit(isFocused: isFocused, commit)
                .onChange(of: patterns) { _, newPatterns in
                    if Self.parse(text) != newPatterns { text = newPatterns.joined(separator: "\n") }
                }
            let invalid = RuleSuggestions.invalidPatterns(Self.parse(text))
            if !invalid.isEmpty {
                Label("正規表現として読めない行があります: \(invalid.joined(separator: "  "))", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    static func parse(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func commit() {
        let parsed = Self.parse(text)
        if parsed != patterns { patterns = parsed }
    }
}

/// Source -> target rows with add / delete. A row is committed as a whole when editing it ends.
struct SettingsGlossaryEditor: View {
    @Binding var terms: [GlossaryTerm]

    var body: some View {
        if terms.isEmpty {
            Text("用語はまだありません。").foregroundStyle(.secondary)
        }
        ForEach(terms) { term in
            GlossaryTermRow(
                term: term,
                onCommit: { edited in
                    // By id: the row may have been deleted or moved since it was drawn.
                    guard let index = terms.firstIndex(where: { $0.id == edited.id }), terms[index] != edited else {
                        return
                    }
                    terms[index] = edited
                },
                onDelete: { terms.removeAll { $0.id == term.id } })
        }
        Button {
            terms.append(GlossaryTerm(source: "", target: ""))
        } label: {
            Label("用語を追加", systemImage: "plus")
        }
    }
}

private struct GlossaryTermRow: View {
    let term: GlossaryTerm
    let onCommit: (GlossaryTerm) -> Void
    let onDelete: () -> Void
    @State private var source: String
    @State private var target: String
    @FocusState private var focus: Field?

    private enum Field { case source, target }

    init(term: GlossaryTerm, onCommit: @escaping (GlossaryTerm) -> Void, onDelete: @escaping () -> Void) {
        self.term = term
        self.onCommit = onCommit
        self.onDelete = onDelete
        self._source = State(initialValue: term.source)
        self._target = State(initialValue: term.target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                TextField("原語", text: $source, prompt: Text("原語"))
                    .labelsHidden()
                    .focused($focus, equals: .source)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("訳語", text: $target, prompt: Text("訳語"))
                    .labelsHidden()
                    .focused($focus, equals: .target)
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("この用語を削除")
            }
            if missingTarget {
                Label("訳語が空のあいだ、この用語は使われません。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onSubmit(commit)
        // Moving from the source to the target field does not commit: the term is used once both are typed.
        .settingsDraftCommit(isFocused: focus != nil, commit)
        .onChange(of: term) { _, newTerm in
            // Changed elsewhere (an import updated the target): show it.
            if newTerm.source != source || newTerm.target != target {
                source = newTerm.source
                target = newTerm.target
            }
        }
    }

    /// A committed term with a source but no target (PLaMo cannot use it), once the row is not being edited.
    private var missingTarget: Bool {
        focus == nil && !term.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !term.isUsable
    }

    private func commit() {
        var edited = term
        edited.source = source
        edited.target = target
        if edited != term { onCommit(edited) }
    }
}

/// App icons by bundle ID (looked up once through Launch Services).
@MainActor
final class SettingsAppIconCache {
    static let shared = SettingsAppIconCache()
    private var icons: [String: NSImage] = [:]
    private var misses: Set<String> = []

    func icon(for bundleID: String, preferred: NSImage? = nil) -> NSImage? {
        if let preferred { return preferred }
        if let cached = icons[bundleID] { return cached }
        if misses.contains(bundleID) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            misses.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}

struct SettingsAppIcon: View {
    let bundleID: String
    var preferred: NSImage? = nil
    var size: CGFloat = 20

    var body: some View {
        if let image = SettingsAppIconCache.shared.icon(for: bundleID, preferred: preferred) {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

enum SettingsFormat {
    static func gigabytes(_ value: Double) -> String {
        String(format: "%.1f GB", value)
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.1f 秒", value)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded())) %"
    }

    static var physicalMemoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }
}
