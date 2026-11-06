import Foundation

public struct PlamoDownloadProgress: Sendable, Hashable {
    public var completedBytes: Int64
    public var totalBytes: Int64
    /// File currently being downloaded (repository-relative path).
    public var currentFile: String

    /// 0...1
    public var fractionCompleted: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
    }
}

/// Where PLaMo models live on disk, and how they get there.
///
/// Layout: `<root>/pfnet/plamo-3-translate-<size>-MLX-4bit/`. A finished download contains a
/// `.complete` marker; directories placed by hand are accepted when their files look complete.
public final class PlamoModelStore: Sendable {
    public static let completeMarkerName = ".complete"

    /// `~/Library/Application Support/Plamonic/Models`
    public static var defaultRootDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Plamonic/Models", isDirectory: true)
    }

    public let rootDirectory: URL

    public init(rootDirectory: URL = PlamoModelStore.defaultRootDirectory) {
        self.rootDirectory = rootDirectory
    }

    public func directory(for variant: PlamoModelVariant) -> URL {
        rootDirectory.appendingPathComponent(variant.repoID, isDirectory: true)
    }

    /// Where an unfinished download keeps its files, next to the variant's directory.
    func partialDirectory(for variant: PlamoModelVariant) -> URL {
        let dir = directory(for: variant)
        return dir.deletingLastPathComponent().appendingPathComponent(
            ".\(dir.lastPathComponent).partial", isDirectory: true)
    }

    // MARK: - Installed state

    public func isInstalled(_ variant: PlamoModelVariant) -> Bool {
        let dir = directory(for: variant)
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(Self.completeMarkerName).path) {
            return true
        }
        return Self.validationProblem(directory: dir) == nil
    }

    /// Bytes of all files under the variant's directory (0 when absent).
    public func installedBytes(_ variant: PlamoModelVariant) -> Int64 {
        Self.directorySize(directory(for: variant))
    }

    /// Bytes kept by an unfinished download (0 when there is none). The next `download` resumes
    /// from them; `delete` removes them.
    public func partialDownloadBytes(_ variant: PlamoModelVariant) -> Int64 {
        Self.directorySize(partialDirectory(for: variant))
    }

    /// Writes the `.complete` marker if the directory passes validation. Returns false otherwise.
    @discardableResult
    public func markInstalledIfValid(_ variant: PlamoModelVariant) throws -> Bool {
        let dir = directory(for: variant)
        guard Self.validationProblem(directory: dir) == nil else { return false }
        try Self.writeMarker(in: dir, files: [])
        return true
    }

    /// nil when `directory` holds a loadable model, otherwise a short reason.
    public static func validationProblem(directory: URL) -> String? {
        let fm = FileManager.default
        func size(_ name: String) -> Int64? {
            guard let attrs = try? fm.attributesOfItem(atPath: directory.appendingPathComponent(name).path) else {
                return nil
            }
            return (attrs[.size] as? NSNumber)?.int64Value
        }
        guard let configSize = size("config.json"), configSize > 512 else { return "config.json がありません" }
        guard let vocabSize = size("tokenizer.jsonl"), vocabSize > 1_000_000 else {
            return "tokenizer.jsonl がありません"
        }
        guard size("tokenizer_config.json") != nil else { return "tokenizer_config.json がありません" }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["plamo_rope_inv_freq"] != nil
        else {
            return "config.json が不正です"
        }
        let weightFiles: [URL]
        do {
            weightFiles = try PlamoModelLoader.weightFiles(in: directory)
        } catch {
            return "重みファイルがありません"
        }
        for url in weightFiles where !SafetensorsHeader.isComplete(url) {
            return "\(url.lastPathComponent) が不完全です"
        }
        return nil
    }

    // MARK: - Delete

    /// Removes the variant's files, including an unfinished download.
    public func delete(_ variant: PlamoModelVariant) throws {
        for dir in [directory(for: variant), partialDirectory(for: variant)]
        where FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Download

    struct RemoteFile: Sendable {
        var path: String
        var size: Int64
        /// Content hash from the listing (the LFS sha256 for weights); nil when unknown.
        var oid: String?
    }

    static let downloadableExtensions: Set<String> = ["json", "jsonl", "safetensors", "jinja"]

    /// Files of the repository that the app needs (config, tokenizer, weights).
    /// README, LICENSE, figures/, *.py and server scripts are skipped.
    static func selectFiles(_ entries: [[String: Any]]) -> [RemoteFile] {
        entries.compactMap { entry in
            guard entry["type"] as? String == "file", let path = entry["path"] as? String,
                !path.contains("/"), !path.hasPrefix(".")
            else { return nil }
            let ext = (path as NSString).pathExtension.lowercased()
            guard downloadableExtensions.contains(ext) else { return nil }
            let lfs = entry["lfs"] as? [String: Any]
            let size = (lfs?["size"] as? NSNumber)?.int64Value ?? (entry["size"] as? NSNumber)?.int64Value ?? 0
            let oid = lfs?["oid"] as? String ?? entry["oid"] as? String
            return RemoteFile(path: path, size: size, oid: oid)
        }
        .sorted { $0.path < $1.path }
    }

    func listRemoteFiles(_ variant: PlamoModelVariant, session: URLSession) async throws -> [RemoteFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(variant.repoID)/tree/main")!
        var request = URLRequest(url: url)
        request.setValue("Plamonic", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw PlamoError.downloadFailed("ファイル一覧を取得できません (HTTP \(http.statusCode))")
        }
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PlamoError.downloadFailed("ファイル一覧の形式が不正です")
        }
        let files = Self.selectFiles(entries)
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }),
            files.contains(where: { $0.path == "config.json" })
        else {
            throw PlamoError.downloadFailed("必要なファイルがリポジトリにありません")
        }
        return files
    }

    /// Delays before retrying a file after a transient network error.
    static let retryDelays: [TimeInterval] = [2, 5, 10]

    /// Downloads the variant from Hugging Face into `partialDirectory(for:)`, then moves it into
    /// place and writes `.complete`. Transient network errors are retried per file; when a run
    /// still fails, the files it finished stay and the next run downloads only the rest.
    /// Cancel the calling Task to stop; cancelling removes the partial download.
    /// `progress` is called on an arbitrary thread, at most about 10 times per second.
    public func download(
        _ variant: PlamoModelVariant,
        progress: (@Sendable (PlamoDownloadProgress) -> Void)? = nil
    ) async throws {
        let fm = FileManager.default
        let finalDir = directory(for: variant)
        // One download per variant at a time is assumed.
        let partialDir = partialDirectory(for: variant)
        do {
            try await downloadFiles(variant, into: partialDir, progress: progress)
            if fm.fileExists(atPath: finalDir.path) {
                try fm.removeItem(at: finalDir)
            }
            try fm.moveItem(at: partialDir, to: finalDir)
            try? fm.removeItem(at: finalDir.appendingPathComponent(Self.partialManifestName))
        } catch {
            // URLSession reports cancellation as URLError.cancelled.
            guard error is CancellationError || Task.isCancelled else { throw error }
            try? fm.removeItem(at: partialDir)
            throw CancellationError()
        }
    }

    /// Fills `partialDir` with every file of the variant and the `.complete` marker.
    private func downloadFiles(
        _ variant: PlamoModelVariant, into partialDir: URL,
        progress: (@Sendable (PlamoDownloadProgress) -> Void)?
    ) async throws {
        let fm = FileManager.default
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.httpAdditionalHeaders = ["User-Agent": "Plamonic"]
        let listSession = URLSession(configuration: configuration)
        defer { listSession.finishTasksAndInvalidate() }

        let files = try await listRemoteFiles(variant, session: listSession)
        let total = files.reduce(Int64(0)) { $0 + $1.size }

        let parent = partialDir.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Older versions used one `.<name>.partial-<UUID>` directory per attempt.
        let legacyPrefix = partialDir.lastPathComponent + "-"
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(legacyPrefix) {
            try? fm.removeItem(at: parent.appendingPathComponent(name))
        }

        var finished = try Self.preparePartialDirectory(partialDir, for: files)
        let reporter = ProgressReporter(total: total, callback: progress)
        var completed: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            if finished[file.path] == nil {
                let base = completed
                try await Self.fetch(file, of: variant, into: partialDir, configuration: configuration) { written in
                    reporter.report(completed: base + written, file: file.path)
                }
                if let oid = file.oid {
                    finished[file.path] = oid
                    try Self.writeManifest(finished, in: partialDir)
                }
            }
            completed += file.size
            reporter.report(completed: completed, file: file.path, force: true)
        }

        if let problem = Self.validationProblem(directory: partialDir) {
            // Downloading the same files again cannot help.
            try? fm.removeItem(at: partialDir)
            throw PlamoError.downloadFailed(problem)
        }
        try Self.writeMarker(in: partialDir, files: files.map(\.path))
        try Task.checkCancellation()
    }

    /// Lists, per path, the content hash of the files a partial download has finished.
    static let partialManifestName = ".downloaded.json"

    /// Keeps the files of `directory` that an earlier run finished for the same file versions
    /// (same oid and size; for weights also a complete safetensors header) and deletes the rest.
    /// Returns the kept files as `path -> oid`.
    static func preparePartialDirectory(_ directory: URL, for files: [RemoteFile]) throws -> [String: String] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent(partialManifestName)
        let recorded =
            (try? Data(contentsOf: manifestURL)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: String]
            } ?? [:]
        var kept = [String: String]()
        for file in files {
            guard let oid = file.oid, recorded[file.path] == oid else { continue }
            let url = directory.appendingPathComponent(file.path)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            guard size == file.size, !file.path.hasSuffix(".safetensors") || SafetensorsHeader.isComplete(url) else {
                continue
            }
            kept[file.path] = oid
        }
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        where name != partialManifestName && kept[name] == nil {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        try writeManifest(kept, in: directory)
        return kept
    }

    static func writeManifest(_ files: [String: String], in directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: files, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent(partialManifestName), options: .atomic)
    }

    /// Downloads one file, retrying transient failures after `retryDelays`.
    private static func fetch(
        _ file: RemoteFile, of variant: PlamoModelVariant, into directory: URL,
        configuration: URLSessionConfiguration, onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let encoded = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
        let url = URL(string: "https://huggingface.co/\(variant.repoID)/resolve/main/\(encoded)")!
        let destination = directory.appendingPathComponent(file.path)
        var attempt = 0
        while true {
            do {
                try await FileDownload.run(
                    url: url, destination: destination, configuration: configuration, onBytes: onBytes)
                let actual =
                    (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?
                    .int64Value ?? -1
                if file.size > 0, actual != file.size {
                    throw FileDownload.Failure(
                        message: "\(file.path) のサイズが一致しません (\(actual) / \(file.size))", isTransient: true)
                }
                return
            } catch let failure as FileDownload.Failure {
                guard failure.isTransient, attempt < retryDelays.count else {
                    throw PlamoError.downloadFailed(failure.message)
                }
                try await Task.sleep(nanoseconds: UInt64(retryDelays[attempt] * 1_000_000_000))
                attempt += 1
            }
        }
    }

    /// Network conditions that may clear up by themselves.
    static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
            .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    static func isTransient(httpStatus: Int) -> Bool {
        httpStatus == 429 || (500 ..< 600).contains(httpStatus)
    }

    static func writeMarker(in directory: URL, files: [String]) throws {
        let info: [String: Any] = [
            "completed": ISO8601DateFormatter().string(from: Date()),
            "files": files,
        ]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent(completeMarkerName), options: .atomic)
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}

