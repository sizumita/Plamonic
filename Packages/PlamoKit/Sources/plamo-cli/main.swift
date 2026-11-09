import Darwin
import Foundation
import MLX
import PlamoKit

let usage = """
    usage: plamo-cli <command> [options]

    commands:
      tokenize  [-m <variant|path>] [--tokens] [text]          token ids for text (stdin if omitted)
      translate -m <variant|path> -t <lang> [--source <lang>] [--form plain|polite]
                [--context <text>] [--max-tokens N] [--stream] [text]
      bench     -m <variant|path> [--runs N]                   load time, prompt tok/s, gen tok/s, batching, memory
      download  <variant> [--root <dir>]                       download from Hugging Face
      verify    <variant> [--root <dir>]                       validate files and write .complete
      list      [--root <dir>]                                 installed variants

    variants: 0.8b, 0.8b-compact, 2b, 8b, 31b
    """

struct CLIError: Error, CustomStringConvertible {
    var description: String
}

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let valueOptions: Set<String> = [
        "-m", "--model", "-t", "--target", "--source", "--form", "--context", "--max-tokens", "--runs", "--root",
    ]

    init(_ args: ArraySlice<String>) throws {
        var it = args.makeIterator()
        while let a = it.next() {
            if Self.valueOptions.contains(a) {
                guard let v = it.next() else { throw CLIError(description: "\(a) needs a value") }
                options[a] = v
            } else if a.hasPrefix("--") || (a.hasPrefix("-") && a.count == 2) {
                flags.insert(a)
            } else {
                positional.append(a)
            }
        }
    }

    func value(_ names: String...) -> String? {
        for n in names { if let v = options[n] { return v } }
        return nil
    }
}

func readText(_ args: Arguments) -> String {
    if !args.positional.isEmpty { return args.positional.joined(separator: " ") }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    var text = String(decoding: data, as: UTF8.self)
    while text.hasSuffix("\n") { text.removeLast() }
    return text
}

func store(_ args: Arguments) -> PlamoModelStore {
    if let root = args.value("--root") {
        return PlamoModelStore(rootDirectory: URL(fileURLWithPath: (root as NSString).expandingTildeInPath))
    }
    return PlamoModelStore()
}

let variantNames = PlamoModelVariant.allCases.map(\.rawValue).joined(separator: "|")

func variant(named name: String) -> PlamoModelVariant? {
    let lower = name.lowercased()
    return PlamoModelVariant.allCases.first { $0.rawValue == lower || $0.displayName.lowercased() == lower }
}

