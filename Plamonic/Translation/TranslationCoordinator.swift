import AppKit
import CoreGraphics
import Foundation

/// Turns window snapshots into overlay items and keeps one backend call running at a time.
///
/// Scheduling is pull-based: whenever the backend is idle the next job is chosen from the latest
/// snapshot of every window, so jobs for segments that left the screen are dropped for free and
/// identical texts (same `TranslationSubject`) are translated once.
/// Priority: manual requests > first translations (each window's draft model, or its final model when it
/// translates in one stage) > final jobs for text whose draft is backing off > final upgrades of drafts.
/// Within a tier: windows of the frontmost app first, then the most recently scanned window, then top-to-bottom.
/// Each window keeps the model plan of its own app's settings (段階翻訳 can be switched per app).
/// A long upgrade yields between chunks when untranslated text appears and later resumes where it stopped.
/// While a lot of new text keeps arriving in a two-stage app, that app's upgrades pause (混雑時の一時停止,
/// one `BurstControl` per app).
@MainActor
final class TranslationCoordinator {
    struct Configuration: Sendable {
        /// Combined length of history sources and translations sent with a request.
        var historyCharacterLimit = 1500
        /// Longer texts are translated in chunks of at most this many characters.
        var chunkCharacterLimit = 800
        /// Minimum interval between partial-result redraws (~10 Hz).
        var partialUpdateInterval: TimeInterval = 0.1
        /// First back-off after a job failed twice; doubles up to `maxRetryBackoff`.
        var retryBackoff: TimeInterval = 30
        var maxRetryBackoff: TimeInterval = 300
        /// Cap for `translateOnce` input.
        var manualTextCharacterLimit = 10_000
        var contextCharacterLimit = 1000
        /// Segments on each side checked for kana when judging kanji-only text.
        var kanaNeighborhood = 3
        /// How long an `isModelInstalled` answer is reused.
        var installCheckInterval: TimeInterval = 1
        /// 混雑時の一時停止: arrivals within this many seconds count toward pausing the final stage.
        var burstArrivalWindow: TimeInterval = 2

        init() {}
    }

    /// Called on the main actor when the items of a window changed outside `process`
    /// (a translation finished, a partial result arrived, a job failed).
    var onItemsChanged: ((WindowKey) -> Void)?
    /// Called on the main actor when `activity` changed.
    var onActivityChanged: ((TranslationActivity) -> Void)?
    private(set) var activity = TranslationActivity()
    /// Models of the window the status describes: the frontmost app's most recently scanned window, else
    /// the most recently scanned one, else the plan of the last `process` call (nil before the first one).
    var modelPlan: TranslationModelPlan? { orderedWindows().first?.plan ?? lastPlan }

    let cache: TranslationCache
    private let backend: any TranslationBackend
    private let configuration: Configuration
    private let frontmostPID: @MainActor () -> pid_t?

    private var windows: [WindowKey: WindowState] = [:]
    private var scanCounter = 0
    /// Plan of the most recent `process` call; describes the status once every window is gone.
    private var lastPlan: TranslationModelPlan?
    /// 混雑時の一時停止 per app: a flood in one app (say a log in a background terminal) must not hold the
    /// upgrades of another. The settings are global (one inference engine).
    private var bursts: [pid_t: BurstControl] = [:]
    private var burstSettings = BurstControlSettings()
    private var burstWakeTask: Task<Void, Never>?
    private var burstWakeDate: Date?
    private var running: RunningJob?
    private var manualQueue: [UUID] = []
    private var manualWaiters: [UUID: ManualRequest] = [:]
    private var partials: [TranslationSubject: String] = [:]
    /// Finished chunks of interrupted upgrades, so they resume instead of starting over.
    private var resumableChunks: [JobID: [String]] = [:]
    private var failures: [JobID: FailureRecord] = [:]
    private var lastError: String?
    private var wakeTask: Task<Void, Never>?
    private var wakeDate: Date?
    private var acceptance: [AcceptanceKey: Bool] = [:]
    private var regexCache: [[String]: [NSRegularExpression]] = [:]
    /// Displayed translations of texts with links, so redraws do not map them again.
    private var linkMaps: [LinkMapKey: TranslationLinks.Mapped] = [:]
    private var installCache: [ModelSize: (installed: Bool, checkedAt: Date)] = [:]
    /// Texts sent by browser extensions (one video's captions each), see "Browser extension documents".
    private var documents: [ExternalDocumentKey: ExternalDocument] = [:]
    private var documentCounter = 0

    init(
        backend: any TranslationBackend,
        cache: TranslationCache,
        configuration: Configuration = Configuration(),
        frontmostPID: @escaping @MainActor () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    ) {
        self.backend = backend
        self.cache = cache
        self.configuration = configuration
        self.frontmostPID = frontmostPID
    }

    // MARK: - Public API

    /// Records the window's latest segments, schedules missing translations and returns what to draw now.
    /// Segments rejected by the filters or the same-language check produce no item.
    @discardableResult
    func process(snapshot: WindowSnapshot, settings: EffectiveSettings) -> [OverlayItem] {
        guard settings.mode != .off else {
            forget(window: snapshot.key)
            applyCacheSettings(settings.global)
            return []
        }
        scanCounter += 1
        let previous = windows[snapshot.key]
        var state = makeWindowState(snapshot, settings: settings, sequence: scanCounter)
        let continued = continuations(in: state, previous: previous)
        state.continued = Set(continued.keys)
        for subject in state.subjects {
            state.arrival[subject] =
                previous?.arrival[subject] ?? continued[subject].flatMap { previous?.arrival[$0] } ?? scanCounter
        }
        if snapshot.truncated, let previous {
            var unreached = previous.subjects.union(previous.unreached).subtracting(state.subjects)
            unreached.subtract(continued.values)
            if unreached.count > Self.maxUnreached { unreached = [] }
            state.unreached = unreached
            for subject in unreached { state.arrival[subject] = previous.arrival[subject] }
        }
        windows[snapshot.key] = state
        lastPlan = state.plan
        burstSettings = settings.progressive.burstControl
        recordArrivals(in: state, previous: previous)
        applyCacheSettings(settings.global)
        cancelRunningJobIfStale()
        pruneFailures()
        pruneResumableChunks()
        pump()
        return items(for: snapshot.key)
    }

    /// Items for the window's latest snapshot with the current translation state. Texts with links carry
    /// them (`originalLinks`) and where they are in the translation (`links`); the translation never shows the
    /// link markers sent to the model (`TranslationLinks`).
    func items(for window: WindowKey) -> [OverlayItem] {
        guard let state = windows[window] else { return [] }
        let now = Date()
        return state.entries.map { entry in
            let (output, itemState) = display(for: entry.subject, in: state, now: now)
            var item = OverlayItem(
                id: entry.segmentID, axFrame: entry.axFrame, original: entry.original, translation: output,
                state: itemState, style: entry.style, lineFrames: entry.lineFrames, originalLinks: entry.links)
            if let plan = entry.linkPlan, !output.isEmpty {
                let mapped = mapLinks(plan, output: output, isPartial: itemState == .streaming)
                item.translation = mapped.text
                item.links = mapped.links
            }
            return item
        }
    }

