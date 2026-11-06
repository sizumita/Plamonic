#if DEBUG
import AppKit
import SwiftUI

/// `--render-check <dir>` (Debug builds): renders the onboarding view to PNG files offscreen and exits.
/// Nothing is put on screen and the app is never activated.
@MainActor
enum RenderCheck {
    static func directory(arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--render-check"), arguments.count > index + 1 else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static func run(into directory: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = AppController()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: OnboardingView(controller: controller))
            view.appearance = NSAppearance(named: appearance)
            view.frame.size = view.fittingSize
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = directory.appendingPathComponent("onboarding-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.path) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
        }
        exit(0)
    }
}
#endif
