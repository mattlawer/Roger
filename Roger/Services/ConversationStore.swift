import Foundation

/// Persists conversations as individual JSON files in Application Support.
final class ConversationStore {
    let directory: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base.appendingPathComponent("Roger/Conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private var groupsURL: URL { directory.deletingLastPathComponent().appendingPathComponent("groups.json") }

    func loadGroups() -> [ChatGroup] {
        guard let data = try? Data(contentsOf: groupsURL) else { return [] }
        return (try? decoder.decode([ChatGroup].self, from: data)) ?? []
    }

    func saveGroups(_ groups: [ChatGroup]) {
        guard let data = try? encoder.encode(groups) else { return }
        try? data.write(to: groupsURL, options: .atomic)
    }

    func loadAll() -> [Conversation] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Conversation.self, from: data)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ conversation: Conversation) {
        var c = conversation
        for i in c.messages.indices { c.messages[i].isStreaming = false }
        guard let data = try? encoder.encode(c) else { return }
        try? data.write(to: url(for: c.id), options: .atomic)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