    /// Areas of the window's latest snapshot that translations must leave visible (AX coordinates): content
    /// that is not translated, including texts skipped as already in the target language.
    func obstacles(for window: WindowKey) -> [CGRect] {
        windows[window]?.obstacles ?? []
    }

    /// Drops the window (closed, app quit, no longer tracked). Its pending jobs disappear with it.
    func forget(window: WindowKey) {
        guard windows.removeValue(forKey: window) != nil else { return }
        cancelRunningJobIfStale()
        pruneResumableChunks()
        // The window may have been what kept the final stage paused; pump re-evaluates and resumes it.
        pump()
    }

    /// Stops all work: windows are forgotten, the running call is cancelled and waiting
    /// `translateOnce` calls return nil. Cached translations are kept, and so are browser extension documents
    /// (they do not depend on 翻訳を有効にする; the next `sync` resumes their work).
    func cancelAll() {
        windows.removeAll()
        for id in manualQueue { manualWaiters.removeValue(forKey: id)?.continuation.resume(returning: nil) }
        manualQueue.removeAll()
        if let running {
            running.cancelled = true
            running.task?.cancel()
        }
        partials.removeAll()
        resumableChunks.removeAll()
        failures.removeAll()
        linkMaps.removeAll()
        wakeTask?.cancel()
        wakeTask = nil
        wakeDate = nil
        bursts.removeAll()
        burstWakeTask?.cancel()
        burstWakeTask = nil
        burstWakeDate = nil
        updateActivity()
    }

