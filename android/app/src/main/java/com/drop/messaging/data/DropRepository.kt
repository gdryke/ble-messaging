package com.drop.messaging.data

import android.content.Context
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import uniffi.drop_ffi.DropCore
import uniffi.drop_ffi.DropException
import uniffi.drop_ffi.FfiChunkResult
import uniffi.drop_ffi.FfiHandshakeInfo
import java.util.concurrent.ConcurrentHashMap

/**
 * Bridges the Rust drop-core library to Android via UniFFI.
 *
 * DEPENDENCY: This file imports `uniffi.drop_ffi.*`, which is generated during the
 * Rust/NDK cross-compilation step. The bindings will not be available until the native
 * .so libraries are built for Android targets:
 *
 *   cd rust/drop-ffi
 *   cargo ndk -t aarch64-linux-android -t armv7-linux-androideabi \
 *       -o ../../android/app/src/main/jniLibs build --release
 *
 * Until then, `uniffi.drop_ffi.*` imports are unresolved and this file will not compile.
 * This is expected — the rest of the Kotlin code is syntactically correct.
 *
 * NOTE: The constructor now requires an Android [Context] to locate the database file
 * and access SharedPreferences. Callers that previously used the no-arg constructor
 * (BleService, ConversationListScreen, ChatScreen) must be updated to pass a Context.
 */
class DropRepository(context: Context) {

