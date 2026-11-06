#if DEBUG
import AppKit
import SwiftUI

/// `--render-check <dir>` (Debug builds): renders the onboarding view, the PLaMo license sheet and
/// the menu bar icons to PNG files offscreen and exits.
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
            render(OnboardingView(controller: controller), size: nil, appearance: appearance,
                   to: directory.appendingPathComponent("onboarding-\(name).png"))
            render(PlamoLicenseView(), size: CGSize(width: 640, height: 560), appearance: appearance,
                   to: directory.appendingPathComponent("license-\(name).png"))
            render(MenuBarIconPreview(), size: nil, appearance: appearance,
                   to: directory.appendingPathComponent("menubar-icon-\(name).png"))
        }
        exit(0)
    }

    /// `size` nil: the view's fitting size.
    private static func render(_ root: some View, size: CGSize?, appearance: NSAppearance.Name, to url: URL) {
        let view = NSHostingView(rootView: root)
        view.appearance = NSAppearance(named: appearance)
        view.frame.size = size ?? view.fittingSize
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }
}

/// The menu bar icon in each state, at menu bar size and enlarged.
private struct MenuBarIconPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach([1.0, 4.0], id: \.self) { zoom in
                HStack(spacing: 16 * zoom) {
                    ForEach(MenuBarIconImage.State.allCases, id: \.self) { state in
                        let image = MenuBarIconImage.image(for: state)
                        Image(nsImage: image)
                            .resizable()
                            .renderingMode(.template)
                            .frame(width: image.size.width * zoom, height: image.size.height * zoom)
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