    /// Translates one text outside the real-time loop (selection, manual popup) with the best
    /// installed model of the app's plan. Jumps ahead of background jobs and is never held by
    /// 混雑時の一時停止. Returns nil on failure or cancellation.
    func translateOnce(text: String, settings: EffectiveSettings) async -> String? {
        applyCacheSettings(settings.global)
        let normalized = TextSanitizer.normalize(text, maxLength: configuration.manualTextCharacterLimit)
        guard !normalized.isEmpty, !Task.isCancelled else { return nil }
        let manualPlan = makePlan(settings)
        guard let model = manualPlan.final ?? manualPlan.draft else { return nil }
        let (subject, glossary) = makeSubject(normalized, settings: settings)
        if let hit = cache.lookup(subject.key(for: settings.global.finalModel)) { return hit.translation }
        if let hit = cache.lookup(subject.key(for: model)) { return hit.translation }

        let id = UUID()
        let job = Job(
            id: JobID(subject: subject, model: model), glossary: glossary, history: [], useHistory: false,
            streams: false, isUpgrade: false, manualID: id)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                manualWaiters[id] = ManualRequest(job: job, continuation: continuation)
                manualQueue.append(id)
                pump()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelManual(id) }
        }
    }

    /// Clears the failure back-off so failed texts are tried again right away.
    func retryFailed() {
        failures.removeAll()
        for key in windows.keys { onItemsChanged?(key) }
        pump()
    }

    /// Empties the cache (memory and disk) and redraws every window as pending.
    func clearCache() {
        cache.clear()
        resumableChunks.removeAll()
        linkMaps.removeAll()
        for key in windows.keys { onItemsChanged?(key) }
        pump()
    }

    // MARK: - Snapshot handling

    private struct Entry {
        var segmentID: String
        var original: String
        var axFrame: CGRect
        var subject: TranslationSubject
        /// Glossary terms that occur in the text.
        var glossary: [GlossaryTerm]
        /// The original's look and line rectangles, passed through to the overlay.
        var style: TextStyleHint
        var lineFrames: [CGRect]
        /// The segment's links, passed through to the overlay.
        var links: [SegmentLink] = []
        /// How the links travel through translation; nil when the text has none.
        var linkPlan: TranslationLinks.Plan?
    }

    private struct WindowState {
        var key: WindowKey
        var pid: pid_t
        var settings: EffectiveSettings
        /// Models for this window's app (its 段階翻訳 override applied).
        var plan: TranslationModelPlan
        /// Accepted segments in reading order.
        var entries: [Entry]
        var subjects: Set<TranslationSubject>
        var sequence: Int
        /// What the overlay must leave visible: the snapshot's obstacles and the texts that are not translated.
        var obstacles: [CGRect] = []
        /// Scan number at which each text first appeared in this window (kept while it stays on screen, and
        /// passed on when it changes in place).
        var arrival: [TranslationSubject: Int] = [:]
        /// Texts that replaced a text of the previous scan in place (see `continuations`). They are likely
        /// to change again: a paragraph still streaming in, or one scrolling off the edge.
        var continued: Set<TranslationSubject> = []
        /// Texts an earlier scan showed that a later partial scan (`WindowSnapshot.truncated`) did not reach.
        /// They are most likely still on screen, so their running translation goes on and they are not new
        /// when they come back. The next complete scan clears them.
        var unreached: Set<TranslationSubject> = []

        /// Texts this window shows or most likely still shows.
        func knows(_ subject: TranslationSubject) -> Bool {
            subjects.contains(subject) || unreached.contains(subject)
        }
    }

    /// Above this many unreached texts a window forgets them all (a huge window scanned partially for long).
    private static let maxUnreached = 512

    private struct LinkMapKey: Hashable {
        var plan: TranslationLinks.Plan
        var output: String
        var isPartial: Bool
    }

    private struct AcceptanceKey: Hashable {
        var text: String
        var target: String
        var policy: SameLanguagePolicy
        var kanaNearby: Bool
        var minLength: Int
        var patterns: [String]
    }

    private func makeWindowState(_ snapshot: WindowSnapshot, settings: EffectiveSettings, sequence: Int)
        -> WindowState
    {
        let global = settings.global
        let segments = Array(snapshot.segments.sorted { $0.order < $1.order }.prefix(max(1, global.maxSegmentsPerScan)))
        let hasKana = segments.map { LanguageDetector.containsKana($0.text) }
        let regexes = compiledPatterns(settings.profile.ignorePatterns)
        let glossary = TranslationRequestFactory.sanitizedGlossary(settings.glossary)
        let neighborhood = max(0, configuration.kanaNeighborhood)

        var entries: [Entry] = []
        var obstacles = snapshot.obstacles
        for (index, segment) in segments.enumerated() {
            let maxLength = max(1, global.maxSegmentCharacters)
            let text: String
            var linkPlan: TranslationLinks.Plan?
            if segment.links.isEmpty {
                text = TextSanitizer.normalize(segment.text, maxLength: maxLength)
            } else {
                let mapped = TextSanitizer.normalizeMapped(segment.text, maxLength: maxLength)
                text = mapped.text
                linkPlan = TranslationLinks.plan(source: segment.text, links: segment.links, normalized: mapped)
            }
            guard !text.isEmpty else { continue }
            let lower = max(0, index - neighborhood)
            let upper = min(segments.count - 1, index + neighborhood)
            let kanaNearby = (lower...upper).contains { $0 != index && hasKana[$0] }
            guard accepts(text, settings: settings, regexes: regexes, kanaNearby: kanaNearby) else {
                // Left in its own language (or filtered): the translations around it must not cover it.
                obstacles.append(contentsOf: segment.lineFrames.isEmpty ? [segment.axFrame] : segment.lineFrames)
                continue
            }
            // The filters judge the text itself; the model gets it with the link markers.
            let (subject, terms) = makeSubject(linkPlan?.input ?? text, settings: settings, sanitizedGlossary: glossary)
            entries.append(
                Entry(
                    segmentID: segment.id, original: segment.text, axFrame: segment.axFrame, subject: subject,
                    glossary: terms, style: segment.style, lineFrames: segment.lineFrames, links: segment.links,
                    linkPlan: linkPlan))
        }
        return WindowState(
            key: snapshot.key, pid: snapshot.pid, settings: settings, plan: makePlan(settings), entries: entries,
            subjects: Set(entries.map(\.subject)), sequence: sequence, obstacles: obstacles)
    }

    /// New texts of this scan that replace a text of the window's previous scan in place, mapped to the text
    /// they replace: a paragraph that grows while it is typed or streamed, or loses a line at the top or the
    /// bottom as the window scrolls. Segment ids hash the text, so the text is what ties the two together.
    /// Each old text is used once.
    private func continuations(in state: WindowState, previous: WindowState?)
        -> [TranslationSubject: TranslationSubject]
    {
        guard let previous else { return [:] }
        var gone: [(subject: TranslationSubject, length: Int)] = []
        var seen = Set<TranslationSubject>()
        for entry in previous.entries
        where !state.subjects.contains(entry.subject) && seen.insert(entry.subject).inserted {
            gone.append((entry.subject, entry.subject.text.count))
        }
        var result: [TranslationSubject: TranslationSubject] = [:]
        for entry in state.entries where !gone.isEmpty {
            let subject = entry.subject
            guard !previous.subjects.contains(subject), result[subject] == nil else { continue }
            let length = subject.text.count
            guard
                let index = gone.firstIndex(where: {
                    Self.isEditedInPlace($0.subject.text, $0.length, subject.text, length)
                })
            else { continue }
            result[subject] = gone.remove(at: index).subject
        }
        return result
    }

    /// One text is the other with text added or cut at the start or the end. The shared part must be at least
    /// 8 characters: shorter ones match by coincidence.
    private static func isEditedInPlace(_ old: String, _ oldLength: Int, _ new: String, _ newLength: Int) -> Bool {
        let (short, shortLength, long) = oldLength <= newLength ? (old, oldLength, new) : (new, newLength, old)
        guard shortLength >= 8, old != new else { return false }
        return long.hasPrefix(short) || long.hasSuffix(short)
    }

    private func makeSubject(
        _ normalized: String, settings: EffectiveSettings, sanitizedGlossary: [GlossaryTerm]? = nil
    ) -> (TranslationSubject, [GlossaryTerm]) {
        let target = settings.targetLanguage
        let glossary = sanitizedGlossary ?? TranslationRequestFactory.sanitizedGlossary(settings.glossary)
        let terms = TranslationRequestFactory.relevantGlossary(glossary, for: normalized)
        let subject = TranslationSubject(
            text: normalized, targetLanguage: target, sourceLanguage: Self.sourceLanguage(settings),
            form: TranslationRequestFactory.form(targetLanguage: target, setting: settings.japaneseForm),
            context: TextSanitizer.normalize(settings.profile.context, maxLength: configuration.contextCharacterLimit),
            glossaryFingerprint: TranslationSubject.fingerprint(of: terms))
        return (subject, terms)
    }

    private func accepts(
        _ text: String, settings: EffectiveSettings, regexes: [NSRegularExpression], kanaNearby: Bool
    ) -> Bool {
        let policy = settings.global.sameLanguagePolicy
        let key = AcceptanceKey(
            text: text, target: settings.targetLanguage, policy: policy, kanaNearby: kanaNearby,
            minLength: settings.minTextLength, patterns: settings.profile.ignorePatterns)
        if let cached = acceptance[key] { return cached }
        let accepted =
            TranslationTextFilter.rejection(for: text, minLength: settings.minTextLength, ignorePatterns: regexes) == nil
            && !LanguageDetector.shouldSkip(
                text, target: settings.targetLanguage, policy: policy, kanaNearby: kanaNearby)
        if acceptance.count >= 8000 { acceptance.removeAll(keepingCapacity: true) }
        acceptance[key] = accepted
        return accepted
    }

    private func compiledPatterns(_ patterns: [String]) -> [NSRegularExpression] {
        guard !patterns.isEmpty else { return [] }
        if let cached = regexCache[patterns] { return cached }
        let compiled = TranslationTextFilter.compile(patterns)
        if regexCache.count > 64 { regexCache.removeAll() }
        regexCache[patterns] = compiled
        return compiled
    }

    // MARK: - Display state

    private func display(for subject: TranslationSubject, in window: WindowState, now: Date)
        -> (String, OverlayItemState)
    {
        let settings = window.settings
        if let best = cache.best(for: subject, finalModel: settings.global.finalModel, draftModel: settings.draftModel) {
            return (best.translation, best.isFinal ? .final : .draft)
        }
        if settings.global.streamPartialResults, let partial = partials[subject], !partial.isEmpty {
            return (partial, .streaming)
        }
        return (String(), isFailed(subject, plan: window.plan, now: now) ? .failed : .pending)
    }

    /// The translation as displayed (markup removed, links located), mapped once per output.
    private func mapLinks(_ plan: TranslationLinks.Plan, output: String, isPartial: Bool) -> TranslationLinks.Mapped {
        let key = LinkMapKey(plan: plan, output: output, isPartial: isPartial)
        if let cached = linkMaps[key] { return cached }
        let mapped = TranslationLinks.map(output, plan: plan, isPartial: isPartial)
        if linkMaps.count >= 2048 { linkMaps.removeAll(keepingCapacity: true) }
        linkMaps[key] = mapped
        return mapped
    }

    private func hasAnyTranslation(_ subject: TranslationSubject) -> Bool {
        cache.best(for: subject, finalModel: nil, draftModel: nil, touch: false) != nil
    }

    /// No translation will come for now: no model, or every first-stage model is backing off.
    private func isFailed(_ subject: TranslationSubject, plan: TranslationModelPlan, now: Date) -> Bool {
        guard plan.hasModel else { return true }
        return plan.firstStageModels.allSatisfy { isBlocked(JobID(subject: subject, model: $0), now: now) }
    }

    // MARK: - Jobs

    private struct JobID: Hashable {
        var subject: TranslationSubject
        var model: ModelSize
    }

    private struct Job {
        var id: JobID
        var glossary: [GlossaryTerm]
        var history: [TranslationHistoryPair]
        /// Also pass earlier chunks of a long text as history.
        var useHistory: Bool
        var streams: Bool
        /// A final translation of text that already shows one; yields to first-stage jobs between chunks.
        var isUpgrade: Bool
        var manualID: UUID?
    }

    private final class RunningJob {
        let job: Job
        var task: Task<Void, Never>?
        var relay: PartialRelay?
        var cancelled = false

        init(job: Job) { self.job = job }
    }

    private struct ManualRequest {
        var job: Job
        var continuation: CheckedContinuation<String?, Never>
        var attempts = 0
    }

    private struct FailureRecord {
        var attempts = 0
        var blockedUntil: Date?
        var backoff: TimeInterval
    }

    private func pump() {
        let now = Date()
        updateBurst(now: now)
        if running == nil {
            var manualJob: Job?
            while manualJob == nil, !manualQueue.isEmpty {
                manualJob = manualWaiters[manualQueue.removeFirst()]?.job
            }
            if let job = manualJob ?? nextJob() { start(job) }
        } else if !manualQueue.isEmpty, let running, running.job.manualID == nil, !running.cancelled {
            // An explicit request preempts background work; the dropped job is picked again later.
            running.cancelled = true
            running.task?.cancel()
        }
        updateActivity()
        scheduleWakeIfNeeded()
        scheduleBurstWake()
    }

    private func nextJob() -> Job? {
        let now = Date()
        let ordered = orderedWindows()
        let documents = orderedDocuments()

        // Captions about to be shown come before everything but manual requests: they cannot wait.
        if let job = urgentDocumentJob(documents, now: now) { return job }
        if let job = firstStageJob(windows: ordered, now: now) { return job }
        for window in ordered {
            // 混雑時の一時停止: while new text keeps flooding into this app, its drafts go first and its upgrades wait.
            guard let final = window.plan.final, !isRefinementPaused(window) else { continue }
            for (index, entry) in window.entries.enumerated()
            where !cache.contains(entry.subject.key(for: final))
                && !isBlocked(JobID(subject: entry.subject, model: final), now: now)
            {
                return makeJob(entry, index: index, window: window, model: final)
            }
        }
        // Reading ahead in a document only uses time nothing on screen needs.
        return prefetchDocumentJob(documents, now: now)
    }

    /// The first translation of a text that has none: the window's draft model, its final model when it
    /// translates in one stage, or the final model when the draft is backing off.
    private func firstStageJob(windows: [WindowState], now: Date) -> Job? {
        for window in windows {
            guard let model = window.plan.draft ?? window.plan.final else { continue }
            for index in firstStageOrder(window) {
                let entry = window.entries[index]
                guard !hasAnyTranslation(entry.subject), !isBlocked(JobID(subject: entry.subject, model: model), now: now)
                else { continue }
                return makeJob(entry, index: index, window: window, model: model)
            }
        }
        for window in windows {
            guard let draft = window.plan.draft, let final = window.plan.final else { continue }
            for (index, entry) in window.entries.enumerated()
            where !hasAnyTranslation(entry.subject)
                && isBlocked(JobID(subject: entry.subject, model: draft), now: now)
                && !isBlocked(JobID(subject: entry.subject, model: final), now: now)
            {
                return makeJob(entry, index: index, window: window, model: final)
            }
        }
        return nil
    }

    /// Reading order, except while the window's final stage is paused for a flood of new text: then the newest
    /// texts go first. Older ones are the ones scrolling away; drafting them first would mostly be cancelled.
    /// Texts that just changed in place go last: their draft would be cancelled by the next change.
    private func firstStageOrder(_ window: WindowState) -> [Int] {
        let indices = Array(window.entries.indices)
        guard isRefinementPaused(window) else { return indices }
        return indices.sorted { a, b in
            let p = window.entries[a].subject
            let q = window.entries[b].subject
            let pChanged = window.continued.contains(p)
            if pChanged != window.continued.contains(q) { return !pChanged }
            let x = window.arrival[p] ?? 0
            let y = window.arrival[q] ?? 0
            return x != y ? x > y : a < b
        }
    }

    /// Whether `nextJob()` would pick a first-stage job now.
    private func hasFirstStageJob() -> Bool {
        let now = Date()
        if urgentDocumentJob(Array(documents.values), now: now) != nil { return true }
        guard !windows.isEmpty else { return false }
        return firstStageJob(windows: Array(windows.values), now: now) != nil
    }

    private func orderedWindows() -> [WindowState] {
        let front = frontmostPID()
        return windows.values.sorted { a, b in
            let aFront = a.pid == front
            let bFront = b.pid == front
            if aFront != bFront { return aFront }
            return a.sequence > b.sequence
        }
    }

    private func makeJob(_ entry: Entry, index: Int, window: WindowState, model: ModelSize) -> Job {
        let settings = window.settings
        let useHistory = settings.profile.useConversationHistory
        let translated = hasAnyTranslation(entry.subject)
        return Job(
            id: JobID(subject: entry.subject, model: model),
            glossary: entry.glossary,
            history: useHistory ? history(before: index, in: window) : [],
            useHistory: useHistory,
            streams: settings.global.streamPartialResults && !translated,
            isUpgrade: translated,
            manualID: nil)
    }

    /// Earlier segments of the same window that already have a finished translation, newest
    /// last, within `historyCharacterLimit`.
    private func history(before index: Int, in window: WindowState) -> [TranslationHistoryPair] {
        guard let model = window.plan.resultModel, index > 0 else { return [] }
        let current = window.entries[index].subject
        var pairs: [TranslationHistoryPair] = []
        var total = 0
        for entry in window.entries[..<index].reversed() where entry.subject != current {
            guard let cached = cache.peek(entry.subject.key(for: model)) else { continue }
            // History is plain text: link markers there could make the model add brackets to other texts.
            var source = entry.subject.text
            var output = cached.translation
            if let plan = entry.linkPlan, plan.usesMarkup {
                source = plan.plain
                output = mapLinks(plan, output: output, isPartial: false).text
            }
            let translation = TextSanitizer.neutralizeControlSequences(output)
            let size = source.count + translation.count
            if total + size > configuration.historyCharacterLimit { break }
            total += size
            pairs.append(TranslationHistoryPair(source: source, translation: translation))
        }
        return pairs.reversed()
    }

    private static func sourceLanguage(_ settings: EffectiveSettings) -> String? {
        guard let source = settings.global.sourceLanguage?.trimmingCharacters(in: .whitespaces), !source.isEmpty
        else { return nil }
        return source
    }

    // MARK: - Running a job

    private func start(_ job: Job) {
        let runningJob = RunningJob(job: job)
        if job.streams {
            runningJob.relay = PartialRelay(interval: configuration.partialUpdateInterval) {
                [weak self, weak runningJob] text in
                guard let self, let runningJob else { return }
                self.receivePartial(text, from: runningJob)
            }
        }
        running = runningJob
        runningJob.task = Task { [weak self] in
            guard let self else { return }
            let result = await self.execute(job, relay: runningJob.relay)
            self.finish(runningJob, result: result)
        }
    }

    private func execute(_ job: Job, relay: PartialRelay?) async -> Result<String, Error> {
        let subject = job.id.subject
        let chunks = TextSanitizer.chunks(subject.text, maxLength: configuration.chunkCharacterLimit)
        let separators = chunks.map(\.separator)
        var outputs = resumableChunks.removeValue(forKey: job.id) ?? []
        do {
            for (index, chunk) in chunks.enumerated().dropFirst(outputs.count) {
                try Task.checkCancellation()
                if job.isUpgrade, index > 0, hasFirstStageJob() {
                    // New text should not wait for the whole upgrade: let it be drafted first.
                    throw CancellationError()
                }
                var history = job.history
                if job.useHistory && index > 0 {
                    let previous = zip(chunks[..<index], outputs).map {
                        TranslationHistoryPair(source: $0.text, translation: $1)
                    }
                    history = TranslationRequestFactory.trimHistory(
                        history + previous, limit: configuration.historyCharacterLimit)
                }
                var request = TranslationBackendRequest(
                    text: chunk.text,
                    targetLanguage: subject.targetLanguage,
                    sourceLanguage: subject.sourceLanguage,
                    context: subject.context.isEmpty ? nil : subject.context,
                    glossary: chunks.count > 1
                        ? TranslationRequestFactory.relevantGlossary(job.glossary, for: chunk.text) : job.glossary,
                    form: subject.form,
                    history: history,
                    maxNewTokens: TranslationRequestFactory.maxNewTokens(for: chunk.text))
                let done = outputs
                var onPartial: (@Sendable (String) -> Void)?
                if let relay {
                    onPartial = { @Sendable partial in
                        relay.push(TextSanitizer.join(done + [TextSanitizer.cleanOutput(partial)], separators: separators))
                    }
                }
                var output = TextSanitizer.cleanOutput(
                    try await Self.callBackend(backend, request, model: job.id.model, onPartial: onPartial))
                if !request.history.isEmpty,
                    TranslationRequestFactory.looksWrong(
                        source: chunk.text, translation: output, targetLanguage: subject.targetLanguage)
                {
                    request.history = []
                    output = TextSanitizer.cleanOutput(
                        try await Self.callBackend(backend, request, model: job.id.model, onPartial: onPartial))
                }
                guard !output.isEmpty else { throw TranslationBackendError.failed("空の訳文が返されました") }
                outputs.append(output)
            }
            return .success(TextSanitizer.join(outputs, separators: separators))
        } catch {
            // An interrupted upgrade (it yielded, or a manual request preempted it) is picked again
            // later and continues after the chunks it finished.
            if job.isUpgrade, !outputs.isEmpty, Self.isCancellation(error) { resumableChunks[job.id] = outputs }
            return .failure(error)
        }
    }

    /// Runs the backend off the main actor and forwards cancellation to it.
    private nonisolated static func callBackend(
        _ backend: any TranslationBackend, _ request: TranslationBackendRequest, model: ModelSize,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let work = Task.detached(priority: .userInitiated) {
            try await backend.translate(request, model: model, onPartial: onPartial)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func receivePartial(_ text: String, from runningJob: RunningJob) {
        guard running === runningJob, !runningJob.cancelled else { return }
        let subject = runningJob.job.id.subject
        guard partials[subject] != text else { return }
        partials[subject] = text
        notifyWindows(containing: subject)
    }

    private func finish(_ runningJob: RunningJob, result: Result<String, Error>) {
        guard running === runningJob else { return }
        running = nil
        runningJob.relay?.cancel()
        let job = runningJob.job
        let subject = job.id.subject
        partials[subject] = nil

        switch result {
        case .success(let translation):
            cache.store(translation, for: subject.key(for: job.id.model))
            failures[job.id] = nil
            lastError = nil
            if let id = job.manualID { resolveManual(id, with: translation) }
        case .failure(let error):
            let cancelled = runningJob.cancelled || Self.isCancellation(error)
            if !cancelled { lastError = Self.describe(error) }
            if let id = job.manualID {
                if cancelled {
                    resolveManual(id, with: nil)
                } else if var request = manualWaiters[id], request.attempts == 0 {
                    request.attempts += 1
                    manualWaiters[id] = request
                    manualQueue.insert(id, at: 0)
                } else {
                    resolveManual(id, with: nil)
                }
            } else if !cancelled {
                recordFailure(job.id)
            }
        }
        notifyWindows(containing: subject)
        pump()
    }

    private func cancelRunningJobIfStale() {
        guard let running, running.job.manualID == nil, !running.cancelled else { return }
        let subject = running.job.id.subject
        guard !windows.values.contains(where: { $0.knows(subject) }),
            !documents.values.contains(where: { $0.subjects.contains(subject) })
        else { return }
        running.cancelled = true
        running.task?.cancel()
    }

    private func cancelManual(_ id: UUID) {
        if let index = manualQueue.firstIndex(of: id) {
            manualQueue.remove(at: index)
            resolveManual(id, with: nil)
            updateActivity()
        } else if let running, running.job.manualID == id {
            running.cancelled = true
            running.task?.cancel()
        }
    }

    private func resolveManual(_ id: UUID, with value: String?) {
        manualWaiters.removeValue(forKey: id)?.continuation.resume(returning: value)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case TranslationBackendError.cancelled = error { return true }
        return false
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case TranslationBackendError.modelNotInstalled(let model):
            return "モデル（\(model.displayName)）がインストールされていません"
        case TranslationBackendError.failed(let message):
            return message
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Failures and back-off

    /// One retry right away; after the second failure the job backs off (30 s, 60 s, ... up to 5 min),
    /// then gets one attempt plus one retry again.
    private func recordFailure(_ id: JobID) {
        var record = failures[id] ?? FailureRecord(backoff: configuration.retryBackoff)
        record.attempts += 1
        if record.attempts >= 2 {
            record.attempts = 0
            record.blockedUntil = Date().addingTimeInterval(record.backoff)
            record.backoff = min(record.backoff * 2, configuration.maxRetryBackoff)
        }
        failures[id] = record
    }

    private func isBlocked(_ id: JobID, now: Date) -> Bool {
        guard let until = failures[id]?.blockedUntil else { return false }
        return until > now
    }

    private func pruneFailures() {
        guard failures.count > 256 else { return }
        let live = liveSubjects()
        failures = failures.filter { live.contains($0.key.subject) }
    }

    /// Drops interrupted upgrades whose text left the screen or whose model is no longer the final one
    /// of a window showing it.
    private func pruneResumableChunks() {
        guard !resumableChunks.isEmpty else { return }
        var live = Set<JobID>()
        for window in windows.values {
            guard let final = window.plan.final else { continue }
            for subject in window.subjects.union(window.unreached) {
                live.insert(JobID(subject: subject, model: final))
            }
        }
        for document in documents.values {
            guard let final = document.plan.final else { continue }
            for subject in document.subjects { live.insert(JobID(subject: subject, model: final)) }
        }
        resumableChunks = resumableChunks.filter { live.contains($0.key) }
    }

    /// Wakes up when the earliest back-off of an on-screen text ends, so it is retried (and redrawn
    /// as pending) even if no new scan arrives.
    private func scheduleWakeIfNeeded() {
        let now = Date()
        let live = liveSubjects()
        let earliest = failures.compactMap { id, record -> Date? in
            guard let until = record.blockedUntil, until > now, live.contains(id.subject) else { return nil }
            return until
        }.min()
        guard let earliest else { return }
        if let wakeDate, wakeDate <= earliest, wakeTask != nil { return }
        wakeTask?.cancel()
        wakeDate = earliest
        let delay = earliest.timeIntervalSince(now) + 0.05
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int64(delay * 1000)))
            guard !Task.isCancelled, let self else { return }
            self.wakeTask = nil
            self.wakeDate = nil
            for key in self.windows.keys { self.onItemsChanged?(key) }
            self.pump()
        }
    }

    // MARK: - 混雑時の一時停止 (burst control)

    /// Whether the window's upgrades are held. Only two-stage windows pause: a single-stage window has no
    /// drafts to protect, so another app's flood leaves it alone.
    private func isRefinementPaused(_ window: WindowState) -> Bool {
        window.plan.isTwoStage && bursts[window.pid]?.isPaused == true
    }

    /// The time burst control runs on: uptime, which never steps back. With the wall clock, setting it back
    /// would make earlier arrivals look recent and hold the pause for as long as the step.
    private static func burstClock() -> Date {
        Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime)
    }

    /// Records texts the window shows for the first time and nobody translated yet. Only windows that
    /// translate in two stages count: the pause exists so their drafts keep up. A text that changed in place
    /// (`continued`) is not new: one streaming reply is not a flood.
    private func recordArrivals(in state: WindowState, previous: WindowState?) {
        guard burstSettings.isEnabled, state.plan.isTwoStage else { return }
        let before = previous.map { $0.subjects.union($0.unreached) } ?? []
        let arrived = state.subjects.reduce(0) { count, subject in
            before.contains(subject) || state.continued.contains(subject) || hasAnyTranslation(subject)
                ? count : count + 1
        }
        guard arrived > 0 else { return }
        bursts[state.pid, default: makeBurst()].recordArrivals(arrived, at: Self.burstClock())
    }

    private func makeBurst() -> BurstControl {
        BurstControl(settings: burstSettings, arrivalWindow: configuration.burstArrivalWindow)
    }

    /// Re-evaluates the pause of every app. An upgrade that only paused windows want stops at once (finished
    /// chunks of a long text are kept and resume later); one that a window still upgrading shows goes on.
    private func updateBurst(now: Date) {
        let clock = Self.burstClock()
        var tracked: [pid_t: [WindowState]] = [:]
        for window in windows.values where window.plan.isTwoStage { tracked[window.pid, default: []].append(window) }
        let live = Set(windows.values.map(\.pid))
        var anyPaused = false
        for pid in Set(bursts.keys).union(tracked.keys) {
            var burst = bursts[pid] ?? makeBurst()
            burst.configure(burstSettings)
            let appWindows = tracked[pid] ?? []
            let isActive = burstSettings.isEnabled && !appWindows.isEmpty
            // Only "zero or not" matters while paused and "below the threshold or not" otherwise.
            let limit = burst.isPaused ? 1 : burst.threshold
            let backlog = isActive ? draftBacklog(in: appWindows, limit: limit, now: now) : 0
            burst.evaluate(backlog: backlog, isActive: isActive, now: clock)
            anyPaused = anyPaused || burst.isPaused
            // An app with no window left has nothing worth remembering.
            bursts[pid] = burst.isPaused || live.contains(pid) ? burst : nil
        }
        guard anyPaused, let running, running.job.isUpgrade, running.job.manualID == nil, !running.cancelled
        else { return }
        let job = running.job.id
        let wanted = windows.values.contains {
            $0.subjects.contains(job.subject) && $0.plan.final == job.model && !isRefinementPaused($0)
        }
        guard !wanted else { return }
        running.cancelled = true
        running.task?.cancel()
    }

    /// Distinct on-screen texts still waiting for their first translation, counted up to `limit`.
    /// Left out: texts whose first-stage models are all backing off (they would hold the pause for minutes),
    /// and texts that just changed in place (a reply still streaming in cancels its own drafts until it stops).
    private func draftBacklog(in windows: [WindowState], limit: Int, now: Date) -> Int {
        var waiting = Set<TranslationSubject>()
        for window in windows {
            for entry in window.entries
            where !waiting.contains(entry.subject) && !window.continued.contains(entry.subject)
                && !hasAnyTranslation(entry.subject) && !isFailed(entry.subject, plan: window.plan, now: now)
            {
                waiting.insert(entry.subject)
                if waiting.count >= limit { return waiting.count }
            }
        }
        return waiting.count
    }

    /// Wakes up when the earliest quiet period would end, so a pause ends even if no new scan arrives.
    private func scheduleBurstWake() {
        let now = Self.burstClock()
        guard let due = bursts.values.compactMap({ $0.nextEvaluation(now: now) }).min() else {
            burstWakeTask?.cancel()
            burstWakeTask = nil
            burstWakeDate = nil
            return
        }
        if burstWakeDate == due, burstWakeTask != nil { return }
        burstWakeTask?.cancel()
        burstWakeDate = due
        // A little past the due time, so the arrival that ends the quiet period has aged out by then.
        let delay = max(0, due.timeIntervalSince(now)) + 0.02
        burstWakeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int64(delay * 1000)))
            guard !Task.isCancelled, let self else { return }
            self.burstWakeTask = nil
            self.burstWakeDate = nil
            self.pump()
        }
    }

    // MARK: - Helpers

    private func notifyWindows(containing subject: TranslationSubject) {
        guard let onItemsChanged else { return }
        let keys = windows.values.filter { $0.subjects.contains(subject) }.map(\.key)
        for key in keys { onItemsChanged(key) }
    }

    /// Applies the cache settings. The capacity never drops below what the tracked windows show (two
    /// models per text, plus headroom for popups), so a small setting cannot evict visible translations
    /// and make them translate again on every scan.
    func applyCacheSettings(_ global: GlobalSettings) {
        // Subjects shared by several windows count more than once; a slightly larger cache is harmless.
        let live = windows.values.reduce(0) { $0 + $1.subjects.count }
            + documents.values.reduce(0) { $0 + $1.subjects.count }
        let wanted = max(1, global.cacheCapacity, 2 * live + 256)
        if cache.capacity != wanted { cache.capacity = wanted }
        if cache.isPersistenceEnabled != (global.persistCache && cache.fileURL != nil) {
            cache.isPersistenceEnabled = global.persistCache
        }
    }

    private func makePlan(_ settings: EffectiveSettings) -> TranslationModelPlan {
        TranslationModelPlan.make(settings: settings) { isInstalled($0) }
    }

    private func isInstalled(_ model: ModelSize) -> Bool {
        let now = Date()
        if let cached = installCache[model], now.timeIntervalSince(cached.checkedAt) < configuration.installCheckInterval {
            return cached.installed
        }
        let installed = backend.isModelInstalled(model)
        installCache[model] = (installed, now)
        return installed
    }

    /// The status describes one window (see `modelPlan`); its pause notice is that window's app's, so a flood
    /// in a background app does not claim that the app in front stopped refining.
    private func updateActivity() {
        let status = orderedWindows().first
        let next = TranslationActivity(
            plan: status?.plan ?? lastPlan, runningModel: running?.job.id.model,
            remainingJobs: remainingJobCount() + manualQueue.count, lastError: lastError,
            refinementPaused: status.map { isRefinementPaused($0) } ?? false)
        guard next != activity else { return }
        activity = next
        onActivityChanged?(next)
    }

    private func remainingJobCount() -> Int {
        var seen = Set<TranslationSubject>()
        var count = 0
        for window in windows.values {
            let plan = window.plan
            guard plan.hasModel else { continue }
            for entry in window.entries where seen.insert(entry.subject).inserted {
                if let final = plan.final {
                    if !cache.contains(entry.subject.key(for: final)) { count += 1 }
                } else if !hasAnyTranslation(entry.subject) {
                    count += 1
                }
            }
        }
        for document in documents.values where document.plan.hasModel {
            for index in document.aheadIndices {
                guard let subject = document.entries[index].subject, seen.insert(subject).inserted else { continue }
                if !hasAnyTranslation(subject) { count += 1 }
            }
        }
        return count
    }
}

