import AppKit

// Overlay demo: opens two plain windows (light / dark) with English labels and draws Japanese sample
// translations over them with OverlayController (pending / streaming / draft / final / overflow), in the
// labels' own size and color, then a selection popup and a hover popup. Never activates itself; exits after
// at most 4 seconds.
//
// Usage: overlay-demo [--screenshot <path.png>]
//        overlay-demo --render <directory>   off-screen PNGs of synthetic pages (no windows; see Scenes.swift and
//                                            LinkScenes.swift)

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private struct Sample {
    var original: String
    var fontSize: CGFloat
    var width: CGFloat
    var translation: String
    var state: OverlayItemState
}

@MainActor
private final class DemoWindow {
    let window: NSWindow
    let key: WindowKey
    var labels: [(NSTextField, Sample)] = []
    let style: OverlayStyle

    init(title: String, origin: CGPoint, dark: Bool, samples: [Sample], index: UInt32) {
        let size = CGSize(width: 560, height: 400)
        window = NSWindow(
            contentRect: CGRect(origin: origin, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let content = FlippedView(frame: CGRect(origin: .zero, size: size))
        window.contentView = content
        var y: CGFloat = 20
        for sample in samples {
            let label = NSTextField(wrappingLabelWithString: sample.original)
            label.font = .systemFont(ofSize: sample.fontSize)
            label.textColor = .labelColor
            label.preferredMaxLayoutWidth = sample.width
            let fitting = label.sizeThatFits(CGSize(width: sample.width, height: .greatestFiniteMagnitude))
            label.frame = CGRect(x: 24, y: y, width: sample.width, height: ceil(fitting.height))
            content.addSubview(label)
            labels.append((label, sample))
            y += ceil(fitting.height) + 16
        }
        key = WindowKey(pid: getpid(), windowID: index)
        var appearance = OverlayAppearance()
        appearance.theme = dark ? .dark : .light
        style = OverlayStyle(displayStyle: .replace, appearance: appearance)
    }

    var windowID: CGWindowID { CGWindowID(window.windowNumber) }
    var axFrame: CGRect { CoordinateSpace.axRect(fromCocoa: window.frame) }
    var axClip: CGRect {
        let content = window.contentView!
        return CoordinateSpace.axRect(fromCocoa: window.convertToScreen(content.convert(content.bounds, to: nil)))
    }

    func axFrame(of label: NSTextField) -> CGRect {
        CoordinateSpace.axRect(fromCocoa: window.convertToScreen(label.convert(label.bounds, to: nil)))
    }

    func items() -> [OverlayItem] {
        labels.enumerated().map { i, pair in
            // What the extraction reports for a native label: its font size and text color.
            var textColor: RGBAColor?
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                if let c = pair.0.textColor?.usingColorSpace(.sRGB) {
                    textColor = RGBAColor(
                        red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent),
                        alpha: Double(c.alphaComponent))
                }
            }
            return OverlayItem(
                id: "item-\(i)", axFrame: axFrame(of: pair.0), original: pair.1.original,
                translation: pair.1.translation, state: pair.1.state,
                style: TextStyleHint(fontSize: Double(pair.1.fontSize), textColor: textColor))
        }
    }

    func push(to controller: OverlayController, style: OverlayStyle? = nil) {
        controller.update(
            window: key, axWindowFrame: axFrame, axClipRect: axClip, cgWindowID: windowID, items: items(),
            style: style ?? self.style, targetIsFrontmost: false)
    }
}

@MainActor
private enum Demo {
    static var controller: OverlayController!
    static var windows: [DemoWindow] = []

    static func samples() -> [Sample] {
        [
            Sample(original: "Settings", fontSize: 13, width: 120, translation: "設定", state: .final),
            Sample(
                original: "The quick brown fox jumps over the lazy dog.", fontSize: 13, width: 480,
                translation: "素早い茶色の狐がのろまな犬を飛び越える。", state: .final),
            Sample(
                original: "Draft translations appear first and are replaced when the final model finishes.",
                fontSize: 13, width: 300,
                translation: "下書きの翻訳が先に表示され、仕上げモデルが終わると差し替えられます。", state: .draft),
            Sample(
                original: "Streaming output is shown while the model is still generating it.", fontSize: 13,
                width: 480, translation: "モデルが生成している途中の", state: .streaming),
            Sample(
                original: "Pending items keep the original text visible.", fontSize: 13, width: 480,
                translation: "", state: .pending),
            Sample(
                original: "Failed items keep the original text visible too.", fontSize: 13, width: 480,
                translation: "", state: .failed),
            Sample(
                original: "OK", fontSize: 12, width: 40,
                translation: "短いラベルに長い訳文：背景が下に伸びます",
                state: .final),
            Sample(
                original: "Select this sentence to see its translation in a popup.", fontSize: 15, width: 480,
                translation: "", state: .pending),
        ]
    }

