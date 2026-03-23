import Foundation
import Observation

/// Bridges the Rust `drop-core` library (via UniFFI) to the iOS app.
/// All protocol logic — identity, message encoding, Bloom filters — lives in Rust.
/// This class exposes a Swift-friendly API and holds observable state for the UI.
@Observable
final class DropRepository: @unchecked Sendable {

    // MARK: - Published State

    var conversations: [Conversation] = Conversation.placeholder
    var currentMessages: [ChatMessage] = []

    // MARK: - Identity

    /// Returns this device's persistent peer identity.
    func getIdentity() -> Data {
        // TODO: Wire UniFFI bindings — call drop_core::get_identity()
        return Data(UUID().uuidString.utf8)
    }

    // MARK: - Bloom Filter

    /// Builds a Bloom filter representing the set of peer IDs this device has
    /// pending messages for. Advertised in BLE service data so remote peers
    /// can quickly decide whether a connection is worthwhile.
    func buildBloomFilter() -> Data {
        // TODO: Wire UniFFI bindings — call drop_core::build_bloom_filter()
        return Data()
    }

    /// Checks whether a remote Bloom filter indicates the peer may have
    /// messages for us.
    func checkBloomFilter(remoteFilter: Data?) -> Bool {
        // TODO: Wire UniFFI bindings — call drop_core::check_bloom_filter()
        return true
    }

    // MARK: - Handshake

    func buildHandshake(peerId: UUID) -> Data {
        // TODO: Wire UniFFI bindings — call drop_core::build_handshake()
        return Data()
    }

    func processHandshake(_ data: Data, from peerId: UUID) {
        // TODO: Wire UniFFI bindings — call drop_core::process_handshake()
    }

    // MARK: - Messages

    func getPendingMessages(peerId: UUID) -> [Data] {
        // TODO: Wire UniFFI bindings — call drop_core::get_pending_messages()
        return []
    }

    func storeIncomingMessage(_ data: Data, from peerId: UUID) {
        // TODO: Wire UniFFI bindings — call drop_core::store_message()
    }

    func markDelivered(messageIds: [Data]) {
        // TODO: Wire UniFFI bindings — call drop_core::mark_delivered()
    }

    // MARK: - UI Helpers

    func loadConversations() {
        // TODO: Wire UniFFI bindings — fetch conversation list from Rust core
        conversations = Conversation.placeholder
    }

    func loadMessages(for conversationID: UUID) {
        // TODO: Wire UniFFI bindings — fetch messages from Rust core
        currentMessages = ChatMessage.placeholders(for: conversationID)
    }

    func sendMessage(_ text: String, to conversationID: UUID) {
        // TODO: Wire UniFFI bindings — encode and queue message via Rust core
        let message = ChatMessage(
            id: UUID(),
            conversationID: conversationID,
            text: text,
            timestamp: Date(),
            isOutgoing: true,
            isDelivered: false
        )
        currentMessages.append(message)
    }
}