// MARK: - Browser extension documents

/// Texts sent by a browser extension: one video's captions in time order, or a page's paragraphs. The extension
/// sends the whole list once and then keeps moving `focus` (what is being shown); jobs are picked from the latest
/// state like a window's. The texts being shown (`visible`, or the focus and the `urgentCount` texts after it) are
/// translated before anything but manual requests; the rest is read ahead only when nothing on screen waits:
/// after the focus, and for a page (`readsAll`) then the part before it too. Results are polled
/// (`documentResults`).
extension TranslationCoordinator {
    struct ExternalDocumentKey: Hashable, Sendable {
        /// Who sent it, such as "chrome" or "safari".
        var client: String
        var id: String
    }

    struct ExternalItem: Equatable, Sendable {
        var id: String
        var text: String
    }

    struct ExternalResult: Equatable, Sendable {
        enum State: String, Sendable {
            case pending, draft, final, failed
            /// Not translated: empty, filtered out, or already in the target language.
            case skipped
        }

        var id: String
        var state: State
        /// Empty unless the state is draft or final.
        var translation: String
    }

    struct ExternalProgress: Equatable, Sendable {
        /// Texts still to read (from the focus on; all of a page) that have a translation (or need none).
        var done: Int
        var total: Int
    }

    fileprivate struct ExternalEntry {
        var id: String
        var original: String
        /// nil = skipped.
        var subject: TranslationSubject?
        var glossary: [GlossaryTerm]
    }

