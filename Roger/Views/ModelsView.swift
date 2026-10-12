import SwiftUI

struct ModelsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pullName = ""
    @State private var modelToDelete: OllamaModelInfo?
    @State private var expanded: Set<String> = []

    private let suggested: [(name: String, note: String)] = [
        ("qwen2.5-coder:7b", "Strong coder, tools"),
        ("qwen3:8b", "General + thinking, tools"),
        ("llama3.1:8b", "Meta, tools"),
        ("gpt-oss:20b", "OpenAI open-weight, tools"),
        ("devstral:24b", "Agentic coding, tools"),
        ("gemma3:12b", "Google, vision"),
        ("deepseek-r1:8b", "Reasoning"),
        ("mistral:7b", "Fast, tools"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Models").font(.title2.bold())
                    Text(headerSummary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isBenchmarking {
                    Button("Cancel benchmark") { model.cancelBenchmark() }
                } else {
                    Button { model.benchmarkAll() } label: { Label("Benchmark all", systemImage: "gauge.with.dots.needle.67percent") }
                        .help("Measure load time, prompt and generation speed, memory and thinking length for every installed model, one after the other. About a minute per model; chats are paused meanwhile.")
                        .disabled(model.models.isEmpty || model.isAnyGenerating || model.isPulling || !model.status.isConnected)
                }
                Button { Task { await model.refreshModels() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if case .unreachable = model.status {
                OllamaBanner()
            }

            List {
                Section("Installed (\(model.models.count))") {
                    if let err = model.benchmarkError {
                        Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    }
                    if model.models.isEmpty {
                        Text("No models installed yet. Pull one below.").foregroundStyle(.secondary)
                    }
                    ForEach(model.models) { info in
                        installedRow(info)
                    }
                }

                Section("Install a model") {
                    HStack {
                        TextField("Model name, e.g. qwen2.5-coder:7b (several names for Try & remove)", text: $pullName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { pull() }
                        Button("Pull") { pull() }
                            .disabled(pullName.trimmingCharacters(in: .whitespaces).isEmpty || model.isPulling || !model.status.isConnected)
                        if model.isTrialRunning {
                            Button("Add to trial") { tryModels() }
                                .help("Queue these models after the ones already being tried.")
                                .disabled(pullName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Cancel trial") { model.cancelTrial() }
                        } else {
                            Button("Try & remove") { tryModels() }
                                .help("Pull each model listed (separate names with spaces or commas), benchmark it, then delete it again, one after the other. Models already installed are benchmarked and kept. The results stay in the Benchmarks section below.")
                                .disabled(pullName.trimmingCharacters(in: .whitespaces).isEmpty || model.isPulling || model.isBenchmarking || !model.status.isConnected)
                        }
                    }
                    if model.isTrialRunning, let current = model.trialQueue.first {
                        let left = model.trialQueue.count - 1
                        Label("\(model.trialStep) \(current)" + (left > 0 ? " · \(left) more to try" : " · last one"), systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout)
                    }
                    ForEach(model.trialFailures, id: \.self) { failure in
                        Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    }
                    if !model.trialSkipped.isEmpty {
                        Text("Skipped, already benchmarked: \(model.trialSkipped.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.leftoverBytes > 100_000_000 {
                        HStack {
                            Label("\(ByteCountFormatter.string(fromByteCount: model.leftoverBytes, countStyle: .file)) of leftover downloads in Ollama's store", systemImage: "externaldrive.badge.exclamationmark")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") { model.removeLeftovers() }
                                .help("Deletes data from failed or cancelled downloads that no installed model uses. Ollama never removes it on its own.")
                                .disabled(model.isPulling)
                        }
                    }
                    if model.isPulling {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Pulling \(model.pullingName)").font(.callout)
                                Spacer()
                                if let f = model.pullProgress?.fraction { Text("\(Int(f * 100))%").font(.caption).foregroundStyle(.secondary) }
                                Button("Cancel") { model.cancelPull() }.controlSize(.small)
                            }
                            if let f = model.pullProgress?.fraction {
                                ProgressView(value: f)
                            } else {
                                ProgressView()
                            }
                            Text(progressDetail).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    if let err = model.pullError {
                        Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    }
                    Link("Browse the Ollama library", destination: URL(string: "https://ollama.com/library")!)
                        .font(.callout)
                }

                Section("Suggested") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(suggested, id: \.name) { s in
                            let installed = model.models.contains { $0.name == s.name }
                            Button {
                                pullName = s.name
                                if !installed { pull() }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(s.name).font(.callout.weight(.medium))
                                        if installed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
                                    }
                                    Text(s.note).font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isPulling || installed)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Benchmarks") {
                    BenchmarksSection()
                }

                if !model.runningModels.isEmpty {
                    Section("Loaded in memory") {
                        ForEach(model.runningModels) { r in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name).font(.body.weight(.medium))
                                    Text(loadedDetail(r)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let v = r.sizeVram {
                                    Text(ByteCountFormatter.string(fromByteCount: v, countStyle: .memory)).font(.callout).monospacedDigit()
                                }
                                Button("Unload") { Task { await model.unloadModel(r.name) } }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 780, height: 640)
        .confirmationDialog("Delete \(modelToDelete?.name ?? "")?", isPresented: Binding(get: { modelToDelete != nil }, set: { if !$0 { modelToDelete = nil } }), presenting: modelToDelete) { info in
            Button("Delete \(info.sizeDescription)", role: .destructive) {
                Task { await model.deleteModel(info.name) }
                modelToDelete = nil
            }
            Button("Cancel", role: .cancel) { modelToDelete = nil }
        } message: { info in
            Text("This removes the model files from disk. You can pull it again later.")
        }
        .task { model.refreshLeftovers(); await model.refreshModels(); await model.loadAllStats() }
    }

    private func installedRow(_ info: OllamaModelInfo) -> some View {
        ModelRow(info: info, isExpanded: expanded.contains(info.name)) {
            if expanded.contains(info.name) { expanded.remove(info.name) } else { expanded.insert(info.name) }
        } onUse: {
            model.setModel(info.name)
        } onDelete: {
            modelToDelete = info
        }
    }

    private var headerSummary: String {
        if model.isTrialRunning, let current = model.trialQueue.first {
            let left = model.trialQueue.count - 1
            return "Trying \(current)" + (left > 0 ? " (\(left) more queued)" : "") + " — " + (model.benchmarkingModel == current ? model.benchmarkStep : model.trialStep.lowercased())
        }
        if let name = model.benchmarkingModel {
            let left = model.benchmarkQueue.count
            return "Benchmarking \(name)" + (left > 0 ? " (\(left) more queued)" : "") + " — \(model.benchmarkStep)"
        }
        var parts = ["\(model.models.count) installed · \(ByteCountFormatter.string(fromByteCount: model.totalModelBytes, countStyle: .file)) on disk"]
        let vram = model.runningModels.reduce(Int64(0)) { $0 + ($1.sizeVram ?? 0) }
        if vram > 0 { parts.append("\(ByteCountFormatter.string(fromByteCount: vram, countStyle: .memory)) loaded in memory") }
        return parts.joined(separator: " · ")
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func loadedDetail(_ r: RunningModel) -> String {
        var parts: [String] = []
        if let c = r.contextLength { parts.append("context \(c / 1024)k") }
        if let runner = ModelBenchmark.displayName(forRunner: r.runner) { parts.append(runner) }
        if let total = r.size, let vram = r.sizeVram, total > 0 {
            let pct = Int(Double(vram) / Double(total) * 100)
            parts.append(pct >= 100 ? "100% on GPU" : "\(pct)% on GPU, rest on CPU")
        }
        if let e = r.expiresAt, let d = ISO8601DateFormatter.flexible.date(from: e) {
            parts.append("unloads " + RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    private var progressDetail: String {
        guard let p = model.pullProgress else { return "Starting…" }
        if let total = p.total, let completed = p.completed {
            return "\(p.status) — \(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        }
        return p.status
    }

    private func pull() {
        let name = pullName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.pullModel(name)
        pullName = ""
    }

    private func tryModels() {
        let names = pullName.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
        guard !names.isEmpty else { return }
        model.tryModels(names)
        pullName = ""
    }
}


extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let info: OllamaModelInfo
    let isExpanded: Bool
    let onToggle: () -> Void
    let onUse: () -> Void
    let onDelete: () -> Void

    private var stats: ModelStats? { model.modelStats[info.name] }
    private var running: RunningModel? { model.runningModels.first { $0.name == info.name } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                        Text(info.name).font(.body.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                badges
                Spacer()
                if model.benchmarkingModel == info.name {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.benchmark(info.name) } label: { Image(systemName: "gauge.with.dots.needle.67percent") }
                        .help(bench == nil ? "Benchmark this model on this Mac (about a minute)" : "Run the benchmark again")
                        .disabled(model.isBenchmarking || model.isAnyGenerating || model.isPulling || !model.status.isConnected)
                }
                Button(action: onUse) { Image(systemName: info.name == model.currentModelName ? "checkmark.circle.fill" : "checkmark.circle") }
                    .help("Use this model for the current chat")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .help("Delete model")
            }
            .buttonStyle(.borderless)

            HStack(spacing: 8) {
                StatTile(label: "On disk", value: info.sizeDescription)
                StatTile(label: "Parameters", value: paramText)
                StatTile(label: "Quantization", value: info.details?.quantizationLevel ?? stats?.fileType ?? "–")
                StatTile(label: "Context", value: contextText)
                StatTile(label: memoryFigure.label, value: memoryFigure.value, help: memoryFigure.help)
            }
            .padding(.leading, 16)

            benchmarkLine.padding(.leading, 16)

            if isExpanded { details.padding(.leading, 16) }
        }
        .padding(.vertical, 4)
        .task(id: info.name) { await model.loadStats(for: info.name) }
    }

    @ViewBuilder
    private var badges: some View {
        if info.supportsTools == true { badge("tools", .accentColor) }
        if info.supportsVision { badge("vision", .purple) }
        if info.supportsThinking { badge("thinking", .teal) }
        if let r = running { badge(["loaded", ModelBenchmark.displayName(forRunner: r.runner)].compactMap { $0 }.joined(separator: " · "), .green) }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var bench: ModelBenchmark? { model.benchmarks[info.name] }

    /// Measured memory when Ollama has the model loaded, else the last benchmark's figure at
    /// the current context, else an estimate from the file size plus a full KV cache.
    private var memoryFigure: (label: String, value: String, help: String) {
        let ctxK = model.settings.contextLength / 1024
        if let r = running, let bytes = r.sizeVram ?? r.size {
            return ("Memory", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory),
                    "Measured: what Ollama has allocated for this model right now" + (r.contextLength.map { " (context \($0 / 1024)k)" } ?? "") + ".")
        }
        if let b = bench, let bytes = b.memoryBytes, b.contextLength == model.settings.contextLength {
            return ("Memory", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory),
                    "Measured during the benchmark on \(b.date.formatted(date: .abbreviated, time: .omitted)) at \(ctxK)k context.")
        }
        guard let size = info.size else { return ("Memory", "–", "") }
        let ctx = min(model.settings.contextLength, info.details?.contextLength ?? stats?.contextLength ?? Int.max)
        let kv = stats?.kvCacheBytes(context: ctx) ?? 0
        return ("Est. memory", "~" + ByteCountFormatter.string(fromByteCount: size + kv, countStyle: .memory),
                "Estimate at your context setting (\(ctxK)k): weights plus a full KV cache. Hybrid models such as Qwen3.5 or Gemma 4 need far less KV cache than this; run the benchmark for the measured figure.")
    }

    @ViewBuilder
    private var benchmarkLine: some View {
        if model.benchmarkingModel == info.name {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(model.benchmarkStep).font(.caption).foregroundStyle(.secondary)
            }
        } else if let b = bench {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    StatTile(label: "Load", value: String(format: "%.1f s", b.loadSeconds), help: "Time to load the weights from disk into memory. Paid again whenever Ollama unloads the model (5 minutes idle by default) or you switch models.")
                    StatTile(label: "Prompt", value: "\(Int(b.promptTokensPerSecond.rounded())) tok/s", help: "Prompt processing speed on a 1,500-token prompt. This is the wait before the first word on long chats and big tool results.")
                    StatTile(label: "Generate", value: String(format: "%.1f tok/s", b.generationTokensPerSecond), help: "Generation speed with thinking off, over \(ModelBenchmark.generationTokens) tokens.")
                    if b.thinkingTokens != nil {
                        StatTile(label: "Thinking", value: thinkingText(b), help: "With thinking on, tokens the model produced on a one-sentence question (reasoning plus reply) and the time until it answered. Capped at \(ModelBenchmark.thinkingTokenCap) tokens.")
                    }
                    if let r = b.runnerDisplayName {
                        StatTile(label: "Runner", value: r, help: "Engine Ollama used: llama.cpp for GGUF files, MLX for MLX-format models, which is roughly twice as fast on Apple Silicon.")
                    }
                }
                Text(benchmarkCaption(b)).font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Text("Not benchmarked on this Mac yet.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func thinkingText(_ b: ModelBenchmark) -> String {
        guard let tokens = b.thinkingTokens else { return "–" }
        let secs = b.thinkingSeconds.map { String(format: "%.0f s", $0) } ?? ""
        return b.thinkingAnswered == true ? "\(tokens) tok · \(secs)" : "no answer in \(tokens) tok"
    }

    private func benchmarkCaption(_ b: ModelBenchmark) -> String {
        var parts = ["Benchmarked \(b.date.formatted(date: .abbreviated, time: .shortened)) at \(b.contextLength / 1024)k context"]
        if let v = b.ollamaVersion { parts.append("Ollama \(v)") }
        if let gpu = b.fullyOnGPU { parts.append(gpu ? "all on GPU" : "partly on CPU") }
        if let d = b.digest, let cur = info.digest, d != cur { parts.append("model file changed since") }
        return parts.joined(separator: " · ")
    }

    private var paramText: String {
        if let n = stats?.parameterCount {
            return n >= 1_000_000_000 ? String(format: "%.1fB", Double(n) / 1e9) : String(format: "%.0fM", Double(n) / 1e6)
        }
        return info.details?.parameterSize ?? "–"
    }

    private var contextText: String {
        let c = info.details?.contextLength ?? stats?.contextLength
        guard let c else { return "–" }
        return c >= 1024 ? "\(c / 1024)k tokens" : "\(c) tokens"
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let s = stats {
                detailRow("Architecture", [s.architecture, s.layers.map { "\($0) layers" },
                                           s.heads.map { h in "\(h) heads" + (s.kvHeads.map { $0 != h ? " (\($0) KV)" : "" } ?? "") },
                                           s.embeddingLength.map { "embedding \($0)" },
                                           s.feedForwardLength.map { "FFN \($0)" }].compactMap { $0 }.joined(separator: " · "))
                if let n = s.parameterCount { detailRow("Exact parameters", n.formatted()) }
                if let kv = s.kvCacheBytes(context: 1) {
                    detailRow("KV cache", "\(ByteCountFormatter.string(fromByteCount: kv, countStyle: .memory)) per token · \(ByteCountFormatter.string(fromByteCount: kv * Int64(model.settings.contextLength), countStyle: .memory)) at \(model.settings.contextLength / 1024)k")
                }
                let base = [s.organization, s.baseModel].compactMap { $0 }.joined(separator: " / ")
                if !base.isEmpty { detailRow("Base model", base) }
                if let l = s.license { detailRow("License", l) }
                if let langs = s.languages, !langs.isEmpty { detailRow("Languages", langs.joined(separator: ", ")) }
                detailRow("Capabilities", s.capabilities.isEmpty ? "–" : s.capabilities.joined(separator: ", "))
                if s.hasSystemPrompt { detailRow("System prompt", "Built into the model") }
            } else if model.loadingStats.contains(info.name) {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Loading details…").font(.caption).foregroundStyle(.secondary) }
            }
            if let fam = info.details?.families, fam.count > 1 { detailRow("Families", fam.joined(separator: ", ")) }
            if let f = info.details?.format { detailRow("Format", f.uppercased()) }
            if let d = info.modifiedDate { detailRow("Modified", d.formatted(date: .abbreviated, time: .shortened)) }
            if let digest = info.digest { detailRow("Digest", String(digest.prefix(12))) }
            if let r = running {
                detailRow("Loaded", [r.sizeVram.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) + " in memory" },
                                     r.contextLength.map { "context \($0 / 1024)k" },
                                     ModelBenchmark.displayName(forRunner: r.runner).map { "runner \($0)" }].compactMap { $0 }.joined(separator: " · "))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(minWidth: 90, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .help(help ?? "")
    }
}

/// Every model benchmarked on this Mac: one row per model with its latest run, older runs on
/// request. Sorted by the measured speeds and filtered by capability.
struct BenchmarksSection: View {
    @Environment(AppModel.self) private var model
    @State private var sortKey: SortKey = .generation
    @State private var required: Set<Capability> = []
    @State private var expanded: Set<String> = []

    enum SortKey: String, CaseIterable {
        case generation = "Generate", prompt = "Prompt", thinking = "Thinking", load = "Load", newest = "Newest"
    }

    enum Capability: String, CaseIterable { case tools, thinking, vision }

    private struct Entry: Identifiable {
        var latest: ModelBenchmark
        /// Earlier runs, newest first.
        var older: [ModelBenchmark]
        var info: OllamaModelInfo?
        var id: String { latest.model }
    }

    // Column widths; the first column takes what is left.
    private static let widths: [CGFloat] = [46, 66, 74, 96, 62, 58]

    var body: some View {
        if model.benchmarkHistory.isEmpty {
            Text("No benchmarks yet. Use the gauge button on a model, or “Benchmark all”.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            controls
            if entries.isEmpty {
                Text("No benchmarked model has all the selected capabilities.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    header
                    Divider()
                    ForEach(entries) { entry in
                        row(entry.latest, entry: entry, isLatest: true)
                        if expanded.contains(entry.id) {
                            ForEach(entry.older) { run in row(run, entry: entry, isLatest: false) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Data

    private var entries: [Entry] {
        var runs: [String: [ModelBenchmark]] = [:]
        var order: [String] = []
        for run in model.benchmarkHistory {
            if runs[run.model] == nil { order.append(run.model) }
            runs[run.model, default: []].append(run)
        }
        return order
            .map { name in Entry(latest: runs[name]![0], older: Array(runs[name]!.dropFirst()), info: model.modelInfo(name)) }
            .filter { entry in required.allSatisfy { has($0, entry) } }
            .sorted(by: ordered)
    }

    private func has(_ capability: Capability, _ entry: Entry) -> Bool {
        let caps = Set(entry.info?.capabilities ?? entry.latest.capabilities ?? [])
        switch capability {
        case .tools: return caps.contains("tools")
        case .thinking: return caps.contains("thinking") || entry.latest.thinkingTokens != nil
        case .vision: return caps.contains("vision")
        }
    }

    private func ordered(_ a: Entry, _ b: Entry) -> Bool {
        switch sortKey {
        case .generation: return a.latest.generationTokensPerSecond > b.latest.generationTokensPerSecond
        case .prompt: return a.latest.promptTokensPerSecond > b.latest.promptTokensPerSecond
        case .load: return a.latest.loadSeconds < b.latest.loadSeconds
        case .newest: return a.latest.date > b.latest.date
        case .thinking: return thinkingKey(a.latest) < thinkingKey(b.latest)
        }
    }

    /// Seconds until the thinking test answered; models that never answered come after
    /// those that did, and models without a thinking test last.
    private func thinkingKey(_ run: ModelBenchmark) -> Double {
        guard run.thinkingTokens != nil else { return .infinity }
        guard run.thinkingAnswered == true, let seconds = run.thinkingSeconds else { return .greatestFiniteMagnitude }
        return seconds
    }

    // MARK: - Rows

    private var controls: some View {
        HStack(spacing: 8) {
            Text("Only").font(.caption).foregroundStyle(.secondary)
            ForEach(Capability.allCases, id: \.self) { capability in
                Toggle(capability.rawValue, isOn: Binding(
                    get: { required.contains(capability) },
                    set: { if $0 { required.insert(capability) } else { required.remove(capability) } }))
                    .toggleStyle(.button)
                    .help("Only models that support \(capability.rawValue)")
            }
            Spacer()
            Picker("Sort by", selection: $sortKey) {
                ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            .help("Generate and Prompt: fastest first. Thinking: quickest to answer with thinking on first. Load: shortest load first.")
        }
        .controlSize(.small)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Model").frame(maxWidth: .infinity, alignment: .leading)
            Text("Load").frame(width: Self.widths[0], alignment: .trailing)
            Text("Prompt").frame(width: Self.widths[1], alignment: .trailing)
            Text("Generate").frame(width: Self.widths[2], alignment: .trailing)
            Text("Thinking").frame(width: Self.widths[3], alignment: .trailing)
            Text("Memory").frame(width: Self.widths[4], alignment: .trailing)
            Text("Run").frame(width: Self.widths[5], alignment: .trailing)
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func row(_ run: ModelBenchmark, entry: Entry, isLatest: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                if isLatest {
                    Button {
                        if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                    } label: {
                        Image(systemName: expanded.contains(entry.id) ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                    }
                    .buttonStyle(.plain)
                    .opacity(entry.older.isEmpty ? 0 : 1)
                    .disabled(entry.older.isEmpty)
                    .accessibilityLabel("Earlier runs")
                    .help(entry.older.isEmpty ? "" : "\(entry.older.count) earlier run\(entry.older.count == 1 ? "" : "s")")
                    ModelNameCell(name: run.model, installed: entry.info != nil)
                    if let d = run.digest, let current = entry.info?.digest, d != current {
                        Text("file changed since").font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Text("earlier run").font(.caption).foregroundStyle(.tertiary).padding(.leading, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(String(format: "%.1f s", run.loadSeconds), 0)
            cell("\(Int(run.promptTokensPerSecond.rounded())) tok/s", 1)
            cell(String(format: "%.1f tok/s", run.generationTokensPerSecond), 2)
            cell(thinkingText(run), 3)
            cell(run.memoryBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "–", 4)
            cell(run.date.formatted(.dateTime.day().month(.abbreviated)), 5)
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(isLatest ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .help(caption(run))
        .contextMenu {
            Button("Copy Model Name") { ModelNameCell.copy(run.model) }
            if entry.info != nil {
                Button("Benchmark again") { model.benchmark(run.model) }
                    .disabled(model.isBenchmarking || model.isAnyGenerating || model.isPulling || !model.status.isConnected)
            }
            Button("Delete this run", role: .destructive) { model.deleteBenchmark(run.id) }
            if !entry.older.isEmpty {
                Button("Delete all \(entry.older.count + 1) runs for this model", role: .destructive) { model.deleteBenchmarks(for: run.model) }
            }
        }
    }

    private func cell(_ text: String, _ column: Int) -> some View {
        Text(text).lineLimit(1).frame(width: Self.widths[column], alignment: .trailing)
    }

    private func thinkingText(_ run: ModelBenchmark) -> String {
        guard let tokens = run.thinkingTokens else { return "–" }
        let seconds = run.thinkingSeconds.map { String(format: "%.0f s", $0) } ?? ""
        return run.thinkingAnswered == true ? "\(tokens) tok · \(seconds)" : "no answer, \(tokens) tok"
    }

    private func caption(_ run: ModelBenchmark) -> String {
        var parts = ["Benchmarked \(run.date.formatted(date: .abbreviated, time: .shortened)) at \(run.contextLength / 1024)k context"]
        if let v = run.ollamaVersion { parts.append("Ollama \(v)") }
        if let r = run.runnerDisplayName { parts.append(r) }
        if let gpu = run.fullyOnGPU { parts.append(gpu ? "all on GPU" : "partly on CPU") }
        parts.append("Right-click to benchmark again or delete")
        return parts.joined(separator: " · ")
    }
}


/// The model name in a benchmark row, with a copy button that appears on hover. A model
/// that is no longer installed is set lighter.
private struct ModelNameCell: View {
    let name: String
    var installed = true
    @State private var hovering = false
    @State private var copied = false

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var body: some View {
        HStack(spacing: 2) {
            // Truncated at the start: the namespace matters less than the model and its tag.
            Text(name)
                .font(.callout.weight(installed ? .medium : .regular))
                .foregroundStyle(installed ? .primary : .secondary)
                .lineLimit(1).truncationMode(.head)
                .help(installed ? name : name + " (not installed)")
            Button {
                Self.copy(name)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption2)
            }
            .buttonStyle(.hoverPress)
            .opacity(hovering || copied ? 1 : 0)
            .help("Copy the model name")
        }
        .onHover { hovering = $0 }
    }
}
