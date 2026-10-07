import Foundation

enum Role: String, Codable {
    case system, user, assistant, tool
}

struct Attachment: Codable, Identifiable, Hashable {
    var id = UUID()
    var fileName: String
    var path: String?
    var text: String?
    var imageBase64: String?

    var isImage: Bool { imageBase64 != nil }
}

enum ToolStatus: String, Codable {
    case pending, denied, running, done, failed
    /// The user stopped generation before this call ran.
    case cancelled
}

struct ToolCall: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var arguments: [String: JSONValue]
    var callID: String?
    var result: String?
    var status: ToolStatus = .pending
    /// Title of the remembered approval that let this call run without asking, if any.
    var approvedBy: String?

    func string(_ key: String) -> String? { arguments[key]?.stringValue }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id = UUID()
    var role: Role
    var content: String
    var thinking: String?
    var attachments: [Attachment] = []
    var toolCalls: [ToolCall] = []
    var toolName: String?
    var toolCallID: String?
    var createdAt = Date()
    var isStreaming = false
    var error: String?
    var stats: String?
    /// Name of the model that produced this reply (assistant messages only).
    var model: String?
    /// Set when the user edited this message and resent it.
    var editedAt: Date?
    /// True when the user stopped generation before the model finished this reply.
    var stopped = false
    /// Token counts reported by Ollama for the request that produced this reply.
    var promptTokens: Int?
    var completionTokens: Int?
    /// The model produced no visible reply and only reasoning; the reasoning is shown as the answer.
    var answeredInReasoning = false

    /// Content as sent to the model, including attached text files.
    var apiContent: String {
        var parts: [String] = []
        if !content.isEmpty { parts.append(content) }
        for a in attachments where a.text != nil {
            let location = a.path.map { " (\($0))" } ?? ""
            parts.append("--- Attached file: \(a.fileName)\(location) ---\n```\n\(a.text!)\n```")
        }
        if parts.isEmpty, attachments.contains(where: \.isImage) {
            parts.append("Please look at the attached image.")
        }
        return parts.joined(separator: "\n\n")
    }

    /// A reply the user cut short that produced nothing visible.
    var isEmptyStoppedReply: Bool {
        stopped && content.isEmpty && toolCalls.isEmpty && (thinking ?? "").isEmpty && error == nil
    }
}

extension ChatMessage {
    /// Tolerant decoding so chats saved by older versions of Roger (without the newer
    /// fields) keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isStreaming = false
        error = try c.decodeIfPresent(String.self, forKey: .error)
        stats = try c.decodeIfPresent(String.self, forKey: .stats)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        editedAt = try c.decodeIfPresent(Date.self, forKey: .editedAt)
        stopped = try c.decodeIfPresent(Bool.self, forKey: .stopped) ?? false
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens)
        answeredInReasoning = try c.decodeIfPresent(Bool.self, forKey: .answeredInReasoning) ?? false
    }
}