    fileprivate struct ExternalDocument {
        var key: ExternalDocumentKey
        var settings: EffectiveSettings
        var plan: TranslationModelPlan
        var entries: [ExternalEntry]
        var indexByID: [String: Int]
        var subjects: Set<TranslationSubject>
        var focus: Int
        var urgentCount: Int
        /// The texts on screen, top to bottom, when the extension says which (a page); else the urgent ones follow
        /// the focus (captions).
        var visible: [Int] = []
        /// A page: everything is read ahead eventually, the part before the focus after the rest.
        var readsAll = false
        /// Last time the extension asked about it; documents left alone expire.
        var lastUsed: Date
        /// Higher = updated more recently; goes first among documents.
        var sequence: Int

        /// What is translated before anything but manual requests.
        var urgentIndices: [Int] {
            if !visible.isEmpty { return visible }
            return Array(focus..<min(entries.count, focus + max(0, urgentCount)))
        }

        /// What is read ahead, in order.
        var aheadIndices: [Int] {
            let after = Array(focus..<entries.count)
            return readsAll ? after + Array(0..<min(focus, entries.count)) : after
        }
    }

    /// Creates or replaces the document's texts (when `items` is given) and moves its focus to the item `focus`
    /// (the first item when nil or unknown). `visible` lists the items on screen when the extension knows them;
    /// `readsAll` reads the whole document ahead, not only what follows the focus. Returns false when the document
    /// is unknown and `items` is nil: the extension must send the texts again (the app restarted, or the document
    /// expired).
    @discardableResult
    func updateDocument(
        _ key: ExternalDocumentKey, items: [ExternalItem]?, focus: String?, urgentCount: Int,
        visible: [String]? = nil, readsAll: Bool = false, settings: EffectiveSettings
    ) -> Bool {
        let now = Date()
        pruneDocuments(now: now)
        documentCounter += 1
        var document: ExternalDocument
        if let items {
            let previous = documents[key]
            if let previous, previous.settings == settings, previous.entries.map(\.original) == items.map(\.text),
                previous.entries.map(\.id) == items.map(\.id)
            {
                document = previous
            } else {
                document = makeDocument(key, items: items, settings: settings)
            }
        } else if let existing = documents[key] {
            document = existing
            if existing.settings != settings { document = makeDocument(key, items: existing.items, settings: settings) }
        } else {
            return false
        }
        document.focus = focus.flatMap { document.indexByID[$0] } ?? 0
        document.urgentCount = urgentCount
        document.visible = (visible ?? []).compactMap { document.indexByID[$0] }
        document.readsAll = readsAll
        document.lastUsed = now
        document.sequence = documentCounter
        documents[key] = document
        lastPlan = document.plan
        applyCacheSettings(settings.global)
        cancelRunningJobIfStale()
        pruneResumableChunks()
        pump()
        return true
    }

