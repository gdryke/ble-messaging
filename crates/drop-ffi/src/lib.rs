uniffi::setup_scaffolding!();

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use uuid::Uuid;

use drop_core::bloom::BloomFilter;
use drop_core::crypto::encryption::derive_message_key;
use drop_core::crypto::identity::{DeviceId, Identity, Peer};
use drop_core::protocol::chunk::{Chunk, ChunkAck};
use drop_core::protocol::handshake::Handshake;
use drop_core::protocol::message::{Message, MessageType, Payload};
use drop_core::store::db::MessageStore;

// ── Error type ──────────────────────────────────────────────────────────

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum DropError {
    #[error("database error: {msg}")]
    Database { msg: String },
    #[error("crypto error: {msg}")]
    Crypto { msg: String },
    #[error("invalid data: {msg}")]
    InvalidData { msg: String },
    #[error("peer not found: {device_id}")]
    PeerNotFound { device_id: String },
}

// ── FFI-friendly records ────────────────────────────────────────────────

#[derive(uniffi::Record)]
pub struct FfiIdentity {
    pub device_id: Vec<u8>,
    pub public_key: Vec<u8>,
    pub secret_key: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct FfiPeer {
    pub device_id: Vec<u8>,
    pub public_key: Vec<u8>,
    pub display_name: String,
    pub last_seen: Option<i64>,
}

#[derive(uniffi::Record)]
pub struct FfiMessage {
    pub msg_id: String,
    pub sender_id: Vec<u8>,
    pub recipient_id: Vec<u8>,
    pub timestamp_ms: u64,
    pub wire_bytes: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct FfiDecryptedMessage {
    pub msg_id: String,
    pub sender_id: Vec<u8>,
    pub msg_type: String,
    pub body: String,
    pub timestamp_ms: u64,
}

#[derive(uniffi::Record)]
pub struct FfiHandshakeInfo {
    pub device_id: Vec<u8>,
    pub public_key: Vec<u8>,
    pub version: u8,
    pub pending_msg_ids: Vec<String>,
}

#[derive(uniffi::Record)]
pub struct FfiChunkResult {
    pub msg_id: String,
    pub chunk_index: u16,
    pub total_chunks: u16,
    pub is_complete: bool,
    pub assembled_message: Option<Vec<u8>>,
}

// ── Core object ─────────────────────────────────────────────────────────

/// Tracks chunks received for a message: (total_chunks, received_chunks)
type ReassemblyState = HashMap<Uuid, (u16, Vec<Option<Vec<u8>>>)>;

#[derive(uniffi::Object)]
pub struct DropCore {
    identity: Identity,
    store: Mutex<MessageStore>,
    reassembly: Mutex<ReassemblyState>,
}

#[uniffi::export]
impl DropCore {
    /// Create or restore a DropCore instance.
    /// If `secret_key` is provided (32 bytes), restores that identity.
    /// Otherwise, generates a new one.
    #[uniffi::constructor]
    pub fn new(db_path: String, secret_key: Option<Vec<u8>>) -> Result<Arc<Self>, DropError> {
        let identity = match secret_key {
            Some(ref key) if key.len() == 32 => {
                let mut bytes = [0u8; 32];
                bytes.copy_from_slice(key);
                Identity::from_secret_bytes(&bytes)
            }
            _ => Identity::generate(),
        };

        let store = if db_path == ":memory:" {
            MessageStore::in_memory()
        } else {
            MessageStore::open(&db_path)
        }
        .map_err(|e| DropError::Database { msg: e.to_string() })?;

        Ok(Arc::new(Self {
            identity,
            store: Mutex::new(store),
            reassembly: Mutex::new(HashMap::new()),
        }))
    }

    // ── Identity ────────────────────────────────────────────────────

    pub fn get_identity(&self) -> FfiIdentity {
        FfiIdentity {
            device_id: self.identity.device_id().as_bytes().to_vec(),
            public_key: self.identity.public_key_bytes().to_vec(),
            secret_key: self.identity.secret_bytes().to_vec(),
        }
    }

    pub fn get_device_id(&self) -> Vec<u8> {
        self.identity.device_id().as_bytes().to_vec()
    }

    // ── Peers ───────────────────────────────────────────────────────

