use serde::{Serialize, Deserialize};
use uuid::Uuid;

/// A single chunk of a message being transferred over BLE.
///
/// Wire format: [msg_id:16][chunk_index:2][total_chunks:2][payload:N]
/// Header: 20 bytes fixed.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Chunk {
    pub msg_id: Uuid,
    pub chunk_index: u16,
    pub total_chunks: u16,
    pub payload: Vec<u8>,
}

impl Chunk {
    pub const HEADER_SIZE: usize = 20;

    /// Maximum payload size for a given MTU.
    /// ATT header is 3 bytes, so usable = MTU - 3 - HEADER_SIZE.
    pub fn max_payload_for_mtu(mtu: u16) -> usize {
        (mtu as usize).saturating_sub(3 + Self::HEADER_SIZE)
    }

    /// Split a message's wire bytes into chunks for the given MTU.
    pub fn split(msg_id: Uuid, data: &[u8], mtu: u16) -> Vec<Chunk> {
        let max_payload = Self::max_payload_for_mtu(mtu);
        if max_payload == 0 {
            return vec![];
        }

        let chunks: Vec<&[u8]> = data.chunks(max_payload).collect();
        let total = chunks.len() as u16;

        chunks
            .into_iter()
            .enumerate()
            .map(|(i, payload)| Chunk {
                msg_id,
                chunk_index: i as u16,
                total_chunks: total,
                payload: payload.to_vec(),
            })
            .collect()
    }

    /// Serialize to wire bytes.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(Self::HEADER_SIZE + self.payload.len());
        buf.extend_from_slice(self.msg_id.as_bytes());
        buf.extend_from_slice(&self.chunk_index.to_be_bytes());
        buf.extend_from_slice(&self.total_chunks.to_be_bytes());
        buf.extend_from_slice(&self.payload);
        buf
    }

    /// Deserialize from wire bytes.
    pub fn from_bytes(data: &[u8]) -> Option<Self> {
        if data.len() < Self::HEADER_SIZE {
            return None;
        }
        let msg_id = Uuid::from_bytes(data[0..16].try_into().ok()?);
        let chunk_index = u16::from_be_bytes([data[16], data[17]]);
        let total_chunks = u16::from_be_bytes([data[18], data[19]]);
        let payload = data[Self::HEADER_SIZE..].to_vec();

        Some(Self { msg_id, chunk_index, total_chunks, payload })
    }
}

/// Cumulative acknowledgment for chunks received.
///
/// Wire format: [msg_id:16][chunk_index:2]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChunkAck {
    pub msg_id: Uuid,
    pub chunk_index: u16,
}

impl ChunkAck {
    pub const SIZE: usize = 18;

    pub fn to_bytes(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(Self::SIZE);
        buf.extend_from_slice(self.msg_id.as_bytes());
        buf.extend_from_slice(&self.chunk_index.to_be_bytes());
        buf
    }

    pub fn from_bytes(data: &[u8]) -> Option<Self> {
        if data.len() < Self::SIZE {
            return None;
        }
        let msg_id = Uuid::from_bytes(data[0..16].try_into().ok()?);
        let chunk_index = u16::from_be_bytes([data[16], data[17]]);
        Some(Self { msg_id, chunk_index })
    }
}

/// Tracks the state of an in-progress transfer (used for resumption).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferState {
    pub msg_id: Uuid,
    pub direction: TransferDirection,
    pub last_acked_chunk: u16,
    pub total_chunks: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransferDirection {
    Inbound,
    Outbound,
}

impl TransferState {
    pub fn is_complete(&self) -> bool {
        self.last_acked_chunk + 1 >= self.total_chunks
    }

    pub fn next_chunk_index(&self) -> u16 {
        self.last_acked_chunk + 1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_chunk_split_small_message() {
        let msg_id = Uuid::new_v4();
        let data = vec![0xAA; 100];
        let chunks = Chunk::split(msg_id, &data, 517);

        // max_payload = 517 - 3 - 20 = 494, so 100 bytes fits in 1 chunk
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].chunk_index, 0);
        assert_eq!(chunks[0].total_chunks, 1);
        assert_eq!(chunks[0].payload.len(), 100);
    }

    #[test]
    fn test_chunk_split_large_message() {
        let msg_id = Uuid::new_v4();
        let data = vec![0xBB; 2000];
        let chunks = Chunk::split(msg_id, &data, 517);

        // max_payload = 494, so 2000/494 = 5 chunks (4×494 + 24)
        assert_eq!(chunks.len(), 5);
        for (i, chunk) in chunks.iter().enumerate() {
            assert_eq!(chunk.msg_id, msg_id);
            assert_eq!(chunk.chunk_index, i as u16);
            assert_eq!(chunk.total_chunks, 5);
        }

        // Reassemble
        let reassembled: Vec<u8> = chunks.iter().flat_map(|c| c.payload.iter().copied()).collect();
        assert_eq!(reassembled, data);
    }

    #[test]
    fn test_chunk_wire_roundtrip() {
        let chunk = Chunk {
            msg_id: Uuid::new_v4(),
            chunk_index: 3,
            total_chunks: 10,
            payload: vec![1, 2, 3, 4, 5],
        };

        let bytes = chunk.to_bytes();
        let restored = Chunk::from_bytes(&bytes).unwrap();

        assert_eq!(restored.msg_id, chunk.msg_id);
        assert_eq!(restored.chunk_index, 3);
        assert_eq!(restored.total_chunks, 10);
        assert_eq!(restored.payload, vec![1, 2, 3, 4, 5]);
    }

    #[test]
    fn test_ack_roundtrip() {
        let ack = ChunkAck {
            msg_id: Uuid::new_v4(),
            chunk_index: 7,
        };

        let bytes = ack.to_bytes();
        let restored = ChunkAck::from_bytes(&bytes).unwrap();

        assert_eq!(restored.msg_id, ack.msg_id);
        assert_eq!(restored.chunk_index, 7);
    }

    #[test]
    fn test_transfer_state_completion() {
        let state = TransferState {
            msg_id: Uuid::new_v4(),
            direction: TransferDirection::Inbound,
            last_acked_chunk: 4,
            total_chunks: 5,
        };
        assert!(state.is_complete());

        let state2 = TransferState {
            msg_id: Uuid::new_v4(),
            direction: TransferDirection::Outbound,
            last_acked_chunk: 2,
            total_chunks: 5,
        };
        assert!(!state2.is_complete());
        assert_eq!(state2.next_chunk_index(), 3);
    }
}