    /// The current state of the given items (all items when `ids` is nil), or nil for an unknown document.
    func documentResults(_ key: ExternalDocumentKey, ids: [String]? = nil) -> [ExternalResult]? {
        guard var document = documents[key] else { return nil }
        document.lastUsed = Date()
        documents[key] = document
        let now = Date()
        let indices = ids.map { $0.compactMap { document.indexByID[$0] } } ?? Array(document.entries.indices)
        return indices.map { result(for: document.entries[$0], in: document, now: now) }
    }

    func documentProgress(_ key: ExternalDocumentKey) -> ExternalProgress? {
        guard let document = documents[key] else { return nil }
        let now = Date()
        let ahead = document.aheadIndices
        let done = ahead.filter { result(for: document.entries[$0], in: document, now: now).state != .pending }.count
        return ExternalProgress(done: done, total: ahead.count)
    }

    /// The extension is done with it (tab closed, another video). Its pending jobs disappear with it.
    func closeDocument(_ key: ExternalDocumentKey) {
        guard documents.removeValue(forKey: key) != nil else { return }
        cancelRunningJobIfStale()
        pruneResumableChunks()
        pump()
    }

    fileprivate var documentKeys: Dictionary<ExternalDocumentKey, ExternalDocument>.Keys { documents.keys }

