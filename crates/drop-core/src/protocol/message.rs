use serde::{Serialize, Deserialize};
use uuid::Uuid;

use crate::crypto::identity::DeviceId;
use crate::crypto::encryption::{self, CryptoError};
use crate::protocol::MAX_BODY_SIZE;

/// Message types carried in the plaintext payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum MessageType {
    Text = 0x01,
    Ack = 0x02,
    ReadReceipt = 0x03,
}

impl MessageType {
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            0x01 => Some(Self::Text),
            0x02 => Some(Self::Ack),
            0x03 => Some(Self::ReadReceipt),
            _ => None,
        }
    }
}

/// Plaintext payload before encryption.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Payload {
    pub msg_type: MessageType,
    pub body: Vec<u8>,
}

impl Payload {
    pub fn text(body: &str) -> Self {
        Self {
            msg_type: MessageType::Text,
            body: body.as_bytes().to_vec(),
        }
    }

    pub fn ack(msg_id: &Uuid) -> Self {
        Self {
            msg_type: MessageType::Ack,
            body: msg_id.as_bytes().to_vec(),
        }
    }

    pub fn read_receipt(msg_id: &Uuid) -> Self {
        Self {
            msg_type: MessageType::ReadReceipt,
            body: msg_id.as_bytes().to_vec(),
        }
    }

    /// Serialize to wire format: [type: 1][body_len: 2][body: N]
    pub fn to_bytes(&self) -> Vec<u8> {
        let body_len = self.body.len() as u16;
        let mut buf = Vec::with_capacity(3 + self.body.len());
        buf.push(self.msg_type as u8);
        buf.extend_from_slice(&body_len.to_be_bytes());
        buf.extend_from_slice(&self.body);
        buf
    }

    /// Deserialize from wire format.
    pub fn from_bytes(data: &[u8]) -> Option<Self> {
        if data.len() < 3 {
            return None;
        }
        let msg_type = MessageType::from_byte(data[0])?;
        let body_len = u16::from_be_bytes([data[1], data[2]]) as usize;
        if data.len() < 3 + body_len {
            return None;
        }
        Some(Self {
            msg_type,
            body: data[3..3 + body_len].to_vec(),
        })
    }
}

/// Encrypted message envelope ready for transfer over BLE.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub msg_id: Uuid,
    pub sender_id: DeviceId,
    pub recipient_id: DeviceId,
    pub timestamp_ms: u64,
    pub nonce: [u8; 24],
    pub ciphertext: Vec<u8>,
}

impl Message {
    /// Create a new encrypted message.
    pub fn create(
        msg_id: Uuid,
        sender_id: DeviceId,
        recipient_id: DeviceId,
        encryption_key: &[u8; 32],
        payload: &Payload,
    ) -> Result<Self, CryptoError> {
        let plaintext = payload.to_bytes();
        assert!(
            plaintext.len() <= MAX_BODY_SIZE + 3,
            "payload exceeds maximum body size"
        );

        let timestamp_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;

        let (nonce, ciphertext) = encryption::encrypt(encryption_key, &plaintext)?;

        Ok(Self {
            msg_id,
            sender_id,
            recipient_id,
            timestamp_ms,
            nonce,
            ciphertext,
        })
    }

    /// Decrypt and deserialize the message payload.
    pub fn decrypt(&self, encryption_key: &[u8; 32]) -> Result<Payload, CryptoError> {
        let plaintext = encryption::decrypt(encryption_key, &self.nonce, &self.ciphertext)?;
        Payload::from_bytes(&plaintext).ok_or(CryptoError::DecryptionFailed)
    }

    /// Serialize the full envelope to wire bytes.
    /// Layout: [msg_id:16][sender_id:16][recipient_id:16][timestamp:8][nonce:24][ciphertext:N]
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(80 + self.ciphertext.len());
        buf.extend_from_slice(self.msg_id.as_bytes());
        buf.extend_from_slice(self.sender_id.as_bytes());
        buf.extend_from_slice(self.recipient_id.as_bytes());
        buf.extend_from_slice(&self.timestamp_ms.to_be_bytes());
        buf.extend_from_slice(&self.nonce);
        buf.extend_from_slice(&self.ciphertext);
        buf
    }

    /// Deserialize from wire bytes.
    pub fn from_bytes(data: &[u8]) -> Option<Self> {
        if data.len() < 80 {
            return None;
        }

        let msg_id = Uuid::from_bytes(data[0..16].try_into().ok()?);
        let sender_id = DeviceId(data[16..32].try_into().ok()?);
        let recipient_id = DeviceId(data[32..48].try_into().ok()?);
        let timestamp_ms = u64::from_be_bytes(data[48..56].try_into().ok()?);
        let nonce: [u8; 24] = data[56..80].try_into().ok()?;
        let ciphertext = data[80..].to_vec();

        Some(Self {
            msg_id,
            sender_id,
            recipient_id,
            timestamp_ms,
            nonce,
            ciphertext,
        })
    }

    /// Total serialized size in bytes.
    pub fn wire_size(&self) -> usize {
        80 + self.ciphertext.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::identity::Identity;
    use crate::crypto::encryption::derive_message_key;

    fn setup() -> ([u8; 32], DeviceId, DeviceId) {
        let alice = Identity::generate();
        let bob = Identity::generate();
        let shared = alice.diffie_hellman(bob.public_key());
        let key = derive_message_key(&shared, alice.device_id(), bob.device_id());
        (key, *alice.device_id(), *bob.device_id())
    }

    #[test]
    fn test_payload_roundtrip() {
        let payload = Payload::text("hello world");
        let bytes = payload.to_bytes();
        let decoded = Payload::from_bytes(&bytes).unwrap();
        assert_eq!(decoded.msg_type, MessageType::Text);
        assert_eq!(decoded.body, b"hello world");
    }

    #[test]
    fn test_message_encrypt_decrypt() {
        let (key, sender_id, recipient_id) = setup();
        let payload = Payload::text("secret message");
        let msg_id = Uuid::new_v4();

        let msg = Message::create(msg_id, sender_id, recipient_id, &key, &payload).unwrap();
        let decrypted = msg.decrypt(&key).unwrap();

        assert_eq!(decrypted.msg_type, MessageType::Text);
        assert_eq!(decrypted.body, b"secret message");
    }

    #[test]
    fn test_message_wire_roundtrip() {
        let (key, sender_id, recipient_id) = setup();
        let payload = Payload::text("over the wire");
        let msg_id = Uuid::new_v4();

        let msg = Message::create(msg_id, sender_id, recipient_id, &key, &payload).unwrap();
        let bytes = msg.to_bytes();
        let restored = Message::from_bytes(&bytes).unwrap();

        assert_eq!(restored.msg_id, msg.msg_id);
        assert_eq!(restored.sender_id, msg.sender_id);
        assert_eq!(restored.recipient_id, msg.recipient_id);
        assert_eq!(restored.timestamp_ms, msg.timestamp_ms);
        assert_eq!(restored.nonce, msg.nonce);
        assert_eq!(restored.ciphertext, msg.ciphertext);

        let decrypted = restored.decrypt(&key).unwrap();
        assert_eq!(decrypted.body, b"over the wire");
    }
}
