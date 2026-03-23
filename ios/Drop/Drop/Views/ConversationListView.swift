import SwiftUI

struct ConversationListView: View {
    @Environment(DropRepository.self) private var repository

    var body: some View {
        List(repository.conversations) { conversation in
            NavigationLink(value: conversation.id) {
                ConversationRow(conversation: conversation)
            }
        }
        .navigationTitle("Drop")
        .navigationDestination(for: UUID.self) { conversationID in
            ChatView(conversationID: conversationID)
        }
        .overlay {
            if repository.conversations.isEmpty {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Move closer to another Drop user to exchange messages")
                )
            }
        }
    }
}

// MARK: - Row

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.peerName)
                    .font(.headline)
                Text(conversation.lastMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(conversation.lastMessageDate, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if conversation.unreadCount > 0 {
                    Text("\(conversation.unreadCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        ConversationListView()
            .environment(DropRepository())
    }
}
