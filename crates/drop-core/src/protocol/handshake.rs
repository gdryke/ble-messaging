use serde::{Serialize, Deserialize};
use uuid::Uuid;

use crate::crypto::identity::DeviceId;
use crate::protocol::PROTOCOL_VERSION;

/// Handshake payload exchanged after GATT connection.
///
/// Wire format: [device_id:16][public_key:32][msg_count:1][version:1][msg_ids:16×N]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Handshake {
    pub device_id: DeviceId,
    pub public_key: [u8; 32],
    pub version: u8,
    pub pending_msg_ids: Vec<Uuid>,
}

impl Handshake {
    pub const HEADER_SIZE: usize = 50; // device_id(16) + public_key(32) + msg_count(1) + version(1)

    pub fn new(device_id: DeviceId, public_key: [u8; 32], pending_msg_ids: Vec<Uuid>) -> Self {
        Self {
            device_id,
            public_key,
            version: PROTOCOL_VERSION,
            pending_msg_ids,
        }
    }

    /// Serialize to wire bytes.
    pub fn to_bytes(&self) -> Vec<u8> {
        let msg_count = self.pending_msg_ids.len().min(255) as u8;
        let mut buf = Vec::with_capacity(Self::HEADER_SIZE + (msg_count as usize) * 16);
        buf.extend_from_slice(self.device_id.as_bytes());
        buf.extend_from_slice(&self.public_key);
        buf.push(msg_count);
        buf.push(self.version);
        for id in self.pending_msg_ids.iter().take(255) {
            buf.extend_from_slice(id.as_bytes());
        }
        buf
    }

    /// Deserialize from wire bytes.
    pub fn from_bytes(data: &[u8]) -> Option<Self> {
        if data.len() < Self::HEADER_SIZE {
            return None;
        }

        let device_id = DeviceId(data[0..16].try_into().ok()?);
        let public_key: [u8; 32] = data[16..48].try_into().ok()?;
        let msg_count = data[48] as usize;
        let version = data[49];

        let expected_len = Self::HEADER_SIZE + msg_count * 16;
        if data.len() < expected_len {
            return None;
        }

        let mut pending_msg_ids = Vec::with_capacity(msg_count);
        for i in 0..msg_count {
            let offset = Self::HEADER_SIZE + i * 16;
            let id = Uuid::from_bytes(data[offset..offset + 16].try_into().ok()?);
            pending_msg_ids.push(id);
        }

        Some(Self { device_id, public_key, version, pending_msg_ids })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::identity::Identity;

    #[test]
    fn test_handshake_roundtrip_empty() {
        let id = Identity::generate();
        let hs = Handshake::new(*id.device_id(), id.public_key_bytes(), vec![]);

        let bytes = hs.to_bytes();
        assert_eq!(bytes.len(), Handshake::HEADER_SIZE);

        let restored = Handshake::from_bytes(&bytes).unwrap();
        assert_eq!(restored.device_id, *id.device_id());
        assert_eq!(restored.public_key, id.public_key_bytes());
        assert_eq!(restored.version, PROTOCOL_VERSION);
        assert!(restored.pending_msg_ids.is_empty());
    }

    #[test]
    fn test_handshake_roundtrip_with_messages() {
        let id = Identity::generate();
        let msg_ids = vec![Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4()];
        let hs = Handshake::new(*id.device_id(), id.public_key_bytes(), msg_ids.clone());

        let bytes = hs.to_bytes();
        let restored = Handshake::from_bytes(&bytes).unwrap();

        assert_eq!(restored.pending_msg_ids.len(), 3);
        assert_eq!(restored.pending_msg_ids, msg_ids);
        assert_eq!(restored.public_key, id.public_key_bytes());
    }
}
