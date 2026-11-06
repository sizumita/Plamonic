import CoreGraphics
import Foundation

// Interfaces between app modules and the PlamoKit adapter.
// The adapter (Translation/PlamoBackend.swift) implements TranslationBackend and ModelLibraryBackend on top of PlamoKit.

struct TranslationHistoryPair: Hashable, Sendable {
    var source: String
    var translation: String
}

/// One translation call. All strings are already sanitized (no "<|plamo:" sequences).
struct TranslationBackendRequest: Hashable, Sendable {
    var text: String
    /// PLaMo language code: "ja", "en", "zh-hans", "ja(easy)", ...
    var targetLanguage: String
    /// nil = let the model detect it.
    var sourceLanguage: String?
    var context: String?
    var glossary: [GlossaryTerm]
    /// "plain" / "polite" (only when targetLanguage == "ja"), otherwise nil.
    var form: String?
    var history: [TranslationHistoryPair]
    var maxNewTokens: Int
}

enum TranslationBackendError: Error, Sendable {
    case modelNotInstalled(ModelSize)
    case cancelled
    case failed(String)
}

/// Runs PLaMo inference. Calls are serialized by the implementation; cancellation of the calling Task stops generation.
protocol TranslationBackend: AnyObject, Sendable {
    /// `onPartial` receives the whole text generated so far (cumulative, not a delta, no special tokens),
    /// on an arbitrary thread. Cancellation surfaces as `TranslationBackendError.cancelled` or `CancellationError`.
    func translate(
        _ request: TranslationBackendRequest,
        model: ModelSize,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String

    /// true when the model files are on disk (it may still need loading).
    /// Must be cheap and non-blocking (a marker file check): it is called on the main actor.
    func isModelInstalled(_ model: ModelSize) -> Bool
}

struct ModelInstallState: Equatable, Sendable {
    var installed: Bool = false
    var downloading: Bool = false
    /// 0...1 while downloading.
    var progress: Double = 0
    var bytesOnDisk: Int64 = 0
    /// Bytes kept by an unfinished download that the next download resumes from (0 when none).
    var partialBytes: Int64 = 0
    var loaded: Bool = false
    var error: String? = nil
}

/// Download / delete / load management for the Models settings tab.
protocol ModelLibraryBackend: AnyObject, Sendable {
    func installState(_ model: ModelSize) async -> ModelInstallState
    func download(_ model: ModelSize, progress: @escaping @Sendable (Double) -> Void) async throws
    func cancelDownload(_ model: ModelSize) async
    func delete(_ model: ModelSize) async throws
    func unloadAll() async
}

/// Describes one AX element for the rule editor ("inspect element under the mouse").
struct ElementDescriptor: Hashable, Sendable {
    var role: String
    var subrole: String?
    var roleDescription: String?
    var domClasses: [String]
    var identifier: String?
    var axFrame: CGRect?
    /// Short preview of the element's own text (value / title / description), at most ~80 characters.
    var textPreview: String
}

struct InspectedElement: Hashable, Sendable {
    var bundleID: String
    var appName: String
    /// path[0] is the element under the point, followed by its ancestors up to the window.
    var path: [ElementDescriptor]
}

protocol ElementInspecting: AnyObject {
    /// `point` is in AX global coordinates. Safe to call from any thread.
    func inspectElement(atAX point: CGPoint) -> InspectedElement?
}

/// Measures colors on screen so overlays can match the target window (Screen Recording permission).
protocol ScreenColorSampling: AnyObject, Sendable {
    /// Screen Recording permission is granted. Cheap; callable on the main actor.
    var isAuthorized: Bool { get }
    /// Captures only the target window's own content (never Plamonic's overlays above it) and measures the
    /// background and text colors inside each rect. `rects` are AX global coordinates keyed by overlay item id.
    /// Returns only the ids it could measure; empty when not authorized or the window is gone. Never call it
    /// on every scan: callers sample when an item's frame or text changes.
    func sampleColors(windowID: UInt32, rects: [String: CGRect]) async -> [String: SampledColors]
}
