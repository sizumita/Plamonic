import AppKit
import SwiftUI

/// Entry point: the headless smoke test or update probe when asked for, otherwise the menu bar app.
@main
enum PlamonicMain {
    static func main() {
        #if DEBUG
        if let directory = RenderCheck.directory(arguments: CommandLine.arguments) {
            MainActor.assumeIsolated { RenderCheck.run(into: directory) }
        }
        #endif
        if let probe = UpdateProbeOptions(arguments: CommandLine.arguments) {
            MainActor.assumeIsolated { UpdateProbe.run(probe) }
        } else if let smoke = SmokeTestOptions(arguments: CommandLine.arguments) {
            MainActor.assumeIsolated { SmokeTest.run(smoke) }
        } else if isUnitTestHost {
            // Hosting PlamonicTests: no menu bar item, windows, hotkeys or session.
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            app.run()
        } else {
            PlamonicApp.main()
        }
    }

    private static var isUnitTestHost: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }
}

struct PlamonicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                controller: appDelegate.controller, models: appDelegate.controller.models,
                settings: appDelegate.controller.settings, updates: appDelegate.controller.updates)
        } label: {
            MenuBarIcon(controller: appDelegate.controller, settings: appDelegate.controller.settings)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