    pub fn add_peer(
        &self,
        public_key: Vec<u8>,
        display_name: String,
    ) -> Result<FfiPeer, DropError> {
        if public_key.len() != 32 {
            return Err(DropError::InvalidData {
                msg: "public key must be 32 bytes".into(),
            });
        }
        let mut pk = [0u8; 32];
        pk.copy_from_slice(&public_key);
        let peer = Peer::new(pk, display_name);

        let store = self.store.lock().unwrap();
        store
            .upsert_peer(&peer)
            .map_err(|e| DropError::Database { msg: e.to_string() })?;

        Ok(FfiPeer {
            device_id: peer.device_id.as_bytes().to_vec(),
            public_key: peer.public_key.to_vec(),
            display_name: peer.display_name,
            last_seen: peer.last_seen,
        })
    }

    pub fn get_peers(&self) -> Result<Vec<FfiPeer>, DropError> {
        let store = self.store.lock().unwrap();
        let peers = store
            .list_peers()
            .map_err(|e| DropError::Database { msg: e.to_string() })?;

        Ok(peers
            .into_iter()
            .map(|p| FfiPeer {
                device_id: p.device_id.as_bytes().to_vec(),
                public_key: p.public_key.to_vec(),
                display_name: p.display_name,
                last_seen: p.last_seen,
            })
            .collect())
    }

    // ── Messages ────────────────────────────────────────────────────

    /// Compose, encrypt, store, and return a new outbound message.
    pub fn compose_message(
        &self,
        recipient_device_id: Vec<u8>,
        text: String,
    ) -> Result<FfiMessage, DropError> {
        let recipient_id = parse_device_id(&recipient_device_id)?;
        let peer = self.load_peer(&recipient_id)?;

        let shared = self.identity.diffie_hellman(&peer.x25519_public_key());
        let key = derive_message_key(&shared, self.identity.device_id(), &recipient_id);

        let payload = Payload::text(&text);
        let msg_id = Uuid::new_v4();
        let msg = Message::create(msg_id, *self.identity.device_id(), recipient_id, &key, &payload)
            .map_err(|e| DropError::Crypto { msg: e.to_string() })?;

        let store = self.store.lock().unwrap();
        store
            .store_outbound_message(&msg)
            .map_err(|e| DropError::Database { msg: e.to_string() })?;

        let wire_bytes = msg.to_bytes();
        Ok(FfiMessage {
            msg_id: msg.msg_id.to_string(),
            sender_id: msg.sender_id.as_bytes().to_vec(),
            recipient_id: msg.recipient_id.as_bytes().to_vec(),
            timestamp_ms: msg.timestamp_ms,
            wire_bytes,
        })
    }

    /// Decrypt a received message from wire bytes.
    pub fn receive_message(&self, wire_bytes: Vec<u8>) -> Result<FfiDecryptedMessage, DropError> {
        let msg = Message::from_bytes(&wire_bytes)
            .ok_or_else(|| DropError::InvalidData { msg: "malformed message".into() })?;

        // Check dedup
        {
            let store = self.store.lock().unwrap();
            if store.is_seen(&msg.msg_id).unwrap_or(false) {
                return Err(DropError::InvalidData { msg: "duplicate message".into() });
            }
        }

        let peer = self.load_peer(&msg.sender_id)?;
        let shared = self.identity.diffie_hellman(&peer.x25519_public_key());
        let key = derive_message_key(&shared, &msg.sender_id, self.identity.device_id());

        let payload = msg
            .decrypt(&key)
            .map_err(|e| DropError::Crypto { msg: e.to_string() })?;

        // Store and mark seen
        {
            let store = self.store.lock().unwrap();
            store
                .store_inbound_message(&msg)
                .map_err(|e| DropError::Database { msg: e.to_string() })?;
            store
                .mark_seen(&msg.msg_id, 30)
                .map_err(|e| DropError::Database { msg: e.to_string() })?;
        }

        let msg_type = match payload.msg_type {
            MessageType::Text => "text",
            MessageType::Ack => "ack",
            MessageType::ReadReceipt => "read_receipt",
        };

        let body = String::from_utf8(payload.body).unwrap_or_default();

        Ok(FfiDecryptedMessage {
            msg_id: msg.msg_id.to_string(),
            sender_id: msg.sender_id.as_bytes().to_vec(),
            msg_type: msg_type.to_string(),
            body,
            timestamp_ms: msg.timestamp_ms,
        })
    }