    // MARK: Documents, private

    fileprivate static let documentLifetime: TimeInterval = 300

    private func makeDocument(
        _ key: ExternalDocumentKey, items: [ExternalItem], settings: EffectiveSettings
    ) -> ExternalDocument {
        let glossary = TranslationRequestFactory.sanitizedGlossary(settings.glossary)
        var entries: [ExternalEntry] = []
        var indexByID: [String: Int] = [:]
        var subjects = Set<TranslationSubject>()
        for item in items where indexByID[item.id] == nil {
            let normalized = TextSanitizer.normalize(item.text, maxLength: configuration.manualTextCharacterLimit)
            var entry = ExternalEntry(id: item.id, original: item.text, subject: nil, glossary: [])
            if !normalized.isEmpty, accepts(normalized, settings: settings, regexes: [], kanaNearby: false) {
                let (subject, terms) = makeSubject(normalized, settings: settings, sanitizedGlossary: glossary)
                entry.subject = subject
                entry.glossary = terms
                subjects.insert(subject)
            }
            indexByID[item.id] = entries.count
            entries.append(entry)
        }
        return ExternalDocument(
            key: key, settings: settings, plan: makePlan(settings), entries: entries, indexByID: indexByID,
            subjects: subjects, focus: 0, urgentCount: 0, lastUsed: Date(), sequence: documentCounter)
    }

