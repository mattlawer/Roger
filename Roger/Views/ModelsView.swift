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
                    if model.models.isEmpty {
                        Text("No models installed yet. Pull one below.").foregroundStyle(.secondary)
                    }
                    ForEach(model.models) { info in
                        installedRow(info)
                    }
                }

                Section("Install a model") {
                    HStack {
                        TextField("Model name, e.g. qwen2.5-coder:7b", text: $pullName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { pull() }
                        Button("Pull") { pull() }
                            .disabled(pullName.trimmingCharacters(in: .whitespaces).isEmpty || model.isPulling || !model.status.isConnected)
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
        .frame(width: 680, height: 620)
        .confirmationDialog("Delete \(modelToDelete?.name ?? "")?", isPresented: Binding(get: { modelToDelete != nil }, set: { if !$0 { modelToDelete = nil } }), presenting: modelToDelete) { info in
            Button("Delete \(info.sizeDescription)", role: .destructive) {
                Task { await model.deleteModel(info.name) }
                modelToDelete = nil
            }
            Button("Cancel", role: .cancel) { modelToDelete = nil }
        } message: { info in
            Text("This removes the model files from disk. You can pull it again later.")
        }
        .task { await model.refreshModels(); await model.loadAllStats() }
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
                StatTile(label: "Est. memory", value: memoryText, help: "Approximate memory needed at your context setting (\(model.settings.contextLength / 1024)k): weights plus KV cache.")
            }
            .padding(.leading, 16)

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
        if running != nil { badge("loaded", .green) }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
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

    private var memoryText: String {
        guard let size = info.size else { return "–" }
        let ctx = min(model.settings.contextLength, info.details?.contextLength ?? stats?.contextLength ?? Int.max)
        let kv = stats?.kvCacheBytes(context: ctx) ?? 0
        return "~" + ByteCountFormatter.string(fromByteCount: size + kv, countStyle: .memory)
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
                                     r.contextLength.map { "context \($0 / 1024)k" }].compactMap { $0 }.joined(separator: " · "))
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
