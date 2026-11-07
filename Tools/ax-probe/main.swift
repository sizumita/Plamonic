import AppKit
import ApplicationServices
import Foundation

// ax-probe: runs Plamonic's Accessibility + Extraction layers against a live app from the command line.
// Text from other apps is masked unless --show-text is given (letters -> x / 字, digits -> 9).

let usage = """
    usage:
      ax-probe --selftest
      ax-probe --list-presets
      ax-probe <bundleID> [options]

    options:
      --rules <preset>         slack | discord | claude | opencode | terminal | ghostty | webchat | none
                               (default: the preset for the bundle ID, else none)
      --scope <scope>          window | rules | focusedElement | underMouse | selection
      --granularity <g>        paragraph | element | item
      --textarea <mode>        whole | paragraphs | terminal
      --controls / --editable  include controls / editable text
      --mouse x,y              pointer for --scope underMouse (default: current pointer)
      --repeat N               scan N times (shows container caching and steady-state timing)
      --rejected               list rejected candidates with the reason
      --obstacles              list the frames of the obstacles (no text)
      --links                  list each segment's links (range, kind, URL, frames, color; masked unless --show-text)
      --show-text              print real text (only for the user's own inspection)
      --full-text              print whole segments instead of the first 90 characters
      --tree [depth]           dump the window's AX tree (masked) instead of scanning
      --inspect x,y            AXInspector path at an AX point
      --events seconds         print AXEventHub notifications for a while
      --max-nodes N, --time-budget ms
      --pid N                  probe this process (several instances share a bundle ID, e.g. a fixture browser)
      --window-title text      scan the window whose title contains `text` (default: the focused window)
      --keep-enabled           leave AXManualAccessibility on at exit when the probe switched it on
    """

func mask(_ s: String) -> String {
    String(
        s.map { c -> Character in
            if c == "\n" { return "⏎" }
            if c.isNumber { return "9" }
            if c.isLetter { return c.isASCII ? "x" : "字" }
            return c
        })
}

var showText = false
func shown(_ s: String, limit: Int = 90) -> String {
    let t = showText ? s.replacingOccurrences(of: "\n", with: "⏎") : mask(s)
    return t.count > limit ? String(t.prefix(limit - 1)) + "…" : t
}

func fmt(_ r: CGRect?) -> String {
    guard let r else { return "[-]" }
    return "[\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))]"
}

func ms(_ t: TimeInterval) -> String { String(format: "%.1f ms", t * 1000) }

/// "14pt/26 mono rgb(194,192,182) L3": size / line pitch, monospaced, color, number of line frames.
func describe(_ s: TextStyleHint, lines: Int) -> String {
    var out = s.fontSize.map { String(format: "%gpt", $0) } ?? "?pt"
    out += "/" + (s.lineHeight.map { String(format: "%g", ($0 * 10).rounded() / 10) } ?? "?")
    if s.isMonospaced { out += " mono" }
    if let c = s.textColor {
        out += String(format: " rgb(%d,%d,%d)", Int(c.red * 255), Int(c.green * 255), Int(c.blue * 255))
    }
    if lines > 0 { out += " L\(lines)" }
    return out
}

func parsePoint(_ s: String) -> CGPoint? {
    let parts = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
}

// MARK: Arguments

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("--help") || args.contains("-h") {
    print(usage)
    exit(args.isEmpty ? 1 : 0)
}
if args.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}
if args.contains("--list-presets") {
    for p in ProbePresets.all {
        var profile = AppProfile(bundleID: "x", displayName: "x")
        p.apply(&profile)
        print("\(p.name): bundles=\(p.bundleIDs) scope=\(profile.scope.rawValue) textArea=\(profile.textAreaHandling.rawValue)")
        print("  containers: \(profile.rules.containers)")
        print("  items:      \(profile.rules.items)")
        print("  excludes:   \(profile.rules.excludes)")
    }
    exit(0)
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

showText = args.contains("--show-text")
let bundleID = args[0]
guard AccessibilityPermission.isTrusted else {
    print("Accessibility permission is missing for this process.")
    exit(2)
}
let requestedPID = option("--pid").flatMap { pid_t($0) }
guard
    let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == bundleID && (requestedPID == nil || $0.processIdentifier == requestedPID)
    })
