import Foundation

/// A conversation with a single peer, identified by their device/peer ID.
struct Conversation: Identifiable, Sendable {
    let id: UUID
    let peerName: String
    var lastMessage: String
    var lastMessageDate: Date
    var unreadCount: Int

    static let placeholder: [Conversation] = [
        Conversation(
            id: UUID(),
            peerName: "Alice's iPhone",
            lastMessage: "Hey, got your message!",
            lastMessageDate: Date().addingTimeInterval(-120),
            unreadCount: 1
        ),
        Conversation(
            id: UUID(),
            peerName: "Bob's iPad",
            lastMessage: "See you at the park",
            lastMessageDate: Date().addingTimeInterval(-3600),
            unreadCount: 0
        ),
    ]
}