    companion object {
        private const val TAG = "DropRepository"
        private const val PREFS_NAME = "drop_prefs"
        private const val KEY_SECRET_KEY = "drop_secret_key"
        private const val DEFAULT_BLE_MTU: UShort = 512u

        // DropCore is thread-safe and backed by SQLite; only one instance per process
        // to avoid database locking issues.
        @Volatile private var coreInstance: DropCore? = null
        private val coreLock = Any()

        // BLE MAC address → Drop device ID mapping, populated during handshake.
        private val bleAddressToDeviceId = ConcurrentHashMap<String, ByteArray>()

        // Shared observable state so that the BLE service and UI instances of
        // DropRepository see the same conversations and messages.
        private val _conversations = MutableStateFlow<List<PeerConversation>>(emptyList())
        private val _messagesByPeer = ConcurrentHashMap<String, MutableStateFlow<List<Message>>>()

        private fun getOrCreateCore(context: Context): DropCore {
            return coreInstance ?: synchronized(coreLock) {
                coreInstance ?: run {
                    val appCtx = context.applicationContext
                    val dbPath = appCtx.filesDir.resolve("drop.db").absolutePath
                    val secretKey = loadSecretKey(appCtx)
                    val core = DropCore.new(dbPath, secretKey)
                    // If no key was stored, the core generated a new identity — persist it
                    if (secretKey == null) {
                        saveSecretKey(appCtx, core.getIdentity().secretKey)
                    }
                    Log.i(TAG, "DropCore initialized (db=$dbPath)")
                    coreInstance = core
                    core
                }
            }
        }

        private fun loadSecretKey(context: Context): ByteArray? {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val encoded = prefs.getString(KEY_SECRET_KEY, null) ?: return null
            return try {
                Base64.decode(encoded, Base64.NO_WRAP)
            } catch (e: IllegalArgumentException) {
                Log.e(TAG, "Corrupted secret key in SharedPreferences — will regenerate", e)
                null
            }
        }

        private fun saveSecretKey(context: Context, key: ByteArray) {
            val encoded = Base64.encodeToString(key, Base64.NO_WRAP)
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_SECRET_KEY, encoded)
                .apply()
            Log.d(TAG, "Secret key persisted to SharedPreferences")
        }
    }

    // region Data Classes

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

    // endregion

    private val core: DropCore = getOrCreateCore(context)
    private val myDeviceId: ByteArray = core.getDeviceId()

    val conversations: Flow<List<PeerConversation>> = _conversations.asStateFlow()

    init {
        refreshConversations()
    }

    // region Identity

    /**
     * Returns this device's identity (device ID bytes).
     */
    fun getIdentity(): ByteArray = myDeviceId

    /**
     * Returns a human-readable display name derived from the device ID suffix.
     */
    fun getDisplayName(): String {
        // TODO: Allow the user to set a custom display name (persist in SharedPreferences)
        return "Drop-${myDeviceId.toHexString().takeLast(4)}"
    }

    // endregion

    // region Messages

    /**
     * Returns pending message wire-bytes for a specific peer, split into
     * BLE-MTU-sized chunks ready to transmit.
     *
     * [peerId] can be a BLE MAC address (resolved via handshake mapping)
     * or a hex-encoded Drop device ID.
     */
    fun getPendingMessages(peerId: String): List<ByteArray> {
        return try {
            val deviceId = resolveDeviceId(peerId) ?: run {
                Log.w(TAG, "getPendingMessages: cannot resolve peer '$peerId'")
                return emptyList()
            }
            val pending = core.getPendingForPeer(deviceId)
            if (pending.isEmpty()) return emptyList()

            Log.d(TAG, "getPendingMessages($peerId): ${pending.size} message(s)")
            pending.flatMap { msg ->
                core.splitIntoChunks(msg.wireBytes, DEFAULT_BLE_MTU)
            }
        } catch (e: DropException) {
            Log.e(TAG, "getPendingMessages failed", e)
            emptyList()
        }
    }

    /**
     * Composes and stores an outbound message for the given peer.
     */
    fun storeMessage(peerId: String, content: String) {
        try {
            val deviceId = resolveDeviceId(peerId) ?: run {
                Log.w(TAG, "storeMessage: cannot resolve peer '$peerId'")
                return
            }
            val msg = core.composeMessage(deviceId, content)
            Log.d(TAG, "storeMessage: composed ${msg.msgId} for $peerId")

            val hexPeerId = deviceId.toHexString()
            appendMessage(hexPeerId, Message(
                id = msg.msgId,
                senderId = myDeviceId.toHexString(),
                content = content,
                timestamp = msg.timestampMs.toLong(),
                isOutgoing = true,
                isDelivered = false
            ))
            refreshConversations()
        } catch (e: DropException) {
            Log.e(TAG, "storeMessage failed", e)
        }
    }

    /**
     * Returns an observable flow of messages for a specific peer conversation.
     */
    fun getMessages(peerId: String): Flow<List<Message>> {
        val hexId = resolveDeviceId(peerId)?.toHexString() ?: peerId
        return getOrCreateMessageFlow(hexId).asStateFlow()
    }

    // endregion

    // region BLE Protocol

    /**
     * Returns the Bloom filter advertising payload, encoding which peer IDs
     * we hold pending messages for.
     */
    fun getBloomFilter(): ByteArray {
        return try {
            core.buildBloomFilter()
        } catch (e: DropException) {
            Log.e(TAG, "getBloomFilter failed", e)
            ByteArray(0)
        }
    }

    /**
     * Checks whether an advertised Bloom filter might contain our device ID,
     * indicating the remote peer may have messages for us.
     */
    fun checkBloomFilter(filter: ByteArray): Boolean {
        return try {
            core.checkBloomFilter(filter)
        } catch (e: DropException) {
            Log.e(TAG, "checkBloomFilter failed", e)
            false
        }
    }

    /**
     * Returns our handshake payload for the GATT handshake characteristic.
     * This includes our device identity so the remote peer can identify us.
     */
    fun getHandshakePayload(): ByteArray {
        return try {
            // Build a handshake addressed to an unknown peer (zero-filled ID).
            // The peer can still parse this to learn our identity.
            // TODO: Accept a peerDeviceId parameter for targeted handshakes
            // that include pending-message metadata for the specific peer.
            core.buildHandshake(ByteArray(myDeviceId.size))
        } catch (e: DropException) {
            Log.e(TAG, "getHandshakePayload failed — falling back to raw device ID", e)
            myDeviceId
        }
    }

    /**
     * Processes a handshake payload received from a peer.
     * Maps the BLE MAC address ([peerId]) to the peer's Drop device ID for
     * subsequent message lookups.
     */
    fun handleHandshake(peerId: String, data: ByteArray) {
        try {
            val info: FfiHandshakeInfo = core.parseHandshake(data)
            val deviceHex = info.deviceId.toHexString()
            bleAddressToDeviceId[peerId] = info.deviceId
            Log.i(TAG, "handleHandshake: $peerId → $deviceHex " +
                    "(v${info.version}, ${info.pendingMsgIds.size} pending)")

            // TODO: Register the peer via core.addPeer() once public keys
            // are exchanged as part of the handshake protocol.
        } catch (e: DropException) {
            Log.e(TAG, "handleHandshake failed for $peerId", e)
        }
    }

    /**
     * Processes incoming message data (typically a BLE chunk) from a peer.
     * Reassembles chunks; when a message is complete, decrypts and stores it.
     */
    fun handleIncomingData(peerId: String, data: ByteArray) {
        try {
            val chunk: FfiChunkResult = core.processChunk(data)
            Log.d(TAG, "processChunk: msg=${chunk.msgId} " +
                    "${chunk.chunkIndex + 1u}/${chunk.totalChunks} " +
                    "complete=${chunk.isComplete}")

            if (chunk.isComplete && chunk.assembledMessage != null) {
                val decrypted = core.receiveMessage(chunk.assembledMessage!!)
                val senderHex = decrypted.senderId.toHexString()
                Log.d(TAG, "Received message ${decrypted.msgId} " +
                        "type=${decrypted.msgType} from $senderHex")

                appendMessage(senderHex, Message(
                    id = decrypted.msgId,
                    senderId = senderHex,
                    content = decrypted.body,
                    timestamp = decrypted.timestampMs.toLong(),
                    isOutgoing = false,
                    isDelivered = true
                ))
                refreshConversations()
            }
        } catch (e: DropException) {
            Log.e(TAG, "handleIncomingData failed for $peerId", e)
        }
    }

    /**
     * Processes an ACK received from a peer, marking the acknowledged
     * message as delivered.
     */
    fun handleAck(peerId: String, data: ByteArray) {
        // TODO: The FFI does not yet expose a parseAck() function.
        // Once available, parse `data` to extract the msgId and chunkIndex,
        // then call core.markDelivered(msgId) and update the Message.isDelivered
        // flag in the corresponding message flow.
        Log.d(TAG, "handleAck from $peerId (${data.size} bytes) — " +
                "awaiting parseAck FFI support")
    }

    // endregion

    // region Internal Helpers

    /**
     * Resolves a peer identifier to a Drop device-ID byte array.
     * Accepts BLE MAC addresses (looked up via the handshake map) or
     * hex-encoded device IDs.
     */
    private fun resolveDeviceId(peerId: String): ByteArray? {
        bleAddressToDeviceId[peerId]?.let { return it }
        return try {
            peerId.hexToByteArray()
        } catch (e: Exception) {
            null
        }
    }

    private fun getOrCreateMessageFlow(peerId: String): MutableStateFlow<List<Message>> {
        return _messagesByPeer.getOrPut(peerId) { MutableStateFlow(emptyList()) }
    }

    private fun appendMessage(peerId: String, message: Message) {
        val flow = getOrCreateMessageFlow(peerId)
        flow.value = flow.value + message
    }

    /**
     * Refreshes the conversations list from the DropCore peer list
     * and in-memory messages.
     */
    private fun refreshConversations() {
        try {
            val peers = core.getPeers()
            _conversations.value = peers.map { peer ->
                val hexId = peer.deviceId.toHexString()
                val messages = _messagesByPeer[hexId]?.value.orEmpty()
                val lastMsg = messages.lastOrNull()
                PeerConversation(
                    peerId = hexId,
                    peerName = peer.displayName.ifEmpty { "Drop-${hexId.takeLast(4)}" },
                    lastMessage = lastMsg?.content ?: "",
                    lastMessageTimestamp = lastMsg?.timestamp ?: (peer.lastSeen ?: 0L),
                    unreadCount = 0 // TODO: Track read/unread state per conversation
                )
            }
        } catch (e: DropException) {
            Log.e(TAG, "refreshConversations failed", e)
        }
    }

    // endregion
}

// region Extension Helpers

private fun ByteArray.toHexString(): String =
    joinToString("") { "%02x".format(it) }

private fun String.hexToByteArray(): ByteArray {
    check(length % 2 == 0) { "Hex string must have even length" }
    return chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}

// endregion
