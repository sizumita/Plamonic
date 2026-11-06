import ApplicationServices
import CoreGraphics
import Foundation

/// One window scan the session asks for.
struct ScanRequest: @unchecked Sendable {
    enum Target {
        /// The app's focused window (falls back to its main / first standard window).
        case focusedWindow
        case window(AXElement)
    }

    var pid: pid_t
    var bundleID: String
    var target: Target
    var settings: EffectiveSettings
    var limits: ExtractionLimits
    /// Pointer in AX coordinates, for the underMouse scope.
    var mouseAX: CGPoint?
    /// Scan for the translate-now hotkey in manual mode.
    var manual = false
}

struct ScanResult: @unchecked Sendable {
    enum Outcome {
        case scanned(WindowSnapshot)
        /// The window exists but is not on screen (minimized, hidden, other Space).
        case offScreen(WindowKey)
        /// The window was closed, or the app has no window.
        case gone
        /// The app did not answer in time; keep what is shown.
        case unavailable
        /// Not read at all: a password is being typed (DESIGN §4.1). Nothing on screen changes.
        case paused(PasswordPause)
    }

    var request: ScanRequest
    var window: AXElement?
    var cgWindowID: CGWindowID?
    var outcome: Outcome
    var diagnostics: ExtractionDiagnostics
}

/// Runs every AX call of the session on one serial queue.
final class SessionScanner: @unchecked Sendable {
    let queue = DispatchQueue(label: "io.smdr.Plamonic.scan", qos: .userInitiated)
    // Touched only on `queue`.
    private let extractor: TextExtractor
    /// Asked right before each window's AX reads; non-nil skips the window (a password is being typed).
    private let gate: @Sendable () -> PasswordPause?
    /// Tests: reads a window instead of AX.
    private let read: (@Sendable (ScanRequest) -> ScanResult)?

    init(
        ownPID: pid_t = getpid(), gate: @escaping @Sendable () -> PasswordPause? = { nil },
        read: (@Sendable (ScanRequest) -> ScanResult)? = nil
    ) {
        extractor = TextExtractor(ownPID: ownPID)
        self.gate = gate
        self.read = read
    }

    /// Scans the windows in order and calls `completion` on the main queue.
    func scan(_ requests: [ScanRequest], completion: @escaping @MainActor ([ScanResult]) -> Void) {
        queue.async { [self] in
            let results = requests.map(gatedScan)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(results) }
            }
        }
    }

    /// Runs `body` on the scan queue (for AX calls outside a scan, e.g. observer registration).
    func perform(_ body: @escaping @Sendable () -> Void) {
        queue.async(execute: body)
    }

    func invalidateCaches(pid: pid_t) {
        queue.async { [self] in extractor.invalidateCaches(pid: pid) }
    }

    /// A request made before a password began to be typed must not read: the gate is asked again here.
    private func gatedScan(_ request: ScanRequest) -> ScanResult {
        if let pause = gate() {
            return ScanResult(
                request: request, window: nil, cgWindowID: nil, outcome: .paused(pause), diagnostics: .init())
        }
        return read?(request) ?? scanOne(request)
    }

    private func scanOne(_ request: ScanRequest) -> ScanResult {
        func result(_ outcome: ScanResult.Outcome, window: AXElement? = nil) -> ScanResult {
            ScanResult(request: request, window: window, cgWindowID: nil, outcome: outcome, diagnostics: .init())
        }
        let window: AXElement
        switch request.target {
        case .focusedWindow:
            if let found = WindowLocator.bestWindow(pid: request.pid) {
                window = found
            } else {
                // No window at all, or the app is busy: only an answer tells them apart.
                switch AXElement.application(pid: request.pid).copyAttribute(AXAttr.windows) {
                case .success: return result(.gone)
                case .failure(let error): return result(error.isGone ? .gone : .unavailable)
                }
            }
        case .window(let element):
            window = element
        }
        if case .failure(let error) = window.copyAttribute(AXAttr.role) {
            return result(error.isGone ? .gone : .unavailable, window: window)
        }
        let cgWindowID = WindowLocator.windowID(of: window, pid: request.pid)
        if let cgWindowID, !WindowLocator.isOnScreen(windowID: cgWindowID) {
            let key = WindowKey(pid: request.pid, windowID: cgWindowID)
            return ScanResult(
                request: request, window: window, cgWindowID: cgWindowID, outcome: .offScreen(key),
                diagnostics: .init())
        }
        let snapshot = extractor.scan(
            window: window, pid: request.pid, bundleID: request.bundleID, settings: request.settings,
            limits: request.limits, mouseAX: request.mouseAX, windowID: cgWindowID)
        // The role was readable a moment ago, so a missing frame means the app stalled (or the window just closed).
        let outcome: ScanResult.Outcome =
            snapshot.axWindowFrame.width > 0 && snapshot.axWindowFrame.height > 0 ? .scanned(snapshot) : .unavailable
        return ScanResult(
            request: request, window: window, cgWindowID: cgWindowID, outcome: outcome,
            diagnostics: extractor.lastDiagnostics)
    }
}
