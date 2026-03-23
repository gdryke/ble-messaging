use sha2::{Sha256, Digest};
use x25519_dalek::{StaticSecret, PublicKey};
use rand::rngs::OsRng;
use serde::{Serialize, Deserialize};
use std::fmt;

/// 16-byte device identity derived from the public key.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct DeviceId(pub [u8; 16]);

impl DeviceId {
    /// Derive a DeviceId from an X25519 public key: SHA-256(pubkey)[0..16]
    pub fn from_public_key(public_key: &PublicKey) -> Self {
        let hash = Sha256::digest(public_key.as_bytes());
        let mut id = [0u8; 16];
        id.copy_from_slice(&hash[..16]);
        DeviceId(id)
    }

    pub fn as_bytes(&self) -> &[u8; 16] {
        &self.0
    }
}

impl fmt::Debug for DeviceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for byte in &self.0 {
            write!(f, "{byte:02x}")?;
        }
        Ok(())
    }
}

impl fmt::Display for DeviceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for byte in &self.0 {
            write!(f, "{byte:02x}")?;
        }
        Ok(())
    }
}

impl PartialOrd for DeviceId {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for DeviceId {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.0.cmp(&other.0)
    }
}

/// Long-term identity key pair for a device.
pub struct Identity {
    secret: StaticSecret,
    public: PublicKey,
    device_id: DeviceId,
}

impl Identity {
    /// Generate a new random identity.
    pub fn generate() -> Self {
        let secret = StaticSecret::random_from_rng(OsRng);
        let public = PublicKey::from(&secret);
        let device_id = DeviceId::from_public_key(&public);
        Self { secret, public, device_id }
    }

    /// Restore identity from a stored secret key.
    pub fn from_secret_bytes(bytes: &[u8; 32]) -> Self {
        let secret = StaticSecret::from(*bytes);
        let public = PublicKey::from(&secret);
        let device_id = DeviceId::from_public_key(&public);
        Self { secret, public, device_id }
    }

    pub fn secret_bytes(&self) -> [u8; 32] {
        // StaticSecret doesn't expose bytes directly in newer versions,
        // but we store the original bytes at creation time.
        // For now, we reconstruct from the diffie_hellman with a known point.
        // TODO: Store raw bytes alongside secret for export
        self.secret.to_bytes()
    }

    pub fn public_key(&self) -> &PublicKey {
        &self.public
    }

    pub fn public_key_bytes(&self) -> [u8; 32] {
        self.public.to_bytes()
    }

    pub fn device_id(&self) -> &DeviceId {
        &self.device_id
    }

    /// Perform X25519 Diffie-Hellman with a peer's public key.
    pub fn diffie_hellman(&self, peer_public: &PublicKey) -> [u8; 32] {
        self.secret.diffie_hellman(peer_public).to_bytes()
    }
}

/// Peer info stored in the local database.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Peer {
    pub device_id: DeviceId,
    pub public_key: [u8; 32],
    pub display_name: String,
    pub last_seen: Option<i64>,
}

impl Peer {
    pub fn new(public_key: [u8; 32], display_name: String) -> Self {
        let pk = PublicKey::from(public_key);
        let device_id = DeviceId::from_public_key(&pk);
        Self {
            device_id,
            public_key,
            display_name,
            last_seen: None,
        }
    }

    pub fn x25519_public_key(&self) -> PublicKey {
        PublicKey::from(self.public_key)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_identity_generation() {
        let id = Identity::generate();
        assert_eq!(id.device_id(), &DeviceId::from_public_key(id.public_key()));
    }

    #[test]
    fn test_identity_roundtrip() {
        let id1 = Identity::generate();
        let bytes = id1.secret_bytes();
        let id2 = Identity::from_secret_bytes(&bytes);
        assert_eq!(id1.public_key_bytes(), id2.public_key_bytes());
        assert_eq!(id1.device_id(), id2.device_id());
    }

    #[test]
    fn test_diffie_hellman_shared_secret() {
        let alice = Identity::generate();
        let bob = Identity::generate();

        let shared_ab = alice.diffie_hellman(bob.public_key());
        let shared_ba = bob.diffie_hellman(alice.public_key());
        assert_eq!(shared_ab, shared_ba);
    }

    #[test]
    fn test_device_id_ordering() {
        let id1 = DeviceId([0u8; 16]);
        let id2 = DeviceId([1u8; 16]);
        assert!(id1 < id2);
    }
}
