package com.drop.messaging.data

import android.util.Log
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Bridges the Rust drop-core library to Android via UniFFI.
 *
 * All methods in this class are currently placeholder implementations.
 * They will be replaced with actual UniFFI-generated bindings once the
 * Rust core is compiled for Android targets.
 */
class DropRepository {

    companion object {
        private const val TAG = "DropRepository"
    }

    // TODO: Wire UniFFI bindings — initialize the Rust core instance
    // private val core: DropCore = DropCore.create(...)

    // region Identity

    /**
     * Returns this device's identity (public key / device ID).
     */
    fun getIdentity(): ByteArray {
        // TODO: Wire UniFFI bindings — call Rust core for identity
        Log.d(TAG, "getIdentity() — returning placeholder")
        return ByteArray(32) // Placeholder: 32-byte identity
    }

    /**
     * Returns the display name for this device.
     */
    fun getDisplayName(): String {
        // TODO: Wire UniFFI bindings
        return "My Device"
    }

    // endregion

    // region Messages

    data class PeerConversation(
        val peerId: String,
        val peerName: String,
        val lastMessage: String,
        val lastMessageTimestamp: Long,
        val unreadCount: Int
    )

    data class Message(
        val id: String,
        val senderId: String,
        val content: String,
        val timestamp: Long,
        val isOutgoing: Boolean,
        val isDelivered: Boolean
    )

    private val _conversations = MutableStateFlow(placeholderConversations())
    val conversations: Flow<List<PeerConversation>> = _conversations.asStateFlow()

    /**
     * Returns pending message payloads to send to a specific peer.
     */
    fun getPendingMessages(peerId: String): List<ByteArray> {
        // TODO: Wire UniFFI bindings — get pending messages from Rust core
        Log.d(TAG, "getPendingMessages($peerId) — returning empty list")
        return emptyList()
    }

    /**
     * Stores an outbound message to be delivered to a peer.
     */
    fun storeMessage(peerId: String, content: String) {
        // TODO: Wire UniFFI bindings — store message via Rust core
        Log.d(TAG, "storeMessage($peerId, ${content.take(20)}...)")
    }

    /**
     * Returns messages for a specific conversation.
     */
    fun getMessages(peerId: String): Flow<List<Message>> {
        // TODO: Wire UniFFI bindings — get messages from Rust core
        return MutableStateFlow(placeholderMessages(peerId)).asStateFlow()
    }

    // endregion

    // region BLE Protocol

    /**
     * Returns the Bloom filter for advertising, indicating which peer IDs
     * we hold pending messages for.
     */
    fun getBloomFilter(): ByteArray {
        // TODO: Wire UniFFI bindings — get Bloom filter from Rust core
        Log.d(TAG, "getBloomFilter() — returning empty filter")
        return ByteArray(8)
    }

    /**
     * Checks whether an advertised Bloom filter matches our device ID.
     */
    fun checkBloomFilter(filter: ByteArray): Boolean {
        // TODO: Wire UniFFI bindings — check Bloom filter via Rust core
        return true
    }

    /**
     * Returns our handshake payload for the GATT handshake characteristic.
     */
    fun getHandshakePayload(): ByteArray {
        // TODO: Wire UniFFI bindings — build handshake payload via Rust core
        Log.d(TAG, "getHandshakePayload() — returning placeholder")
        return getIdentity()
    }

    /**
     * Processes a handshake payload received from a peer.
     */
    fun handleHandshake(peerId: String, data: ByteArray) {
        // TODO: Wire UniFFI bindings — process handshake via Rust core
        Log.d(TAG, "handleHandshake($peerId, ${data.size} bytes)")
    }

    /**
     * Processes incoming message data received from a peer.
     */
    fun handleIncomingData(peerId: String, data: ByteArray) {
        // TODO: Wire UniFFI bindings — process incoming data via Rust core
        Log.d(TAG, "handleIncomingData($peerId, ${data.size} bytes)")
    }

    /**
     * Processes an ACK received from a peer.
     */
    fun handleAck(peerId: String, data: ByteArray) {
        // TODO: Wire UniFFI bindings — process ACK via Rust core
        Log.d(TAG, "handleAck($peerId, ${data.size} bytes)")
    }

    // endregion

    // region Placeholder Data

    private fun placeholderConversations(): List<PeerConversation> = listOf(
        PeerConversation(
            peerId = "AA:BB:CC:DD:EE:01",
            peerName = "Alice",
            lastMessage = "Hey, are you at the park?",
            lastMessageTimestamp = System.currentTimeMillis() - 300_000,
            unreadCount = 2
        ),
        PeerConversation(
            peerId = "AA:BB:CC:DD:EE:02",
            peerName = "Bob",
            lastMessage = "Got your message!",
            lastMessageTimestamp = System.currentTimeMillis() - 3_600_000,
            unreadCount = 0
        ),
        PeerConversation(
            peerId = "AA:BB:CC:DD:EE:03",
            peerName = "Carol",
            lastMessage = "See you tomorrow",
            lastMessageTimestamp = System.currentTimeMillis() - 86_400_000,
            unreadCount = 0
        )
    )

    private fun placeholderMessages(peerId: String): List<Message> = listOf(
        Message(
            id = "msg-1",
            senderId = peerId,
            content = "Hey there!",
            timestamp = System.currentTimeMillis() - 600_000,
            isOutgoing = false,
            isDelivered = true
        ),
        Message(
            id = "msg-2",
            senderId = "self",
            content = "Hi! How are you?",
            timestamp = System.currentTimeMillis() - 500_000,
            isOutgoing = true,
            isDelivered = true
        ),
        Message(
            id = "msg-3",
            senderId = peerId,
            content = "Good! Are you nearby?",
            timestamp = System.currentTimeMillis() - 400_000,
            isOutgoing = false,
            isDelivered = true
        ),
        Message(
            id = "msg-4",
            senderId = "self",
            content = "Yeah, I'm at the coffee shop on Main St",
            timestamp = System.currentTimeMillis() - 300_000,
            isOutgoing = true,
            isDelivered = false
        )
    )

    // endregion
}