/// Throttles progress callbacks.
private final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private let callback: (@Sendable (PlamoDownloadProgress) -> Void)?
    private var lastReport = Date.distantPast

    init(total: Int64, callback: (@Sendable (PlamoDownloadProgress) -> Void)?) {
        self.total = total
        self.callback = callback
    }

    func report(completed: Int64, file: String, force: Bool = false) {
        guard let callback else { return }
        let now = Date()
        let shouldReport = lock.withLock { () -> Bool in
            if !force, now.timeIntervalSince(lastReport) < 0.1 { return false }
            lastReport = now
            return true
        }
        if shouldReport {
            callback(PlamoDownloadProgress(completedBytes: completed, totalBytes: total, currentFile: file))
        }
    }
}

/// One URLSession download task bridged to async/await with byte progress and cancellation.
/// Throws `CancellationError` or `FileDownload.Failure`.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Failure: Error {
        var message: String
        var isTransient: Bool
    }

    private let lock = NSLock()
    private let destination: URL
    private let onBytes: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var finishError: Error?

    private init(destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.onBytes = onBytes
    }

    static func run(
        url: URL, destination: URL, configuration: URLSessionConfiguration,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let download = FileDownload(destination: destination, onBytes: onBytes)
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: url)
                let alreadyCancelled = download.lock.withLock { () -> Bool in
                    download.continuation = continuation
                    download.task = task
                    return download.cancelled
                }
                if alreadyCancelled {
                    download.finish(CancellationError())
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            let task = download.lock.withLock { () -> URLSessionDownloadTask? in
                download.cancelled = true
                return download.task
            }
            task?.cancel()
        }
    }

    private func finish(_ error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        onBytes(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        // The temporary file disappears when this method returns, so move it now.
        if let http = downloadTask.response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            lock.withLock {
                finishError = Failure(
                    message: "\(destination.lastPathComponent): HTTP \(http.statusCode)",
                    isTransient: PlamoModelStore.isTransient(httpStatus: http.statusCode))
            }
            return
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            // URLSession's temporary files are owner-only
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        } catch {
            lock.withLock {
                finishError = Failure(
                    message: "\(destination.lastPathComponent): \(error.localizedDescription)", isTransient: false)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (wasCancelled, moveError) = lock.withLock { (cancelled, finishError) }
        if wasCancelled {
            finish(CancellationError())
        } else if let error {
            finish(
                Failure(
                    message: "\(destination.lastPathComponent): \(error.localizedDescription)",
                    isTransient: PlamoModelStore.isTransient(error)))
        } else {
            finish(moveError)
        }
    }
}