else {
    print("\(bundleID) is not running" + (requestedPID.map { " as pid \($0)" } ?? ""))
    exit(1)
}
let pid = app.processIdentifier

// MARK: Inspect / events

if let pointArg = option("--inspect") {
    guard let point = parsePoint(pointArg) else {
        print("bad point")
        exit(1)
    }
    let inspector = AXInspector()
    guard let result = inspector.inspectElement(atAX: point) else {
        print("nothing at \(point)")
        exit(1)
    }
    print("\(result.appName) (\(result.bundleID))")
    for (i, d) in result.path.enumerated() {
        var line = String(repeating: " ", count: i) + d.role
        if let s = d.subrole { line += "/" + s }
        if let id = d.identifier { line += " id=\(id)" }
        if !d.domClasses.isEmpty { line += " dom=" + d.domClasses.prefix(6).joined(separator: ",") }
        line += " " + fmt(d.axFrame)
        if !d.textPreview.isEmpty { line += " \"" + shown(d.textPreview, limit: 40) + "\"" }
        print(line)
    }
    exit(0)
}

if let secondsArg = option("--events"), let seconds = Double(secondsArg) {
    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var counts: [AXEventKind: Int] = [:]
        func add(_ k: AXEventKind) {
            lock.lock()
            counts[k, default: 0] += 1
            lock.unlock()
        }
    }
    let counter = Counter()
    let hub = AXEventHub { event in counter.add(event.kind) }
    let accepted = hub.observe(pid: pid)
    print("observing pid \(pid); accepted: \(accepted.map(\.rawValue).sorted())")
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    hub.stop()
    for (k, n) in counter.counts.sorted(by: { $0.value > $1.value }) { print("  \(k.rawValue): \(n)") }
    exit(0)
}

// MARK: Profile

var profile = AppProfile(bundleID: bundleID, displayName: app.localizedName ?? bundleID)
let presetName = option("--rules") ?? ProbePresets.forBundle(bundleID)?.name ?? "none"
guard let preset = ProbePresets.named(presetName) else {
    print("unknown preset \(presetName)")
    exit(1)
}
preset.apply(&profile)
if let s = option("--scope") {
    guard let v = TranslationScope(rawValue: s) else {
        print("bad scope")
        exit(1)
    }
    profile.scope = v
}
if let g = option("--granularity") {
    guard let v = SegmentGranularity(rawValue: g) else {
        print("bad granularity")
        exit(1)
    }
    profile.granularity = v
}
if let t = option("--textarea") {
    guard let v = TextAreaHandling(rawValue: t) else {
        print("bad textarea mode")
        exit(1)
    }
    profile.textAreaHandling = v
}
if args.contains("--controls") { profile.includeControls = true }
if args.contains("--editable") { profile.includeEditableText = true }

var global = GlobalSettings()
global.defaultMode = .automatic
let settings = EffectiveSettings(profile: profile, global: global)
var limits = ExtractionLimits(global: global)
if let n = option("--max-nodes").flatMap(Int.init) { limits.maxNodes = n }
if let t = option("--time-budget").flatMap(Double.init) { limits.timeBudget = t / 1000 }

// Electron apps build their web tree a few seconds after AXManualAccessibility is set. What the probe switched
// on is switched off again at exit (unless --keep-enabled), so the app is left as it was found.
nonisolated(unsafe) var enabledPID: pid_t = 0
if AppAccessibilityEnabler.shared.ensureEnabled(pid: pid, profile: profile) {
    print("enabled AX tree for pid \(pid); waiting \(AppAccessibilityEnabler.shared.warmUpInterval) s")
    if !args.contains("--keep-enabled") {
        enabledPID = pid
        atexit { AppAccessibilityEnabler.shared.restore(pid: enabledPID) }
    }
    Thread.sleep(forTimeInterval: AppAccessibilityEnabler.shared.warmUpInterval)
}

