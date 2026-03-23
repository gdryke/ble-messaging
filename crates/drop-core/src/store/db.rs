use rusqlite::{Connection, params, Result as SqlResult};
use uuid::Uuid;

use crate::crypto::identity::{DeviceId, Peer};
use crate::protocol::message::Message;

/// Local message store backed by SQLite.
pub struct MessageStore {
    conn: Connection,
}

impl MessageStore {
    /// Open (or create) a message store at the given path.
    pub fn open(path: &str) -> SqlResult<Self> {
        let conn = Connection::open(path)?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    /// Open an in-memory store (for testing).
    pub fn in_memory() -> SqlResult<Self> {
        let conn = Connection::open_in_memory()?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    fn migrate(&self) -> SqlResult<()> {
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS peers (
                device_id   BLOB PRIMARY KEY,
                public_key  BLOB NOT NULL,
                display_name TEXT NOT NULL,
                last_seen   INTEGER
            );

            CREATE TABLE IF NOT EXISTS messages (
                msg_id       BLOB PRIMARY KEY,
                sender_id    BLOB NOT NULL,
                recipient_id BLOB NOT NULL,
                timestamp_ms INTEGER NOT NULL,
                nonce        BLOB NOT NULL,
                ciphertext   BLOB NOT NULL,
                direction    TEXT NOT NULL CHECK(direction IN ('inbound', 'outbound')),
                status       TEXT NOT NULL DEFAULT 'queued'
                    CHECK(status IN ('queued', 'transferring', 'delivered', 'received', 'read'))
            );

            CREATE INDEX IF NOT EXISTS idx_messages_recipient
                ON messages(recipient_id, status);

            CREATE TABLE IF NOT EXISTS seen_msg_ids (
                msg_id     BLOB PRIMARY KEY,
                expires_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS transfer_state (
                msg_id          BLOB NOT NULL,
                peer_id         BLOB NOT NULL,
                direction       TEXT NOT NULL CHECK(direction IN ('inbound', 'outbound')),
                last_acked_chunk INTEGER NOT NULL DEFAULT -1,
                total_chunks    INTEGER NOT NULL,
                PRIMARY KEY (msg_id, peer_id, direction)
            );"
        )
    }

    // -- Peers --

    pub fn upsert_peer(&self, peer: &Peer) -> SqlResult<()> {
        self.conn.execute(
            "INSERT INTO peers (device_id, public_key, display_name, last_seen)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(device_id) DO UPDATE SET
                display_name = excluded.display_name,
                last_seen = excluded.last_seen",
            params![
                peer.device_id.as_bytes().as_slice(),
                peer.public_key.as_slice(),
                peer.display_name,
                peer.last_seen,
            ],
        )?;
        Ok(())
    }

    pub fn get_peer(&self, device_id: &DeviceId) -> SqlResult<Option<Peer>> {
        let mut stmt = self.conn.prepare(
            "SELECT device_id, public_key, display_name, last_seen FROM peers WHERE device_id = ?1"
        )?;

        let mut rows = stmt.query_map(params![device_id.as_bytes().as_slice()], |row| {
            let did_bytes: Vec<u8> = row.get(0)?;
            let pk_bytes: Vec<u8> = row.get(1)?;
            let display_name: String = row.get(2)?;
            let last_seen: Option<i64> = row.get(3)?;

            let mut did = [0u8; 16];
            did.copy_from_slice(&did_bytes);
            let mut pk = [0u8; 32];
            pk.copy_from_slice(&pk_bytes);

            Ok(Peer {
                device_id: DeviceId(did),
                public_key: pk,
                display_name,
                last_seen,
            })
        })?;

        match rows.next() {
            Some(Ok(peer)) => Ok(Some(peer)),
            Some(Err(e)) => Err(e),
            None => Ok(None),
        }
    }

    pub fn list_peers(&self) -> SqlResult<Vec<Peer>> {
        let mut stmt = self.conn.prepare(
            "SELECT device_id, public_key, display_name, last_seen FROM peers ORDER BY display_name"
        )?;

        let rows = stmt.query_map([], |row| {
            let did_bytes: Vec<u8> = row.get(0)?;
            let pk_bytes: Vec<u8> = row.get(1)?;
            let display_name: String = row.get(2)?;
            let last_seen: Option<i64> = row.get(3)?;

            let mut did = [0u8; 16];
            did.copy_from_slice(&did_bytes);
            let mut pk = [0u8; 32];
            pk.copy_from_slice(&pk_bytes);

            Ok(Peer {
                device_id: DeviceId(did),
                public_key: pk,
                display_name,
                last_seen,
            })
        })?;

        rows.collect()
    }

    // -- Messages --

    pub fn store_outbound_message(&self, msg: &Message) -> SqlResult<()> {
        self.conn.execute(
            "INSERT OR IGNORE INTO messages (msg_id, sender_id, recipient_id, timestamp_ms, nonce, ciphertext, direction, status)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'outbound', 'queued')",
            params![
                msg.msg_id.as_bytes().as_slice(),
                msg.sender_id.as_bytes().as_slice(),
                msg.recipient_id.as_bytes().as_slice(),
                msg.timestamp_ms as i64,
                msg.nonce.as_slice(),
                msg.ciphertext.as_slice(),
            ],
        )?;
        Ok(())
    }

    pub fn store_inbound_message(&self, msg: &Message) -> SqlResult<()> {
        self.conn.execute(
            "INSERT OR IGNORE INTO messages (msg_id, sender_id, recipient_id, timestamp_ms, nonce, ciphertext, direction, status)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'inbound', 'received')",
            params![
                msg.msg_id.as_bytes().as_slice(),
                msg.sender_id.as_bytes().as_slice(),
                msg.recipient_id.as_bytes().as_slice(),
                msg.timestamp_ms as i64,
                msg.nonce.as_slice(),
                msg.ciphertext.as_slice(),
            ],
        )?;
        Ok(())
    }

    /// Get all queued outbound messages for a specific peer.
    pub fn get_pending_for_peer(&self, recipient_id: &DeviceId) -> SqlResult<Vec<Message>> {
        let mut stmt = self.conn.prepare(
            "SELECT msg_id, sender_id, recipient_id, timestamp_ms, nonce, ciphertext
             FROM messages
             WHERE recipient_id = ?1 AND direction = 'outbound' AND status = 'queued'
             ORDER BY timestamp_ms ASC"
        )?;

        let rows = stmt.query_map(params![recipient_id.as_bytes().as_slice()], |row| {
            let msg_id_bytes: Vec<u8> = row.get(0)?;
            let sender_bytes: Vec<u8> = row.get(1)?;
            let recip_bytes: Vec<u8> = row.get(2)?;
            let timestamp_ms: i64 = row.get(3)?;
            let nonce_bytes: Vec<u8> = row.get(4)?;
            let ciphertext: Vec<u8> = row.get(5)?;

            Ok(Message {
                msg_id: Uuid::from_bytes(msg_id_bytes.as_slice().try_into().unwrap()),
                sender_id: DeviceId(sender_bytes.as_slice().try_into().unwrap()),
                recipient_id: DeviceId(recip_bytes.as_slice().try_into().unwrap()),
                timestamp_ms: timestamp_ms as u64,
                nonce: nonce_bytes.as_slice().try_into().unwrap(),
                ciphertext,
            })
        })?;

        rows.collect()
    }

    /// Get all peers that have pending outbound messages (for Bloom filter).
    pub fn get_pending_recipients(&self) -> SqlResult<Vec<DeviceId>> {
        let mut stmt = self.conn.prepare(
            "SELECT DISTINCT recipient_id FROM messages
             WHERE direction = 'outbound' AND status = 'queued'"
        )?;

        let rows = stmt.query_map([], |row| {
            let bytes: Vec<u8> = row.get(0)?;
            Ok(DeviceId(bytes.as_slice().try_into().unwrap()))
        })?;

        rows.collect()
    }

    pub fn mark_delivered(&self, msg_id: &Uuid) -> SqlResult<()> {
        self.conn.execute(
            "UPDATE messages SET status = 'delivered' WHERE msg_id = ?1",
            params![msg_id.as_bytes().as_slice()],
        )?;
        Ok(())
    }

    // -- Deduplication --

    pub fn is_seen(&self, msg_id: &Uuid) -> SqlResult<bool> {
        let count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM seen_msg_ids WHERE msg_id = ?1",
            params![msg_id.as_bytes().as_slice()],
            |row| row.get(0),
        )?;
        Ok(count > 0)
    }

    pub fn mark_seen(&self, msg_id: &Uuid, ttl_days: i64) -> SqlResult<()> {
        let expires_at = chrono::Utc::now().timestamp() + (ttl_days * 86400);
        self.conn.execute(
            "INSERT OR IGNORE INTO seen_msg_ids (msg_id, expires_at) VALUES (?1, ?2)",
            params![msg_id.as_bytes().as_slice(), expires_at],
        )?;
        Ok(())
    }

    pub fn cleanup_expired(&self) -> SqlResult<usize> {
        let now = chrono::Utc::now().timestamp();
        self.conn.execute(
            "DELETE FROM seen_msg_ids WHERE expires_at < ?1",
            params![now],
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::identity::Identity;
    use crate::crypto::encryption::derive_message_key;
    use crate::protocol::message::Payload;

    fn create_test_message(sender: &Identity, recipient: &Identity) -> Message {
        let shared = sender.diffie_hellman(recipient.public_key());
        let key = derive_message_key(&shared, sender.device_id(), recipient.device_id());
        let payload = Payload::text("test message");
        Message::create(
            Uuid::new_v4(),
            *sender.device_id(),
            *recipient.device_id(),
            &key,
            &payload,
        ).unwrap()
    }

    #[test]
    fn test_peer_crud() {
        let store = MessageStore::in_memory().unwrap();
        let id = Identity::generate();

        let peer = Peer::new(id.public_key_bytes(), "Alice".to_string());
        store.upsert_peer(&peer).unwrap();

        let loaded = store.get_peer(id.device_id()).unwrap().unwrap();
        assert_eq!(loaded.display_name, "Alice");
        assert_eq!(loaded.public_key, id.public_key_bytes());

        let peers = store.list_peers().unwrap();
        assert_eq!(peers.len(), 1);
    }

    #[test]
    fn test_message_store_and_retrieve() {
        let store = MessageStore::in_memory().unwrap();
        let alice = Identity::generate();
        let bob = Identity::generate();

        let msg = create_test_message(&alice, &bob);
        store.store_outbound_message(&msg).unwrap();

        let pending = store.get_pending_for_peer(bob.device_id()).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].msg_id, msg.msg_id);

        let recipients = store.get_pending_recipients().unwrap();
        assert_eq!(recipients.len(), 1);
        assert_eq!(recipients[0], *bob.device_id());
    }

    #[test]
    fn test_mark_delivered() {
        let store = MessageStore::in_memory().unwrap();
        let alice = Identity::generate();
        let bob = Identity::generate();

        let msg = create_test_message(&alice, &bob);
        store.store_outbound_message(&msg).unwrap();

        store.mark_delivered(&msg.msg_id).unwrap();

        let pending = store.get_pending_for_peer(bob.device_id()).unwrap();
        assert!(pending.is_empty());
    }

    #[test]
    fn test_deduplication() {
        let store = MessageStore::in_memory().unwrap();
        let msg_id = Uuid::new_v4();

        assert!(!store.is_seen(&msg_id).unwrap());
        store.mark_seen(&msg_id, 30).unwrap();
        assert!(store.is_seen(&msg_id).unwrap());
    }
}