    /// Get all queued outbound messages for a peer (as wire bytes).
    pub fn get_pending_for_peer(
        &self,
        device_id: Vec<u8>,
    ) -> Result<Vec<FfiMessage>, DropError> {
        let did = parse_device_id(&device_id)?;
        let store = self.store.lock().unwrap();
        let messages = store
            .get_pending_for_peer(&did)
            .map_err(|e| DropError::Database { msg: e.to_string() })?;

        Ok(messages
            .into_iter()
            .map(|m| FfiMessage {
                msg_id: m.msg_id.to_string(),
                sender_id: m.sender_id.as_bytes().to_vec(),
                recipient_id: m.recipient_id.as_bytes().to_vec(),
                timestamp_ms: m.timestamp_ms,
                wire_bytes: m.to_bytes(),
            })
            .collect())
    }

    /// Get device IDs of all peers with pending outbound messages.
    pub fn get_pending_recipients(&self) -> Result<Vec<Vec<u8>>, DropError> {
        let store = self.store.lock().unwrap();
        let recipients = store
            .get_pending_recipients()
            .map_err(|e| DropError::Database { msg: e.to_string() })?;
        Ok(recipients.into_iter().map(|d| d.as_bytes().to_vec()).collect())
    }

    pub fn mark_delivered(&self, msg_id: String) -> Result<(), DropError> {
        let uuid = Uuid::parse_str(&msg_id)
            .map_err(|e| DropError::InvalidData { msg: e.to_string() })?;
        let store = self.store.lock().unwrap();
        store
            .mark_delivered(&uuid)
            .map_err(|e| DropError::Database { msg: e.to_string() })?;
        Ok(())
    }

    // ── Bloom Filter ────────────────────────────────────────────────

    /// Build an 8-byte Bloom filter from all pending outbound recipients.
    pub fn build_bloom_filter(&self) -> Result<Vec<u8>, DropError> {
        let store = self.store.lock().unwrap();
        let recipients = store
            .get_pending_recipients()
            .map_err(|e| DropError::Database { msg: e.to_string() })?;

        let mut filter = BloomFilter::empty();
        for r in &recipients {
            filter.insert(r);
        }
        Ok(filter.to_bytes().to_vec())
    }

    /// Check if our device_id is in a remote peer's Bloom filter.
    pub fn check_bloom_filter(&self, filter_bytes: Vec<u8>) -> bool {
        if filter_bytes.len() != 8 {
            return false;
        }
        let mut bytes = [0u8; 8];
        bytes.copy_from_slice(&filter_bytes);
        let filter = BloomFilter::from_bytes(&bytes);
        filter.maybe_contains(self.identity.device_id())
    }

    // ── Handshake ───────────────────────────────────────────────────

    /// Build a handshake payload for a specific peer.
    pub fn build_handshake(
        &self,
        peer_device_id: Vec<u8>,
    ) -> Result<Vec<u8>, DropError> {
        let did = parse_device_id(&peer_device_id)?;
        let store = self.store.lock().unwrap();
        let pending = store
            .get_pending_for_peer(&did)
            .map_err(|e| DropError::Database { msg: e.to_string() })?;

        let msg_ids: Vec<Uuid> = pending.iter().map(|m| m.msg_id).collect();
        let hs = Handshake::new(
            *self.identity.device_id(),
            self.identity.public_key_bytes(),
            msg_ids,
        );
        Ok(hs.to_bytes())
    }

    /// Parse a received handshake payload.
    pub fn parse_handshake(&self, data: Vec<u8>) -> Result<FfiHandshakeInfo, DropError> {
        let hs = Handshake::from_bytes(&data)
            .ok_or_else(|| DropError::InvalidData { msg: "malformed handshake".into() })?;

        Ok(FfiHandshakeInfo {
            device_id: hs.device_id.as_bytes().to_vec(),
            public_key: hs.public_key.to_vec(),
            version: hs.version,
            pending_msg_ids: hs.pending_msg_ids.iter().map(|id| id.to_string()).collect(),
        })
    }

