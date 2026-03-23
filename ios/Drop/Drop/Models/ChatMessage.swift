import Foundation

/// A single chat message exchanged with a peer.
struct ChatMessage: Identifiable, Sendable {
    let id: UUID
    let conversationID: UUID
    let text: String
    let timestamp: Date
    let isOutgoing: Bool
    let isDelivered: Bool

    static func placeholders(for conversationID: UUID) -> [ChatMessage] {
        [
            ChatMessage(
                id: UUID(),
                conversationID: conversationID,
                text: "Hey! Are you nearby?",
                timestamp: Date().addingTimeInterval(-300),
                isOutgoing: true,
                isDelivered: true
            ),
            ChatMessage(
                id: UUID(),
                conversationID: conversationID,
                text: "Yeah, just got here. Syncing now…",
                timestamp: Date().addingTimeInterval(-240),
                isOutgoing: false,
                isDelivered: true
            ),
            ChatMessage(
                id: UUID(),
                conversationID: conversationID,
                text: "Got your message!",
                timestamp: Date().addingTimeInterval(-120),
                isOutgoing: false,
                isDelivered: true
            ),
        ]
    }
}
