use std::io::Cursor;
use murmur3::murmur3_32;

use crate::crypto::identity::DeviceId;

/// 64-bit (8-byte) Bloom filter for advertising payloads.
///
/// Encodes device_ids of peers with pending outbound messages. Scanners check
/// if their own device_id is in the filter to decide whether to connect.
///
/// Parameters: 64 bits, 3 hash functions (MurmurHash3 with seeds 0, 1, 2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BloomFilter {
    bits: u64,
}

impl BloomFilter {
    const NUM_HASHES: u32 = 3;
    const NUM_BITS: u32 = 64;

    /// Create an empty Bloom filter (no pending messages).
    pub fn empty() -> Self {
        Self { bits: 0 }
    }

    /// Create a Bloom filter from raw bytes (8 bytes, big-endian).
    pub fn from_bytes(bytes: &[u8; 8]) -> Self {
        Self {
            bits: u64::from_be_bytes(*bytes),
        }
    }

    /// Serialize to 8 bytes (big-endian).
    pub fn to_bytes(&self) -> [u8; 8] {
        self.bits.to_be_bytes()
    }

    /// Returns true if the filter is empty (no items inserted).
    pub fn is_empty(&self) -> bool {
        self.bits == 0
    }

    /// Insert a device_id into the filter.
    pub fn insert(&mut self, device_id: &DeviceId) {
        for seed in 0..Self::NUM_HASHES {
            let bit_index = self.hash(device_id, seed);
            self.bits |= 1u64 << bit_index;
        }
    }

    /// Check if a device_id might be in the filter.
    /// Returns false = definitely not present, true = possibly present.
    pub fn maybe_contains(&self, device_id: &DeviceId) -> bool {
        for seed in 0..Self::NUM_HASHES {
            let bit_index = self.hash(device_id, seed);
            if self.bits & (1u64 << bit_index) == 0 {
                return false;
            }
        }
        true
    }

    fn hash(&self, device_id: &DeviceId, seed: u32) -> u32 {
        let mut cursor = Cursor::new(device_id.as_bytes());
        let h = murmur3_32(&mut cursor, seed).unwrap_or(0);
        h % Self::NUM_BITS
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::identity::Identity;

    #[test]
    fn test_empty_filter() {
        let filter = BloomFilter::empty();
        assert!(filter.is_empty());
        assert_eq!(filter.to_bytes(), [0u8; 8]);
    }

    #[test]
    fn test_insert_and_check() {
        let id = Identity::generate();
        let mut filter = BloomFilter::empty();
        filter.insert(id.device_id());

        assert!(!filter.is_empty());
        assert!(filter.maybe_contains(id.device_id()));
    }

    #[test]
    fn test_false_negative_impossible() {
        // Insert many IDs and verify all are found
        let mut filter = BloomFilter::empty();
        let identities: Vec<_> = (0..10).map(|_| Identity::generate()).collect();

        for id in &identities {
            filter.insert(id.device_id());
        }

        for id in &identities {
            assert!(
                filter.maybe_contains(id.device_id()),
                "bloom filter must not produce false negatives"
            );
        }
    }

    #[test]
    fn test_unknown_id_usually_not_found() {
        let mut filter = BloomFilter::empty();
        let known = Identity::generate();
        filter.insert(known.device_id());

        // Test with many unknown IDs — most should not match
        let mut false_positives = 0;
        let trials = 1000;
        for _ in 0..trials {
            let unknown = Identity::generate();
            if filter.maybe_contains(unknown.device_id()) {
                false_positives += 1;
            }
        }

        // With 1 item in a 64-bit filter and 3 hashes, FP rate should be very low (~0.004%)
        assert!(
            false_positives < 50,
            "false positive rate too high: {false_positives}/{trials}"
        );
    }

    #[test]
    fn test_bytes_roundtrip() {
        let mut filter = BloomFilter::empty();
        let id = Identity::generate();
        filter.insert(id.device_id());

        let bytes = filter.to_bytes();
        let restored = BloomFilter::from_bytes(&bytes);

        assert_eq!(filter, restored);
        assert!(restored.maybe_contains(id.device_id()));
    }
}