    private func result(for entry: ExternalEntry, in document: ExternalDocument, now: Date) -> ExternalResult {
        guard let subject = entry.subject else { return ExternalResult(id: entry.id, state: .skipped, translation: "") }
        let settings = document.settings
        if let best = cache.best(for: subject, finalModel: settings.global.finalModel, draftModel: settings.draftModel) {
            return ExternalResult(id: entry.id, state: best.isFinal ? .final : .draft, translation: best.translation)
        }
        let failed = isFailed(subject, plan: document.plan, now: now)
        return ExternalResult(id: entry.id, state: failed ? .failed : .pending, translation: "")
    }

    private func pruneDocuments(now: Date) {
        let expired = documents.filter { now.timeIntervalSince($0.value.lastUsed) > Self.documentLifetime }
        guard !expired.isEmpty else { return }
        for key in expired.keys { documents.removeValue(forKey: key) }
        cancelRunningJobIfStale()
    }

    private func orderedDocuments() -> [ExternalDocument] {
        documents.values.sorted { $0.sequence > $1.sequence }
    }

    /// Texts on screen or in a document.
    private func liveSubjects() -> Set<TranslationSubject> {
        var live = windows.values.reduce(into: Set<TranslationSubject>()) { $0.formUnion($1.subjects) }
        for document in documents.values { live.formUnion(document.subjects) }
        return live
    }

    /// The first translation of a text about to be shown: the draft model when the plan has one.
    private func urgentDocumentJob(_ documents: [ExternalDocument], now: Date) -> Job? {
        for document in documents {
            guard let model = document.plan.draft ?? document.plan.final else { continue }
            for index in document.urgentIndices {
                guard let subject = document.entries[index].subject, !hasAnyTranslation(subject),
                    !isBlocked(JobID(subject: subject, model: model), now: now)
                else { continue }
                return makeDocumentJob(document, index: index, model: model)
            }
        }
        return nil
    }

    /// Reading ahead: the final translation of the texts being shown, then the texts after them (and for a page,
    /// before them), in order, straight with the final model (there is time, so no draft first).
    private func prefetchDocumentJob(_ documents: [ExternalDocument], now: Date) -> Job? {
        for document in documents {
            guard let model = document.plan.final ?? document.plan.draft else { continue }
            for index in document.urgentIndices + document.aheadIndices {
                guard let subject = document.entries[index].subject, !cache.contains(subject.key(for: model)),
                    !isBlocked(JobID(subject: subject, model: model), now: now)
                else { continue }
                return makeDocumentJob(document, index: index, model: model)
            }
        }
        return nil
    }

    private func makeDocumentJob(_ document: ExternalDocument, index: Int, model: ModelSize) -> Job {
        let entry = document.entries[index]
        let subject = entry.subject!
        let useHistory = document.settings.profile.useConversationHistory
        return Job(
            id: JobID(subject: subject, model: model), glossary: entry.glossary,
            history: useHistory ? documentHistory(before: index, in: document) : [], useHistory: useHistory,
            streams: false, isUpgrade: hasAnyTranslation(subject), manualID: nil)
    }

    /// Earlier texts of the document that already have a translation, newest last, within
    /// `historyCharacterLimit`. Stops at the first one without: history must be what came right before.
    private func documentHistory(before index: Int, in document: ExternalDocument) -> [TranslationHistoryPair] {
        guard index > 0 else { return [] }
        var pairs: [TranslationHistoryPair] = []
        var total = 0
        for entry in document.entries[..<index].reversed() {
            guard let subject = entry.subject else { continue }
            guard
                let cached = cache.best(
                    for: subject, finalModel: document.plan.final, draftModel: document.plan.draft, touch: false)
            else { break }
            let translation = TextSanitizer.neutralizeControlSequences(cached.translation)
            let size = subject.text.count + translation.count
            if total + size > configuration.historyCharacterLimit { break }
            total += size
            pairs.append(TranslationHistoryPair(source: subject.text, translation: translation))
        }
        return pairs.reversed()
    }
}

extension TranslationCoordinator.ExternalDocument {
    fileprivate var items: [TranslationCoordinator.ExternalItem] {
        entries.map { TranslationCoordinator.ExternalItem(id: $0.id, text: $0.original) }
    }
}

extension TranslationCoordinator {
    /// Forgets every browser extension document (the extensions were turned off).
    func closeAllDocuments() {
        for key in Array(documentKeys) { closeDocument(key) }
    }
}
