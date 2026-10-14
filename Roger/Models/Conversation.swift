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
    /// Where commands run and relative paths resolve.
    var workingDirectory: String = NSHomeDirectory()
    /// Folders added beside the working directory; the model reaches them by absolute path.
    var extraDirectories: [String] = []
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
    /// Every folder the chat works in, the working directory first.
    var workingDirectories: [String] { [workingDirectory] + extraDirectories }

    mutating func addDirectory(_ path: String) {
        guard !workingDirectories.contains(path) else { return }
        extraDirectories.append(path)
    }

    /// Removing the working directory promotes the next folder; removing the last folder
    /// goes back to the home folder.
    mutating func removeDirectory(_ path: String) {
        if path == workingDirectory {
            workingDirectory = extraDirectories.isEmpty ? NSHomeDirectory() : extraDirectories.removeFirst()
        } else {
            extraDirectories.removeAll { $0 == path }
        }
    }

    mutating func makeMainDirectory(_ path: String) {
        guard extraDirectories.contains(path) else { return }
        extraDirectories.removeAll { $0 == path }
        extraDirectories.insert(workingDirectory, at: 0)
        workingDirectory = path
    }

    /// Tolerant decoding so chats saved by older versions keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "New chat"
        model = try c.decodeIfPresent(String.self, forKey: .model)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? NSHomeDirectory()
        extraDirectories = try c.decodeIfPresent([String].self, forKey: .extraDirectories) ?? []
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        titleIsCustom = try c.decodeIfPresent(Bool.self, forKey: .titleIsCustom) ?? false
        titleGenerated = try c.decodeIfPresent(Bool.self, forKey: .titleGenerated) ?? false
    }
}
