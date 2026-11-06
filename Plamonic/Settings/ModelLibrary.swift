import Combine
import Foundation

/// Observable model install state for the Models settings tab, on top of a ModelLibraryBackend.
@MainActor
final class ModelLibrary: ObservableObject {
    @Published private(set) var states: [ModelSize: ModelInstallState] = [:]

    private let backend: any ModelLibraryBackend
    private var downloadTasks: [ModelSize: Task<Void, Never>] = [:]

    init(backend: any ModelLibraryBackend) {
        self.backend = backend
        for size in ModelSize.allCases { states[size] = ModelInstallState() }
    }

    func state(for size: ModelSize) -> ModelInstallState { states[size] ?? ModelInstallState() }

    func isInstalled(_ size: ModelSize) -> Bool { state(for: size).installed }

    func isDownloading(_ size: ModelSize) -> Bool { downloadTasks[size] != nil }

    var isAnyDownloading: Bool { !downloadTasks.isEmpty }

    var totalBytesOnDisk: Int64 { states.values.reduce(0) { $0 + $1.bytesOnDisk + $1.partialBytes } }

    /// Re-reads the state of every size from the backend.
    func refresh() async {
        for size in ModelSize.allCases { await refresh(size) }
    }

    func refresh(_ size: ModelSize) async {
        var fresh = await backend.installState(size)
        if downloadTasks[size] != nil {
            // Our own download is still running; keep its progress and error state.
            let current = state(for: size)
            fresh.downloading = true
            fresh.progress = max(fresh.progress, current.progress)
            fresh.error = current.error
        } else if fresh.error == nil, let error = state(for: size).error, !fresh.installed {
            // Keep the last failure visible until the user tries again.
            fresh.error = error
        }
        states[size] = fresh
    }

    /// Starts downloading in the background. Progress is published through `states`.
    func download(_ size: ModelSize) {
        guard downloadTasks[size] == nil else { return }
        var s = state(for: size)
        s.downloading = true
        s.progress = 0
        s.error = nil
        states[size] = s

        let backend = self.backend
        downloadTasks[size] = Task { [weak self] in
            var failure: Error?
            weak let weakSelf = self
            do {
                try await backend.download(size) { fraction in
                    Task { @MainActor in weakSelf?.applyProgress(size, fraction) }
                }
            } catch {
                failure = error
            }
            await self?.finishDownload(size, error: failure)
        }
    }

    func cancelDownload(_ size: ModelSize) {
        let task = downloadTasks[size]
        task?.cancel()
        let backend = self.backend
        Task { [weak self] in
            await backend.cancelDownload(size)
            await task?.value
            await self?.refresh(size)
        }
    }

    func delete(_ size: ModelSize) async {
        if downloadTasks[size] != nil { return }
        do {
            try await backend.delete(size)
            var s = state(for: size)
            s.error = nil
            states[size] = s
        } catch {
            var s = state(for: size)
            s.error = "削除できませんでした: \(Self.describe(error))"
            states[size] = s
            return
        }
        await refresh(size)
    }

    /// Frees the memory of every loaded model (they reload on the next translation).
    func unloadAll() async {
        await backend.unloadAll()
        await refresh()
    }

    // MARK: - Private

    private func applyProgress(_ size: ModelSize, _ fraction: Double) {
        guard downloadTasks[size] != nil, var s = states[size], s.downloading else { return }
        // Progress callbacks hop to the main actor independently and may arrive out of order.
        let clamped = min(max(fraction, 0), 1)
        if clamped > s.progress {
            s.progress = clamped
            states[size] = s
        }
    }

    private func finishDownload(_ size: ModelSize, error: Error?) async {
        downloadTasks[size] = nil
        var s = state(for: size)
        s.downloading = false
        if let error, !Self.isCancellation(error) {
            s.error = "ダウンロードに失敗しました: \(Self.describe(error))"
        } else {
            s.error = nil
        }
        states[size] = s
        await refresh(size)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case TranslationBackendError.cancelled = error { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case TranslationBackendError.failed(let message): return message
        case TranslationBackendError.modelNotInstalled(let size): return "\(size.displayName) がありません"
        default: return error.localizedDescription
        }
    }
}
