import Foundation

enum Role: String, Codable {
    case user
    case assistant
}

final class ChatMessage: Codable {
    let id: String
    let role: Role
    var text: String
    /// Summarized thinking shown above the answer; never sent back to the API.
    var thinking: String
    /// Error or refusal note; a message with `excluded == true` is not sent back to the API.
    var note: String?
    var excluded: Bool
    var model: String?

    init(role: Role, text: String) {
        self.id = UUID().uuidString
        self.role = role
        self.text = text
        self.thinking = ""
        self.note = nil
        self.excluded = false
        self.model = nil
    }
}

final class Conversation: Codable {
    let id: String
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date

    init() {
        id = UUID().uuidString
        title = "新对话"
        messages = []
        updatedAt = Date()
    }

    /// Builds the `messages` array for the API: text-only, roles strictly alternating,
    /// starting with a user turn.
    func apiMessages() -> [[String: Any]] {
        var merged: [(Role, String)] = []
        for message in messages where !message.excluded {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if let last = merged.last, last.0 == message.role {
                merged[merged.count - 1].1 = last.1 + "\n\n" + text
            } else {
                merged.append((message.role, text))
            }
        }
        while let first = merged.first, first.0 != .user {
            merged.removeFirst()
        }
        return merged.map { ["role": $0.0.rawValue, "content": $0.1] }
    }
}

final class ConversationStore {
    static let shared = ConversationStore()

    private(set) var conversations: [Conversation] = []
    private let fileURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("conversations.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        conversations = (try? decoder.decode([Conversation].self, from: data)) ?? []
        sort()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(conversations) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func add(_ conversation: Conversation) {
        conversations.insert(conversation, at: 0)
        save()
    }

    func touch(_ conversation: Conversation) {
        conversation.updatedAt = Date()
        if !conversations.contains(where: { $0 === conversation }) {
            conversations.insert(conversation, at: 0)
        }
        sort()
        save()
    }

    func delete(_ conversation: Conversation) {
        conversations.removeAll { $0 === conversation }
        save()
    }

    private func sort() {
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }
}