    /// Parse a handshake and auto-register the peer. Returns the peer info.
    pub fn handle_handshake(&self, data: Vec<u8>) -> Result<FfiPeer, DropError> {
        let hs = Handshake::from_bytes(&data)
            .ok_or_else(|| DropError::InvalidData { msg: "malformed handshake".into() })?;

        let id_hex: String = hs.device_id.as_bytes()[..4]
            .iter()
            .map(|b| format!("{:02x}", b))
            .collect();
        let peer = Peer::new(
            hs.public_key,
            format!("Drop-{}", id_hex),
        );

        let store = self.store.lock().unwrap();
        store
            .upsert_peer(&peer)
            .map_err(|e| DropError::Database { msg: e.to_string() })?;

        Ok(FfiPeer {
            device_id: peer.device_id.as_bytes().to_vec(),
            public_key: peer.public_key.to_vec(),
            display_name: peer.display_name,
            last_seen: peer.last_seen,
        })
    }

    // ── Chunking ────────────────────────────────────────────────────

    /// Split a message's wire bytes into MTU-sized chunks (each as wire bytes).
    pub fn split_into_chunks(&self, msg_wire_bytes: Vec<u8>, mtu: u16) -> Vec<Vec<u8>> {
        let msg = match Message::from_bytes(&msg_wire_bytes) {
            Some(m) => m,
            None => return vec![],
        };
        let chunks = Chunk::split(msg.msg_id, &msg_wire_bytes, mtu);
        chunks.iter().map(|c| c.to_bytes()).collect()
    }

    /// Process a received chunk. Returns result indicating whether the
    /// full message has been reassembled.
    pub fn process_chunk(&self, chunk_bytes: Vec<u8>) -> Result<FfiChunkResult, DropError> {
        let chunk = Chunk::from_bytes(&chunk_bytes)
            .ok_or_else(|| DropError::InvalidData { msg: "malformed chunk".into() })?;

        let mut reassembly = self.reassembly.lock().unwrap();
        let entry = reassembly
            .entry(chunk.msg_id)
            .or_insert_with(|| {
                let slots = vec![None; chunk.total_chunks as usize];
                (chunk.total_chunks, slots)
            });

        let idx = chunk.chunk_index as usize;
        if idx < entry.1.len() {
            entry.1[idx] = Some(chunk.payload.clone());
        }

        let received_count = entry.1.iter().filter(|s| s.is_some()).count();
        let is_complete = received_count == entry.0 as usize;

        let assembled = if is_complete {
            let data: Vec<u8> = entry.1.iter().flat_map(|s| s.as_ref().unwrap().iter().copied()).collect();
            reassembly.remove(&chunk.msg_id);
            Some(data)
        } else {
            None
        };

        Ok(FfiChunkResult {
            msg_id: chunk.msg_id.to_string(),
            chunk_index: chunk.chunk_index,
            total_chunks: chunk.total_chunks,
            is_complete,
            assembled_message: assembled,
        })
    }

    /// Build a chunk ACK (wire bytes).
    pub fn build_ack(&self, msg_id: String, chunk_index: u16) -> Result<Vec<u8>, DropError> {
        let uuid = Uuid::parse_str(&msg_id)
            .map_err(|e| DropError::InvalidData { msg: e.to_string() })?;
        let ack = ChunkAck { msg_id: uuid, chunk_index };
        Ok(ack.to_bytes())
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────

fn parse_device_id(bytes: &[u8]) -> Result<DeviceId, DropError> {
    if bytes.len() != 16 {
        return Err(DropError::InvalidData {
            msg: format!("device_id must be 16 bytes, got {}", bytes.len()),
        });
    }
    let mut id = [0u8; 16];
    id.copy_from_slice(bytes);
    Ok(DeviceId(id))
}

impl DropCore {
    fn load_peer(&self, device_id: &DeviceId) -> Result<Peer, DropError> {
        let store = self.store.lock().unwrap();
        store
            .get_peer(device_id)
            .map_err(|e| DropError::Database { msg: e.to_string() })?
            .ok_or_else(|| DropError::PeerNotFound {
                device_id: device_id.to_string(),
            })
    }
}