/// A variant from the store, or a model directory path.
func modelDirectory(_ spec: String, store: PlamoModelStore) throws -> URL {
    if let v = variant(named: spec) {
        guard store.isInstalled(v) else {
            throw CLIError(description: "\(v.displayName) is not installed (plamo-cli download \(v.rawValue))")
        }
        return store.directory(for: v)
    }
    let url = URL(fileURLWithPath: (spec as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) else {
        throw CLIError(description: "no model at \(url.path)")
    }
    return url
}

func fmt(_ value: Double, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", value)
}

/// The process's physical footprint (what Activity Monitor shows as Memory), in bytes.
func physicalFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

func memoryLine(_ label: String) -> String {
    func mb(_ bytes: Int) -> String { fmt(Double(bytes) / 1_048_576) + " MB" }
    return "memory \(label): MLX active \(mb(Memory.activeMemory)), MLX peak \(mb(Memory.peakMemory)), "
        + "MLX cache \(mb(Memory.cacheMemory)), footprint \(mb(physicalFootprint()))"
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func runTokenize(_ args: Arguments) async throws {
    let s = store(args)
    let dir: URL
    if let spec = args.value("-m", "--model") {
        dir = try modelDirectory(spec, store: s)
    } else if let v = PlamoModelVariant.allCases.first(where: { s.isInstalled($0) }) {
        dir = s.directory(for: v)
    } else {
        throw CLIError(description: "no installed model; pass -m <path>")
    }
    let start = Date()
    let tokenizer = try PlamoTokenizer(directory: dir)
    let loadMs = Date().timeIntervalSince(start) * 1000
    let text = readText(args)
    let ids = tokenizer.encode(text)
    print(ids.map(String.init).joined(separator: " "))
    if args.flags.contains("--tokens") {
        print(ids.map { tokenizer.tokenString($0).debugDescription }.joined(separator: " "))
    }
    printError("\(ids.count) tokens, tokenizer load \(fmt(loadMs)) ms")
}

func makeRequest(_ args: Arguments, text: String) throws -> PlamoTranslationRequest {
    guard let target = args.value("-t", "--target") else { throw CLIError(description: "-t <lang> is required") }
    var maxTokens: Int?
    if let m = args.value("--max-tokens") {
        guard let n = Int(m), n > 0 else { throw CLIError(description: "--max-tokens must be a positive integer") }
        maxTokens = n
    }
    return PlamoTranslationRequest(
        text: text,
        targetLanguage: target,
        sourceLanguage: args.value("--source"),
        context: args.value("--context"),
        form: args.value("--form"),
        maxNewTokens: maxTokens)
}

func runTranslate(_ args: Arguments) async throws {
    let s = store(args)
    guard let spec = args.value("-m", "--model") else { throw CLIError(description: "-m <variant|path> is required") }
    let dir = try modelDirectory(spec, store: s)
    let request = try makeRequest(args, text: readText(args))
    let engine = PlamoTranslationEngine(store: s, idleUnloadMinutes: nil)
    let stream = args.flags.contains("--stream")
    var onPartial: (@Sendable (String) -> Void)?
    if stream {
        onPartial = { partial in
            let line = "… " + partial.replacingOccurrences(of: "\n", with: "⏎") + "\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
    let result = try await engine.translate(request, modelDirectory: dir, onPartial: onPartial)
    print(result.text)
    let t = result.timings
    printError(
        "load \(fmt(t.load, 2))s, prompt \(result.promptTokens) tok (reused \(result.reusedPromptTokens)) "
            + "prefill \(fmt(t.prefill * 1000))ms, \(result.generatedTokens) tok decode \(fmt(t.decode * 1000))ms, "
            + "total \(fmt(t.total * 1000))ms"
            + (result.retriedWithoutHistory ? ", retried" : "") + (result.looksWrong ? ", looks wrong" : ""))
}

func runBench(_ args: Arguments) async throws {
    let s = store(args)
    guard let spec = args.value("-m", "--model") else { throw CLIError(description: "-m <variant|path> is required") }
    let dir = try modelDirectory(spec, store: s)
    let runs = Int(args.value("--runs") ?? "5") ?? 5
    let engine = PlamoTranslationEngine(store: s, idleUnloadMinutes: nil)

    let loadTime = try await engine.load(directory: dir)
    print("model: \(dir.lastPathComponent)")
    print("load: \(fmt(loadTime * 1000)) ms")
    print(memoryLine("after load"))

    // Warm up kernels.
    _ = try await engine.translate(
        PlamoTranslationRequest(text: "Hello.", targetLanguage: "ja"), modelDirectory: dir)

    // 1. Short sentence end to end, no prompt reuse.
    await engine.setPromptCacheReuse(false)
    let short = PlamoTranslationRequest(text: "The meeting has been moved to next Monday.", targetLanguage: "ja")
    var latencies = [Double]()
    for _ in 0 ..< runs {
        let r = try await engine.translate(short, modelDirectory: dir)
        latencies.append(r.timings.total)
    }
    latencies.sort()
    print(
        "short sentence (en->ja, \(runs) runs): median \(fmt(latencies[latencies.count / 2] * 1000)) ms, "
            + "min \(fmt(latencies[0] * 1000)) ms")

    // 2. Prompt processing on a long input.
    let paragraph = """
        Plamonic reads the text of other applications through the accessibility interface, translates it \
        on the device, and draws the translation over the original text. Because everything runs locally, \
        private conversations never leave the computer, and translations appear while the user is reading. \
        The application keeps a small cache of recent translations so that scrolling back does not trigger \
        new work, and it refines quick drafts from a small model with a larger model when the machine is idle.
        """
    let long = Array(repeating: paragraph, count: 6).joined(separator: "\n")
    let prefillRequest = PlamoTranslationRequest(text: long, targetLanguage: "ja", maxNewTokens: 1)
    var promptRates = [Double]()
    var promptTokens = 0
    for _ in 0 ..< max(1, runs / 2) {
        let r = try await engine.translate(prefillRequest, modelDirectory: dir)
        promptTokens = r.promptTokens
        promptRates.append(Double(r.promptTokens) / r.timings.prefill)
    }
    promptRates.sort()
    print(
        "prompt: \(promptTokens) tokens, median \(fmt(promptRates[promptRates.count / 2])) tok/s, "
            + "best \(fmt(promptRates.last!)) tok/s")

    // 3. Generation speed on a paragraph.
    var genRates = [Double]()
    var generated = 0
    for _ in 0 ..< max(1, runs / 2) {
        let r = try await engine.translate(
            PlamoTranslationRequest(text: paragraph, targetLanguage: "ja"), modelDirectory: dir)
        generated = r.generatedTokens
        genRates.append(Double(max(r.generatedTokens - 1, 1)) / r.timings.decode)
    }
    genRates.sort()
    print(
        "generation: \(generated) tokens, median \(fmt(genRates[genRates.count / 2])) tok/s, "
            + "best \(fmt(genRates.last!)) tok/s")

    // 4. Batched generation: 16 requests one after another, then up to N at a time (median of 3 rounds).
    let sentences = [
        "The meeting has been moved to next Monday.",
        "Please restart the application after installing the update.",
        "I left my umbrella on the train this morning.",
        "Could you send me the slides from yesterday's presentation?",
        "The weather forecast says it will snow tomorrow night.",
        "Our team finished the migration two days ahead of schedule.",
        "This function returns nil when the file does not exist.",
        "Thanks for the quick review, I'll merge it after lunch.",
    ]
    let requests = ["ja", "zh-hans"].flatMap { target in
        sentences.map { PlamoTranslationRequest(text: $0, targetLanguage: target) }
    }
    func translateAll(width: Int) async throws -> (TimeInterval, Int) {
        await engine.setMaxBatchSize(width)
        let started = Date()
        // Like the app: at most `width` translations in flight, the next one starts when one finishes.
        let tokens = try await withThrowingTaskGroup(of: Int.self) { tasks in
            var next = 0
            var total = 0
            func add() {
                let request = requests[next]
                next += 1
                tasks.addTask { try await engine.translate(request, modelDirectory: dir).generatedTokens }
            }
            while next < min(width, requests.count) { add() }
            while let done = try await tasks.next() {
                total += done
                if next < requests.count { add() }
            }
            return total
        }
        return (Date().timeIntervalSince(started), tokens)
    }
    await engine.setPromptCacheReuse(true)
    var baseline = 0.0
    for width in [1, 2, 4, 8] {
        _ = try await translateAll(width: width)  // compiles the kernels for these batch shapes
        var rounds = [(TimeInterval, Int)]()
        for _ in 0 ..< 3 { rounds.append(try await translateAll(width: width)) }
        rounds.sort { $0.0 < $1.0 }
        let (elapsed, tokens) = rounds[1]
        if width == 1 { baseline = elapsed }
        print(
            "batch \(width): \(requests.count) translations in \(fmt(elapsed * 1000)) ms, "
                + "\(fmt(Double(tokens) / elapsed)) tok/s, \(fmt(baseline / elapsed, 2))x")
    }
    await engine.setMaxBatchSize(8)
    print(memoryLine("after runs"))
}

func runDownload(_ args: Arguments) async throws {
    guard let name = args.positional.first, let v = variant(named: name) else {
        throw CLIError(description: "download <\(variantNames)>")
    }
    let s = store(args)
    print("downloading \(v.repoID) into \(s.directory(for: v).path)")
    let start = Date()
    try await s.download(v) { p in
        let line = String(
            format: "\r%5.1f%%  %.2f / %.2f GB  %@", p.fractionCompleted * 100, Double(p.completedBytes) / 1e9,
            Double(p.totalBytes) / 1e9, p.currentFile)
        FileHandle.standardError.write(Data(line.utf8))
    }
    printError("")
    print("done in \(fmt(Date().timeIntervalSince(start)))s, \(fmt(Double(s.installedBytes(v)) / 1e9, 2)) GB")
}

func runVerify(_ args: Arguments) throws {
    guard let name = args.positional.first, let v = variant(named: name) else {
        throw CLIError(description: "verify <\(variantNames)>")
    }
    let s = store(args)
    if let problem = PlamoModelStore.validationProblem(directory: s.directory(for: v)) {
        throw CLIError(description: "\(v.displayName): \(problem)")
    }
    try s.markInstalledIfValid(v)
    print("\(v.displayName): ok, marked installed")
}

func runList(_ args: Arguments) {
    let s = store(args)
    let width = PlamoModelVariant.allCases.map(\.rawValue.count).max() ?? 0
    for v in PlamoModelVariant.allCases {
        let installed = s.isInstalled(v)
        let size = s.installedBytes(v)
        print(
            "\(v.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)) "
                + (installed ? "installed" : "-        ") + "  \(fmt(Double(size) / 1e9, 2)) GB  \(s.directory(for: v).path)")
    }
}

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    print(usage)
    exit(1)
}
do {
    let args = try Arguments(argv.dropFirst(2))
    switch argv[1] {
    case "tokenize": try await runTokenize(args)
    case "translate": try await runTranslate(args)
    case "bench": try await runBench(args)
    case "download": try await runDownload(args)
    case "verify": try runVerify(args)
    case "list": runList(args)
    case "-h", "--help", "help": print(usage)
    default:
        print(usage)
        exit(1)
    }
} catch {
    printError("error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    exit(1)
}
