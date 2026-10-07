import Foundation

/// Rough token accounting for a conversation. Ollama exposes no tokenizer endpoint, so
/// Roger estimates about four bytes per token, which is close for English prose and
/// source code with most tokenizers, and keeps headroom for the reply.
enum TokenEstimator {
    static let bytesPerToken = 4
    static let imageTokens = 1024
    static let perMessageOverhead = 4

    static func tokens(forText text: String) -> Int {
        text.isEmpty ? 0 : text.utf8.count / bytesPerToken + 1
    }

    static func tokens(for message: ChatMessage) -> Int {
        var n = perMessageOverhead
        switch message.role {
        case .user:
            n += tokens(forText: message.apiContent)
            n += message.attachments.filter(\.isImage).count * imageTokens
        case .assistant:
            n += tokens(forText: message.content)
            for call in message.toolCalls {
                n += 8 + tokens(forText: call.name)
                n += call.arguments.values.reduce(0) { $0 + tokens(forText: $1.stringValue ?? "") }
            }
        case .tool:
            n += 8 + tokens(forText: message.content)
        case .system:
            n += tokens(forText: message.content)
        }
        return n
    }

    /// Size of the tool definitions sent with every tool-capable request.
    static func toolDefinitionTokens(internet: Bool) -> Int {
        internet ? allToolTokens : baseToolTokens
    }
    private static let baseToolTokens = measure(ToolRegistry.definitions(internet: false))
    private static let allToolTokens = measure(ToolRegistry.definitions(internet: true))
    private static func measure(_ defs: [[String: Any]]) -> Int {
        guard let data = try? JSONSerialization.data(withJSONObject: defs) else { return 600 }
        return data.count / bytesPerToken
    }

    static func format(_ n: Int) -> String {
        if n >= 10_000 { return String(format: "%.0fk", Double(n) / 1000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

/// What Roger will send to the model for the next request, and whether it fits.
struct ContextPlan: Hashable {
    /// Effective context window in tokens (the smaller of the Settings value and the model's maximum).
    var window: Int
    /// Headroom kept free for the model's reply.
    var reserve: Int
    /// System prompt plus tool definitions.
    var fixedTokens: Int
    /// Estimated size of the whole conversation, before any trimming.
    var totalTokens: Int
    /// Estimated size of what will actually be sent.
    var sentTokens: Int
    /// Index into `Conversation.messages` of the first message that is still sent.
    var firstSentIndex: Int
    var autoTrim: Bool

    var limit: Int { max(0, window - reserve) }
    var fraction: Double { window > 0 ? Double(totalTokens) / Double(window) : 0 }
    /// The conversation no longer fits in the window with headroom for a reply.
    var exceedsWindow: Bool { totalTokens > limit }
    /// Even after trimming to the latest turn the request is too long.
    var stillTooLong: Bool { sentTokens > limit }
    var trimmedCount: Int { firstSentIndex }

    static func plan(messages: [ChatMessage], fixedTokens: Int, window: Int, autoTrim: Bool) -> ContextPlan {
        let reserve = min(4096, max(512, window / 8))
        let limit = max(0, window - reserve)
        let perMessage = messages.map(TokenEstimator.tokens(for:))
        let total = fixedTokens + perMessage.reduce(0, +)
        var first = 0
        var sent = total
        if autoTrim && total > limit {
            // A turn starts at each user message. Drop whole turns from the oldest end,
            // but never the latest one: the model always sees the current request.
            let starts = messages.indices.filter { messages[$0].role == .user }
            for start in starts.dropFirst() where sent > limit {
                for i in first..<start { sent -= perMessage[i] }
                first = start
            }
        }
        return ContextPlan(window: window, reserve: reserve, fixedTokens: fixedTokens, totalTokens: total,
                           sentTokens: sent, firstSentIndex: first, autoTrim: autoTrim)
    }
}