    static func run(screenshotPath: String?) {
        NSApplication.shared.setActivationPolicy(.accessory)
        controller = OverlayController()

        let screen = NSScreen.screens[0].visibleFrame
        let total = CGSize(width: 560 * 2 + 20, height: 400)
        let origin = CGPoint(x: screen.midX - total.width / 2, y: screen.midY - total.height / 2)
        windows = [
            DemoWindow(title: "Plamonic オーバーレイ デモ（ライト）", origin: origin, dark: false, samples: samples(), index: 1),
            DemoWindow(
                title: "Plamonic オーバーレイ デモ（ダーク）", origin: CGPoint(x: origin.x + 580, y: origin.y), dark: true,
                samples: samples(), index: 2),
        ]
        // Shown without activating the app or taking key focus.
        for demo in windows { demo.window.orderFrontRegardless() }

        after(0.3) {
            for demo in windows { demo.push(to: controller) }
        }
        // Ordering is applied by the window server at the end of the run-loop turn; check a bit later.
        after(0.7) { reportOrdering("0.7s") }
        after(1.0) {
            for demo in windows {
                demo.labels[3].1.translation = "モデルが生成している途中の出力を、生成中にも表示し"
                demo.push(to: controller)
            }
        }
        after(1.6) {
            for demo in windows {
                demo.labels[3].1.translation = "モデルが生成している途中の出力も、生成中に表示されます。"
                demo.push(to: controller)
            }
            let light = windows[0]
            controller.showPopup(
                translation: "この文を選択すると、訳文がポップアップで表示されます。", original: light.labels[7].1.original,
                state: .final, nearAX: light.axFrame(of: light.labels[7].0), style: light.style)
        }
        after(2.4) {
            if let screenshotPath { takeScreenshot(to: screenshotPath) }
        }
        after(2.8) {
            controller.hidePopup()
            // Hover style on the dark window: the item under the "mouse" gets a popup below it.
            let dark = windows[1]
            let hover = OverlayStyle(displayStyle: .hover, appearance: dark.style.appearance)
            dark.push(to: controller, style: hover)
            let target = dark.axFrame(of: dark.labels[1].0)
            controller.updateMouseLocation(ax: CGPoint(x: target.minX + 20, y: target.midY))
        }
        after(3.2) {
            reportPopup(anchor: windows[1].axFrame(of: windows[1].labels[1].0))
            controller.revealOriginal = true
        }
        after(3.5) {
            print("activeWindows:", controller.activeWindows.count)
            controller.removeAll()
            for demo in windows { demo.window.orderOut(nil) }
        }
        after(3.8) { exit(0) }
    }

    static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { body() } }
    }

    /// Checks in CGWindowList that each overlay panel sits directly above its demo window.
    static func reportOrdering(_ label: String) {
        let ours = controller.overlayWindowNumbers
        for demo in windows {
            let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], demo.windowID) as? [[String: Any]] ?? []
            let numbers = above.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
            let direct = numbers.last.map { ours.contains($0) } ?? false
            print("[\(label)] window \(demo.windowID): overlay directly above = \(direct)")
        }
        print("app active:", NSRunningApplication.current.isActive, "key window:", NSApp.keyWindow != nil)
    }

    static func reportPopup(anchor: CGRect) {
        let ours = controller.overlayWindowNumbers
        let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = all.filter { ours.contains(($0[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1) }
        let popups = mine.filter { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.floatingWindow)) }
        for popup in popups {
            guard let dict = popup[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { continue }
            let alpha = (popup[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
            print("hover popup:", bounds, "alpha", alpha, "covers anchor:", bounds.intersects(anchor), "below:", bounds.minY >= anchor.maxY)
        }
        if popups.isEmpty { print("hover popup: not on screen") }
    }

    static func takeScreenshot(to path: String) {
        guard CGPreflightScreenCaptureAccess() else {
            print("screenshot skipped: no Screen Recording permission")
            return
        }
        var region = CGRect.null
        for demo in windows { region = region.union(demo.axFrame) }
        region = region.insetBy(dx: -12, dy: -12).integral
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = [
            "-x", "-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", path,
        ]
        do {
            try process.run()
            process.waitUntilExit()
            print("screenshot:", process.terminationStatus == 0 ? path : "failed (\(process.terminationStatus))")
        } catch {
            print("screenshot failed:", error)
        }
    }
}

let arguments = CommandLine.arguments
// Hard stop in case the main thread stalls (rendering takes longer than the live demo).
DispatchQueue.global().asyncAfter(deadline: .now() + (arguments.contains("--render") ? 30 : 4.0)) { exit(0) }

if let i = arguments.firstIndex(of: "--render") {
    let directory = arguments.indices.contains(i + 1) ? arguments[i + 1] : "."
    let problems = MainActor.assumeIsolated {
        _ = NSApplication.shared
        return DemoScenes.render(to: directory) + DemoLinkScenes.render(to: directory)
    }
    print(problems == 0 ? "no problems" : "\(problems) problem(s)")
    exit(problems == 0 ? 0 : 1)
}
let screenshotPath = arguments.firstIndex(of: "--screenshot").flatMap {
    arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    Demo.run(screenshotPath: screenshotPath)
}
// NSApp.run() would finish launching and activate this unbundled process. Spinning the run loop keeps it in
// the background; windows still display and timers, tasks and animations still run.
RunLoop.main.run(until: Date().addingTimeInterval(4.0))
exit(0)