let titleFilter = option("--window-title")
let chosenWindow: AXElement? =
    if let titleFilter {
        WindowLocator.windows(pid: pid).first { ($0.string(AXAttr.title) ?? "").contains(titleFilter) }
    } else {
        WindowLocator.bestWindow(pid: pid)
    }
guard let window = chosenWindow else {
    print(titleFilter.map { "no window titled *\($0)*" } ?? "no window")
    exit(1)
}
let windowID = WindowLocator.windowID(of: window, pid: pid)
print(
    "app: \(app.localizedName ?? "?") (\(bundleID)) pid \(pid) window \(windowID.map(String.init) ?? "?") "
        + "frame \(fmt(window.frame)) onScreen \(windowID.map { WindowLocator.isOnScreen(windowID: $0) } ?? false)")

// MARK: Tree dump

if args.contains("--tree") {
    let depthArg = option("--tree").flatMap(Int.init) ?? 60
    let plan = AXFetchPlan([.role, .subrole, .children, .frame, .value, .title, .description, .domClassList, .identifier])
    var count = 0
    func dump(_ el: AXElement, _ depth: Int) {
        guard depth <= depthArg, count < 8000, let i = el.fetch(plan) else { return }
        count += 1
        var line = String(repeating: " ", count: depth) + i.role
        if let s = i.subrole { line += "/" + s }
        if let id = i.identifier, !id.isEmpty { line += " id=\(id.prefix(30))" }
        if !i.domClasses.isEmpty { line += " dom=" + i.domClasses.prefix(6).joined(separator: ",") }
        line += " " + fmt(i.frame)
        if let v = i.stringValue, !v.isEmpty { line += " v=\"\(shown(v, limit: 50))\"#\(v.count)" }
        if let t = i.title, !t.isEmpty { line += " t=\"\(shown(t, limit: 30))\"" }
        if let d = i.descriptionText, !d.isEmpty { line += " d=\"\(shown(d, limit: 30))\"" }
        if !i.children.isEmpty { line += " (\(i.children.count))" }
        print(line)
        for c in i.children { dump(c, depth + 1) }
    }
    dump(window, 0)
    print("nodes: \(count)")
    exit(0)
}

// MARK: Scan

print(
    "preset: \(preset.name)  scope: \(profile.scope.rawValue)  granularity: \(profile.granularity.rawValue)  "
        + "textArea: \(profile.textAreaHandling.rawValue)")

let extractor = TextExtractor()
extractor.collectRejected = args.contains("--rejected")
let repeats = max(1, option("--repeat").flatMap(Int.init) ?? 1)
let mouse = option("--mouse").flatMap(parsePoint) ?? AXGeometry.mouseLocationAX()
var durations: [TimeInterval] = []
var last: WindowSnapshot?
for n in 0..<repeats {
    let snap = extractor.scan(
        window: window, pid: pid, bundleID: bundleID, settings: settings, limits: limits, mouseAX: mouse,
        windowID: windowID)
    let d = extractor.lastDiagnostics
    durations.append(snap.scanDuration)
    print(
        "scan \(n + 1): \(snap.segments.count) segments, \(snap.nodeCount) nodes, \(ms(snap.scanDuration)), "
            + "truncated \(snap.truncated), candidates \(d.candidates), pruned invisible \(d.prunedInvisible) / "
            + "excluded \(d.prunedExcluded), containers \(d.containerCount)\(d.containerCacheHit ? " (cached)" : "")"
            + ", style reads \(d.styleLookups), merged \(d.mergedOverlaps)"
            + ", links \(d.links) (url reads \(d.linkLookups))"
            + (d.zoom != 1 ? String(format: ", page zoom x%.2f", d.zoom) : "")
            + (d.warmingUp ? ", warming up" : "") + (d.scaledWebArea ? ", web frames rescaled" : ""))
    last = snap
}
if repeats > 1 {
    let sorted = durations.sorted()
    print("timing: min \(ms(sorted.first!)), median \(ms(sorted[sorted.count / 2])), max \(ms(sorted.last!))")
}

