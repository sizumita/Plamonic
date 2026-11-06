import CoreGraphics
import Foundation

@testable import Plamonic

/// Backend double: sleeps instead of running a model and answers "[<model>] <text>".
final class TranslationFakeBackend: TranslationBackend, @unchecked Sendable {
    struct Call: Sendable {
        var request: TranslationBackendRequest
        var model: ModelSize
    }

    private let lock = NSLock()
    private var _installed: Set<ModelSize>
    private var _latency: [ModelSize: TimeInterval]
    private var _partialSteps = 0
    private var _partialStepInterval: TimeInterval = 0.005
    private var _failures: [String: Int] = [:]
    private var _responder: (@Sendable (String, ModelSize) -> String)?
    private var _calls: [Call] = []
    private var _completed: [Call] = []
    private var _active = 0
    private var _maxActive = 0

    init(
        installed: Set<ModelSize> = [.b0_8, .b2],
        latency: [ModelSize: TimeInterval] = [.b0_8: 0.02, .b2: 0.06]
    ) {
        _installed = installed
        _latency = latency
    }

    static func output(for text: String, model: ModelSize) -> String { "[\(model.rawValue)] \(text)" }

    var installed: Set<ModelSize> {
        get { locked { _installed } }
        set { locked { _installed = newValue } }
    }

    /// When > 0 the call emits this many growing partial results, `partialStepInterval` apart.
    func setStreaming(steps: Int, interval: TimeInterval) {
        locked {
            _partialSteps = steps
            _partialStepInterval = interval
        }
    }

    /// Answers with `responder(text, model)` instead of `output(for:model:)`.
    func respond(with responder: @escaping @Sendable (String, ModelSize) -> String) {
        locked { _responder = responder }
    }

    /// The next `count` calls for `text` throw.
    func fail(_ text: String, times count: Int) {
        locked { _failures[text] = count }
    }

    var calls: [Call] { locked { _calls } }
    var completedCalls: [Call] { locked { _completed } }
    var maxConcurrentCalls: Int { locked { _maxActive } }

    func calls(for text: String) -> [Call] { calls.filter { $0.request.text == text } }

    func translate(
        _ request: TranslationBackendRequest, model: ModelSize, onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let call = Call(request: request, model: model)
        let responder = locked { _responder }
        let (delay, steps, stepInterval, shouldFail): (TimeInterval, Int, TimeInterval, Bool) = locked {
            _calls.append(call)
            _active += 1
            _maxActive = max(_maxActive, _active)
            var fail = false
            if let remaining = _failures[request.text], remaining > 0 {
                _failures[request.text] = remaining - 1
                fail = true
            }
            return (_latency[model] ?? 0.01, _partialSteps, _partialStepInterval, fail)
        }
        defer { locked { _active -= 1 } }

        let output = responder?(request.text, model) ?? Self.output(for: request.text, model: model)
        if steps > 0 {
            for step in 1...steps {
                try await Task.sleep(nanoseconds: UInt64(stepInterval * 1_000_000_000))
                onPartial?(String(output.prefix(output.count * step / steps)))
            }
        } else {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if shouldFail { throw TranslationBackendError.failed("fake failure") }
        locked { _completed.append(call) }
        return output
    }

    func isModelInstalled(_ model: ModelSize) -> Bool { locked { _installed.contains(model) } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Mutable frontmost process for coordinators whose tests switch apps.
@MainActor
final class FrontmostBox {
    var pid: pid_t?

    init(_ pid: pid_t?) { self.pid = pid }
}

enum TranslationTestFixtures {
    static func settings(
        target: String = "ja", draft: ModelSize? = .b0_8, final: ModelSize = .b2,
        configure: (inout EffectiveSettings) -> Void = { _ in }
    ) -> EffectiveSettings {
        var global = GlobalSettings()
        global.targetLanguage = target
        global.draftModel = draft
        global.finalModel = final
        global.persistCache = false
        global.streamPartialResults = true
        var profile = AppProfile(bundleID: "com.example.chat", displayName: "Chat")
        profile.mode = .automatic
        var settings = EffectiveSettings(profile: profile, global: global)
        configure(&settings)
        return settings
    }

    static func segments(_ texts: [String], window: UInt32 = 1) -> [TextSegment] {
        texts.enumerated().map { index, text in
            TextSegment(
                id: "\(window)-\(text.hashValue)-\(index)", text: text,
                axFrame: CGRect(x: 0, y: CGFloat(index) * 24, width: 400, height: 20), role: "AXStaticText",
                isEditable: false, order: index)
        }
    }

    static func snapshot(_ texts: [String], pid: pid_t = 100, window: UInt32 = 1) -> WindowSnapshot {
        WindowSnapshot(
            key: WindowKey(pid: pid, windowID: window), pid: pid, bundleID: "com.example.chat",
            axWindowFrame: CGRect(x: 0, y: 0, width: 800, height: 600), axClipRect: nil,
            segments: segments(texts, window: window), nodeCount: texts.count, scanDuration: 0.001, truncated: false)
    }

    static func configuration() -> TranslationCoordinator.Configuration {
        var configuration = TranslationCoordinator.Configuration()
        configuration.installCheckInterval = 0
        configuration.retryBackoff = 0.3
        configuration.maxRetryBackoff = 0.6
        return configuration
    }

    @MainActor
    static func coordinator(
        _ backend: TranslationFakeBackend, cache: TranslationCache = TranslationCache(capacity: 1000, fileURL: nil),
        frontmost: pid_t? = 100
    ) -> TranslationCoordinator {
        TranslationCoordinator(
            backend: backend, cache: cache, configuration: configuration(), frontmostPID: { frontmost })
    }

    /// Polls `condition` on the main actor every 5 ms.
    @MainActor
    static func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    static func temporaryFileURL(_ name: String = "translation-cache.json") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PlamonicTranslationTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }
}
