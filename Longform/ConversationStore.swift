import Foundation
import SwiftData

@Model
final class StoredConversation {
    var started: Date = Date()
    var updated: Date = Date()
    @Relationship(deleteRule: .cascade) var entries: [StoredMessage] = []

    init(started: Date = .now) {
        self.started = started
        self.updated = started
    }

    /// First thing you said, which is a better handle than a timestamp.
    var title: String {
        let opener = entries.sorted { $0.position < $1.position }
            .first { $0.role == Role.user.rawValue }?.text ?? "Empty conversation"
        return opener.count > 60 ? String(opener.prefix(60)) + "…" : opener
    }

    var messages: [Message] {
        entries.sorted { $0.position < $1.position }
            .compactMap { entry in
                Role(rawValue: entry.role).map { Message(role: $0, text: entry.text) }
            }
    }
}

@Model
final class StoredMessage {
    var role: String = ""
    var text: String = ""
    var position: Int = 0

    init(role: Role, text: String, position: Int) {
        self.role = role.rawValue
        self.text = text
        self.position = position
    }
}

/// Saves conversations so they survive relaunch and can be picked back up.
@MainActor @Observable
final class ConversationStore {
    private var container: ModelContainer?
    private var current: StoredConversation?

    init() {
        do {
            container = try ModelContainer(for: StoredConversation.self, StoredMessage.self)
        } catch {
            Log.api.error("conversation store unavailable: \(error.localizedDescription)")
        }
    }

    func history() -> [StoredConversation] {
        guard let context = container?.mainContext else { return [] }
        let descriptor = FetchDescriptor<StoredConversation>(sortBy: [SortDescriptor(\.updated, order: .reverse)])
        return ((try? context.fetch(descriptor)) ?? []).filter { !$0.entries.isEmpty }
    }

    /// Mirrors the live transcript into the store after every turn.
    func save(_ messages: [Message]) {
        guard let context = container?.mainContext, !messages.isEmpty else { return }

        let conversation = current ?? {
            let fresh = StoredConversation()
            context.insert(fresh)
            current = fresh
            return fresh
        }()

        conversation.entries = messages.enumerated().map { StoredMessage(role: $1.role, text: $1.text, position: $0) }
        conversation.updated = .now
        try? context.save()
    }

    /// Reopens a past conversation; the caller feeds its messages back to the model so the
    /// API sees the same history it had before.
    func resume(_ conversation: StoredConversation) -> [Message] {
        current = conversation
        return conversation.messages
    }

    func startNew() {
        current = nil
    }

    func delete(_ conversation: StoredConversation) {
        guard let context = container?.mainContext else { return }
        if current === conversation { current = nil }
        context.delete(conversation)
        try? context.save()
    }
}
