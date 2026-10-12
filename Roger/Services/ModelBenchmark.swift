import Foundation

/// What one model measured on this machine: load time, prompt processing, generation
/// speed, memory, and how long it reasons before answering a trivial question.
struct ModelBenchmark: Codable, Hashable, Identifiable {
    var model: String
    var digest: String?
    var date: Date
    var ollamaVersion: String?
    /// Context length (num_ctx) the measurements were taken at.
    var contextLength: Int
    /// Time to load the weights from disk into memory.
    var loadSeconds: Double
    /// Prompt tokens evaluated per second on a prompt of about 1,500 tokens.
    var promptTokensPerSecond: Double
    /// Tokens generated per second on a 200-token reply with thinking off.
    var generationTokensPerSecond: Double
    /// Memory Ollama reported for the loaded model, and whether all of it sat on the GPU.
    var memoryBytes: Int64?
    var fullyOnGPU: Bool?
    /// "llamacpp" or "mlx" as reported by Ollama 0.40+, nil on older servers.
    var runner: String?
    /// Thinking test (thinking-capable models only): tokens produced (reasoning plus reply)
    /// on a one-sentence question, the time it took, and whether a reply arrived within the cap.
    var thinkingTokens: Int?
    var thinkingSeconds: Double?
    var thinkingAnswered: Bool?
    /// Capabilities Ollama reported for the model when it was measured ("tools", "thinking",
    /// "vision"), so the history can still be filtered once the model is gone.
    var capabilities: [String]?

    var id: String { "\(model)@\(date.timeIntervalSince1970)" }

    var supportsTools: Bool { capabilities?.contains("tools") ?? false }
    var supportsThinking: Bool { capabilities?.contains("thinking") ?? (thinkingTokens != nil) }
    var supportsVision: Bool { capabilities?.contains("vision") ?? false }

    static let thinkingTokenCap = 1200
    static let generationTokens = 200

    var runnerDisplayName: String? { ModelBenchmark.displayName(forRunner: runner) }

    static func displayName(forRunner raw: String?) -> String? {
        switch raw?.lowercased() {
        case nil, "": return nil
        case "llamacpp", "llama.cpp": return "llama.cpp"
        case "mlx": return "MLX"
        case let r?: return r
        }
    }
}

/// Persists every benchmark run next to the chats, newest first.
final class BenchmarkStore {
    private let url: URL

    /// Runs kept per model; older ones are dropped when a new run comes in.
    static let runsPerModel = 50

    init() {
        let dir = AppData.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("benchmarks.json")
    }

    func load() -> [ModelBenchmark] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let runs = try? decoder.decode([ModelBenchmark].self, from: data) {
            return runs.sorted { $0.date > $1.date }
        }
        // Files written before the history was kept hold one run per model, keyed by name.
        let latest = (try? decoder.decode([String: ModelBenchmark].self, from: data)) ?? [:]
        return latest.values.sorted { $0.date > $1.date }
    }

    func save(_ runs: [ModelBenchmark]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(runs) { try? data.write(to: url, options: .atomic) }
    }
}

/// Runs the standard measurements against one model. Every step uses the user's context
/// setting so the numbers reflect how the model behaves in Roger, not in isolation.
enum BenchmarkRunner {
    static let generationPrompt = "Explain in about 200 words how a hash table works. Plain prose, no headings and no lists."
    static let thinkingPrompt = "In one sentence, what is a hash table?"