if let snap = last {
    print("window key \(snap.key)  clip \(fmt(snap.axClipRect))")
    for s in snap.segments {
        let order = String(s.order).padding(toLength: 3, withPad: " ", startingAt: 0)
        let frame = fmt(s.axFrame).padding(toLength: 22, withPad: " ", startingAt: 0)
        let role = s.role.padding(toLength: 13, withPad: " ", startingAt: 0)
        let look = describe(s.style, lines: s.lineFrames.count).padding(toLength: 30, withPad: " ", startingAt: 0)
        print("  \(order) \(frame) \(role) \(look) \(String(s.text.count).padding(toLength: 4, withPad: " ", startingAt: 0)) \"\(shown(s.text, limit: args.contains("--full-text") ? Int.max : 90))\"\(s.isEditable ? " (editable)" : "")")
        if args.contains("--links") {
            for l in s.links {
                var line = "      ↳ \(l.kind.rawValue) \(l.range.lowerBound)..<\(l.range.upperBound) \"\(shown(l.text, limit: 50))\""
                if let url = l.url { line += " url=" + shown(url.absoluteString, limit: 70) }
                line += " frames=" + l.frames.map(fmt).joined(separator: ",")
                if let c = l.color {
                    line += String(format: " rgb(%d,%d,%d)", Int(c.red * 255), Int(c.green * 255), Int(c.blue * 255))
                }
                if l.isUnderlined { line += " underline" }
                if l.element != nil { line += " element" }
                // The range must hold the link's text.
                if LinkText.substring(s.text, l.range) != l.text { line += " RANGE MISMATCH" }
                print(line)
            }
        }
    }
    // Sanity checks: nothing outside the window, nothing squashed (off-screen virtual-list items).
    let outside = snap.segments.filter { !snap.axWindowFrame.contains($0.axFrame.insetBy(dx: 1, dy: 1)) }.count
    let squashed = snap.segments.filter { $0.axFrame.height < limits.minVisibleHeight }.count
    let ids = Set(snap.segments.map(\.id)).count == snap.segments.count
    print("checks: outside window \(outside), squashed \(squashed), unique ids \(ids)")
    // Frames that cover each other would make the overlays hide each other's text.
    var overlaps = 0
    var touching = 0
    for (i, a) in snap.segments.enumerated() {
        for b in snap.segments[(i + 1)...] {
            let x = a.axFrame.intersection(b.axFrame)
            guard !x.isNull, x.width > 0, x.height > 0 else { continue }
            let line = CGFloat(min(a.style.lineHeight ?? 20, b.style.lineHeight ?? 20))
            if x.height >= max(4, 0.5 * line), x.width >= max(4, line) { overlaps += 1 } else { touching += 1 }
        }
    }
    let styled = snap.segments.filter { $0.style.fontSize != nil }.count
    let colored = snap.segments.filter { $0.style.textColor != nil }.count
    let pitched = snap.segments.filter { $0.style.lineHeight != nil }.count
    let lined = snap.segments.filter { !$0.lineFrames.isEmpty }.count
    print("overlaps: \(overlaps) (slight touches \(touching))")
    // Visible content that is not translated; the overlay keeps translations off it.
    print("obstacles: \(snap.obstacles.count)")
    if args.contains("--obstacles") {
        for o in snap.obstacles { print("  # \(fmt(o))") }
    }
    print("style: size \(styled)/\(snap.segments.count), color \(colored), line height \(pitched), line frames \(lined)")
    let d = extractor.lastDiagnostics
    if !d.rejectionCounts.isEmpty {
        print("rejected: " + d.rejectionCounts.sorted { $0.value > $1.value }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", "))
    }
    if d.droppedOverSegmentLimit > 0 { print("dropped over segment limit: \(d.droppedOverSegmentLimit)") }
    for r in d.rejected {
        print("  - \(r.reason.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)) \(fmt(r.axFrame)) \"\(shown(r.text, limit: 60))\"")
    }
}
