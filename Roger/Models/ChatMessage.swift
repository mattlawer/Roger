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
    /// Not run because it repeated an identical call made earlier in the same turn.
    case skipped
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
    /// True when generation was stopped before the model finished this reply.
    var stopped = false
    /// Why it was stopped, when not by the user (the model repeating itself, for instance).
    var stopReason: String?
    /// Token counts reported by Ollama for the request that produced this reply.
    var promptTokens: Int?
    var completionTokens: Int?
    /// The model produced no visible reply and only reasoning; the reasoning is shown as the answer.
    var answeredInReasoning = false
    /// A remark from Roger on how this reply came about: a retry after a loop, for instance.
    var note: String?

    /// Content as sent to the model, including attached text files. A reply that was
    /// stopped for repeating itself or outgrowing the window, or that never got past its
    /// reasoning, is mostly noise; sent whole, it poisons every later turn (the model
    /// answers a word and gives up), so only its beginning goes back with a note on how it
    /// ended. The context planner counts the same text.
    var apiContent: String {
        if role == .assistant, stopReason != nil || answeredInReasoning, content.count > Self.degenerateReplyLimit {
            let ending = stopReason.map { "reply cut short: \($0)" } ?? "the model stopped without finishing an answer"
            return String(Self.collapsingRepeatedLines(content).prefix(Self.degenerateReplyLimit)) + "\n\n[…\(ending)]"
        }
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

    /// How much of a degenerate reply is sent back to the model, in characters.
    static let degenerateReplyLimit = 4000

    /// Runs of the same line, the shape of a looping model, kept to one copy so they do
    /// not prime the next reply to loop too.
    static func collapsingRepeatedLines(_ text: String) -> String {
        var out: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where line != out.last {
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// A reply the user stopped that has text to continue from and no tool calls.
    var canResume: Bool {
        role == .assistant && stopped && stopReason == nil && !isStreaming && !content.isEmpty && toolCalls.isEmpty
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
        stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens)
        answeredInReasoning = try c.decodeIfPresent(Bool.self, forKey: .answeredInReasoning) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}