    @MainActor
    static func run(model: String, digest: String?, client: OllamaClient, contextLength: Int, supportsThinking: Bool,
                    ollamaVersion: String?, progress: @MainActor (String) -> Void) async throws -> ModelBenchmark {
        // Models that cannot think reject the `think` field, so only send it when it applies.
        let thinkOff: Bool? = supportsThinking ? false : nil
        let base: [String: Any] = ["num_ctx": contextLength, "temperature": 0.3, "seed": 7]
        func options(_ extra: [String: Any]) -> [String: Any] { base.merging(extra) { $1 } }

        progress("Unloading, so the load time is measured from disk…")
        try? await client.unloadModel(model)
        try Task.checkCancellation()

        progress("Loading…")
        let warm = try await client.generate(model: model, prompt: "Reply with the single word OK.", think: thinkOff, options: options(["num_predict": 8]))
        let loadSeconds = Double(warm.loadDuration ?? 0) / 1e9
        try Task.checkCancellation()

        progress("Reading memory use…")
        let running = (try? await client.runningModels())?.first { $0.name == model }

        let prompt = longPrompt()
        progress("Prompt processing (about \(prompt.count / 4) tokens)…")
        let long = try await client.generate(model: model, prompt: prompt, think: thinkOff, options: options(["num_predict": 1]))
        let promptRate = rate(long.promptEvalCount, long.promptEvalDuration)
        try Task.checkCancellation()

        progress("Generating \(ModelBenchmark.generationTokens) tokens…")
        let gen = try await client.generate(model: model, prompt: generationPrompt, think: thinkOff, options: options(["num_predict": ModelBenchmark.generationTokens]))
        let generationRate = rate(gen.evalCount, gen.evalDuration)

        var thinkingTokens: Int?, thinkingSeconds: Double?, thinkingAnswered: Bool?
        if supportsThinking {
            try Task.checkCancellation()
            progress("Thinking test (up to \(ModelBenchmark.thinkingTokenCap) tokens)…")
            let t = try await client.generate(model: model, prompt: thinkingPrompt, think: true, options: options(["num_predict": ModelBenchmark.thinkingTokenCap]))
            thinkingTokens = t.evalCount
            thinkingSeconds = Double(t.evalDuration ?? 0) / 1e9
            thinkingAnswered = !(t.response ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return ModelBenchmark(model: model, digest: digest, date: Date(), ollamaVersion: ollamaVersion, contextLength: contextLength,
                              loadSeconds: loadSeconds, promptTokensPerSecond: promptRate, generationTokensPerSecond: generationRate,
                              memoryBytes: running?.sizeVram ?? running?.size,
                              fullyOnGPU: running.flatMap { r in (r.size).flatMap { s in r.sizeVram.map { $0 >= s } } },
                              runner: running?.runner,
                              thinkingTokens: thinkingTokens, thinkingSeconds: thinkingSeconds, thinkingAnswered: thinkingAnswered)
    }

    private static func rate(_ count: Int?, _ nanoseconds: Int64?) -> Double {
        guard let count, let nanoseconds, nanoseconds > 0 else { return 0 }
        return Double(count) / (Double(nanoseconds) / 1e9)
    }

    /// About 1,500 tokens of varied prose, different on every run so Ollama's prompt cache
    /// cannot shortcut the measurement.
    static func longPrompt() -> String {
        let words = """
        server request handler returns a response after reading the configuration file and checking every \
        cached entry while the scheduler assigns work to idle threads before logging the outcome in detail \
        network latency memory bandwidth compiler warning database index query planner garbage collector \
        pointer buffer socket packet protocol encryption certificate signature checksum fragment header
        """.split(separator: " ").map(String.init)
        var state = UInt64(Date().timeIntervalSince1970 * 1000) | 1
        func next() -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(words.count))
        }
        var text = "Reference \(UUID().uuidString). Read the following notes carefully.\n\n"
        for i in 0..<1100 {
            text += words[next()] + (i % 17 == 16 ? ".\n" : " ")
        }
        return text + "\n\nReply with the single word DONE."
    }
}

/// Ollama's local store (`~/.ollama/models`, or `OLLAMA_MODELS`). A pull that fails or is
/// cancelled leaves its downloaded data behind: `-partial` files, and whole blobs when the
/// manifest never arrived. Ollama does not remove them, and they can fill the disk during a
/// trial. `leftovers` finds blobs no manifest refers to; `removeLeftovers` deletes them,
/// sparing anything written in the last two minutes (a download in progress).
enum OllamaStore {
    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["OLLAMA_MODELS"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ollama/models")
    }

    static func leftovers() -> [(url: URL, bytes: Int64, modified: Date)] {
        let fm = FileManager.default
        let manifests = directory.appendingPathComponent("manifests")
        let blobs = directory.appendingPathComponent("blobs")
        guard let files = fm.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey]),
              let names = try? fm.contentsOfDirectory(atPath: blobs.path) else { return [] }
        var referenced: Set<String> = []
        for case let url as URL in files {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var layers = manifest["layers"] as? [[String: Any]] ?? []
            if let config = manifest["config"] as? [String: Any] { layers.append(config) }
            for layer in layers {
                if let digest = layer["digest"] as? String { referenced.insert(digest.replacingOccurrences(of: ":", with: "-")) }
            }
        }
        return names.compactMap { name in
            guard !referenced.contains(name) else { return nil }
            let url = blobs.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            return (url, (attrs[.size] as? Int64) ?? 0, (attrs[.modificationDate] as? Date) ?? .distantPast)
        }
    }

    /// Bytes that `removeLeftovers` would free now (a download in progress is not counted).
    static var leftoverBytes: Int64 {
        leftovers().filter { Date().timeIntervalSince($0.modified) > 120 }.reduce(0) { $0 + $1.bytes }
    }

    /// Deletes the leftovers and returns how many bytes were freed.
    @discardableResult
    static func removeLeftovers() -> Int64 {
        var freed: Int64 = 0
        for item in leftovers() where Date().timeIntervalSince(item.modified) > 120 {
            if (try? FileManager.default.removeItem(at: item.url)) != nil { freed += item.bytes }
        }
        return freed
    }
}
