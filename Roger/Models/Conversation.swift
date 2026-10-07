import Foundation

/// A user-defined folder in the sidebar.
struct ChatGroup: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
}

struct Conversation: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String = "New chat"
    var model: String?
    var workingDirectory: String = NSHomeDirectory()
    var messages: [ChatMessage] = []
    var createdAt = Date()
    var updatedAt = Date()
    /// Sidebar group, or nil for the top-level list.
    var groupID: UUID?
    /// The user renamed this chat; automatic naming must leave it alone.
    var titleIsCustom = false
    /// A model-generated name has been applied (or attempted) once.
    var titleGenerated = false
}

extension Conversation {
    /// Tolerant decoding so chats saved by older versions keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "New chat"
        model = try c.decodeIfPresent(String.self, forKey: .model)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? NSHomeDirectory()
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        titleIsCustom = try c.decodeIfPresent(Bool.self, forKey: .titleIsCustom) ?? false
        titleGenerated = try c.decodeIfPresent(Bool.self, forKey: .titleGenerated) ?? false
    }
}
