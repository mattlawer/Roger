import Foundation

struct OllamaModelInfo: Codable, Identifiable, Hashable {
    struct Details: Codable, Hashable {
        var parentModel: String?
        var format: String?
        var family: String?
        var families: [String]?
        var parameterSize: String?
        var quantizationLevel: String?
        var contextLength: Int?
        var embeddingLength: Int?
    }

    var id: String { name }
    var name: String
    var model: String?
    var size: Int64?
    var digest: String?
    var modifiedAt: String?
    var details: Details?
    var capabilities: [String]?

    var supportsTools: Bool? { capabilities.map { $0.contains("tools") } }
    var supportsVision: Bool { capabilities?.contains("vision") ?? false }
    var supportsThinking: Bool { capabilities?.contains("thinking") ?? false }

    var sizeDescription: String {
        guard let size else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var modifiedDate: Date? {
        guard let modifiedAt else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: modifiedAt) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: modifiedAt)
    }

    var summary: String {
        var parts: [String] = []
        if let f = details?.family { parts.append(f) }
        if let p = details?.parameterSize { parts.append(p) }
        if let q = details?.quantizationLevel { parts.append(q) }
        if let c = details?.contextLength { parts.append("\(c / 1024)k context") }
        return parts.joined(separator: " · ")
    }
}

struct OllamaTagsResponse: Codable {
    var models: [OllamaModelInfo]
}

struct RunningModel: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var size: Int64?
    var sizeVram: Int64?
    var expiresAt: String?
    var contextLength: Int?
    var details: OllamaModelInfo.Details?
}

/// Response of /api/show, reduced to what Roger displays.
struct OllamaShowResponse: Decodable {
    var license: String?
    var system: String?
    var details: OllamaModelInfo.Details?
    var modelInfo: [String: JSONValue]?
    var capabilities: [String]?
    var modifiedAt: String?
}

/// Derived, display-ready statistics for one model.
struct ModelStats: Hashable {
    var architecture: String?
    var parameterCount: Int64?
    var layers: Int?
    var heads: Int?
    var kvHeads: Int?
    var embeddingLength: Int?
    var contextLength: Int?
    var feedForwardLength: Int?
    var fileType: String?
    var license: String?
    var baseModel: String?
    var organization: String?
    var languages: [String]?
    var capabilities: [String] = []
    var hasSystemPrompt = false

    init(show: OllamaShowResponse) {
        let info = show.modelInfo ?? [:]
        func str(_ k: String) -> String? { info[k]?.stringValue }
        func int(_ k: String) -> Int? { if case .number(let n)? = info[k] { return Int(n) } else { return nil } }
        let arch = str("general.architecture")
        architecture = arch
        if case .number(let n)? = info["general.parameter_count"] { parameterCount = Int64(n) }
        if let arch {
            layers = int("\(arch).block_count")
            heads = int("\(arch).attention.head_count")
            kvHeads = int("\(arch).attention.head_count_kv")
            embeddingLength = int("\(arch).embedding_length")
            contextLength = int("\(arch).context_length")
            feedForwardLength = int("\(arch).feed_forward_length")
        }
        if let ft = int("general.file_type") { fileType = Self.fileTypeName(ft) }
        license = str("general.license") ?? show.license?.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces)
        baseModel = str("general.base_model.0.name") ?? str("general.basename")
        organization = str("general.base_model.0.organization")
        if case .array(let langs)? = info["general.languages"] { languages = langs.compactMap(\.stringValue) }
        capabilities = show.capabilities ?? []
        hasSystemPrompt = !(show.system ?? "").isEmpty
    }

    /// Approximate KV-cache size for a given context length (f16 cache).
    func kvCacheBytes(context: Int) -> Int64? {
        guard let layers, let heads, let embeddingLength, heads > 0 else { return nil }
        let headDim = embeddingLength / heads
        let kv = kvHeads ?? heads
        return Int64(2 * layers * kv * headDim * 2) * Int64(context)
    }

    static func fileTypeName(_ t: Int) -> String {
        let names: [Int: String] = [0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 7: "Q8_0", 8: "Q5_0", 9: "Q5_1", 10: "Q2_K", 11: "Q3_K_S",
                                    12: "Q3_K_M", 13: "Q3_K_L", 14: "Q4_K_S", 15: "Q4_K_M", 16: "Q5_K_S", 17: "Q5_K_M", 18: "Q6_K",
                                    19: "IQ2_XXS", 20: "IQ2_XS", 21: "Q2_K_S", 22: "IQ3_XS", 23: "IQ3_XXS", 24: "IQ1_S", 25: "IQ4_NL",
                                    26: "IQ3_S", 27: "IQ3_M", 28: "IQ2_S", 29: "IQ2_M", 30: "IQ4_XS", 31: "IQ1_M", 32: "BF16"]
        return names[t] ?? "type \(t)"
    }
}

struct OllamaPsResponse: Codable {
    var models: [RunningModel]
}

struct PullProgress: Codable, Hashable {
    var status: String
    var digest: String?
    var total: Int64?
    var completed: Int64?
    var error: String?

    var fraction: Double? {
        guard let total, total > 0, let completed else { return nil }
        return Double(completed) / Double(total)
    }
}

struct ChatChunk: Decodable {
    struct RawToolCall: Decodable {
        struct Function: Decodable {
            var name: String
            var arguments: JSONValue?
            var index: Int?
        }
        var id: String?
        var function: Function
    }
    struct Message: Decodable {
        var role: String?
        var content: String?
        var thinking: String?
        var toolCalls: [RawToolCall]?
    }
    var model: String?
    var message: Message?
    var done: Bool?
    var doneReason: String?
    var evalCount: Int?
    var evalDuration: Int64?
    var promptEvalCount: Int?
    var error: String?
}
