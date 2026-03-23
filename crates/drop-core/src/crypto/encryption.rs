use chacha20poly1305::{
    XChaCha20Poly1305, XNonce,
    aead::{Aead, KeyInit},
};
use hkdf::Hkdf;
use sha2::Sha256;
use rand::RngCore;
use thiserror::Error;

use crate::crypto::identity::DeviceId;

#[derive(Debug, Error)]
pub enum CryptoError {
    #[error("encryption failed")]
    EncryptionFailed,
    #[error("decryption failed — invalid key or corrupted data")]
    DecryptionFailed,
    #[error("invalid nonce length")]
    InvalidNonce,
}

/// Derive a symmetric encryption key from a X25519 shared secret using HKDF-SHA256.
///
/// The salt is `sorted(sender_id, recipient_id)` to ensure both peers derive
/// the same key regardless of direction.
pub fn derive_message_key(
    shared_secret: &[u8; 32],
    device_a: &DeviceId,
    device_b: &DeviceId,
) -> [u8; 32] {
    // Sort device IDs lexicographically for deterministic salt
    let (first, second) = if device_a <= device_b {
        (device_a.as_bytes(), device_b.as_bytes())
    } else {
        (device_b.as_bytes(), device_a.as_bytes())
    };

    let mut salt = [0u8; 32];
    salt[..16].copy_from_slice(first);
    salt[16..].copy_from_slice(second);

    let hk = Hkdf::<Sha256>::new(Some(&salt), shared_secret);
    let mut key = [0u8; 32];
    hk.expand(b"drop-v1-message", &mut key)
        .expect("HKDF-SHA256 expand should not fail for 32-byte output");
    key
}

/// Encrypt a plaintext payload using XChaCha20-Poly1305.
/// Returns `(nonce, ciphertext)` where ciphertext includes the 16-byte auth tag.
pub fn encrypt(key: &[u8; 32], plaintext: &[u8]) -> Result<([u8; 24], Vec<u8>), CryptoError> {
    let cipher = XChaCha20Poly1305::new(key.into());

    let mut nonce_bytes = [0u8; 24];
    rand::thread_rng().fill_bytes(&mut nonce_bytes);
    let nonce = XNonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|_| CryptoError::EncryptionFailed)?;

    Ok((nonce_bytes, ciphertext))
}

/// Decrypt a ciphertext using XChaCha20-Poly1305.
pub fn decrypt(key: &[u8; 32], nonce: &[u8; 24], ciphertext: &[u8]) -> Result<Vec<u8>, CryptoError> {
    let cipher = XChaCha20Poly1305::new(key.into());
    let nonce = XNonce::from_slice(nonce);

    cipher
        .decrypt(nonce, ciphertext)
        .map_err(|_| CryptoError::DecryptionFailed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::identity::Identity;

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let alice = Identity::generate();
        let bob = Identity::generate();

        let shared = alice.diffie_hellman(bob.public_key());
        let key = derive_message_key(&shared, alice.device_id(), bob.device_id());

        let plaintext = b"Hello from Alice!";
        let (nonce, ciphertext) = encrypt(&key, plaintext).unwrap();
        let decrypted = decrypt(&key, &nonce, &ciphertext).unwrap();

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_key_derivation_is_symmetric() {
        let alice = Identity::generate();
        let bob = Identity::generate();

        let shared_ab = alice.diffie_hellman(bob.public_key());
        let shared_ba = bob.diffie_hellman(alice.public_key());

        let key_ab = derive_message_key(&shared_ab, alice.device_id(), bob.device_id());
        let key_ba = derive_message_key(&shared_ba, bob.device_id(), alice.device_id());

        assert_eq!(key_ab, key_ba);
    }

    #[test]
    fn test_decrypt_with_wrong_key_fails() {
        let key = [1u8; 32];
        let wrong_key = [2u8; 32];

        let (nonce, ciphertext) = encrypt(&key, b"secret").unwrap();
        let result = decrypt(&wrong_key, &nonce, &ciphertext);

        assert!(result.is_err());
    }

    #[test]
    fn test_unique_nonces() {
        let key = [1u8; 32];
        let (nonce1, _) = encrypt(&key, b"msg1").unwrap();
        let (nonce2, _) = encrypt(&key, b"msg2").unwrap();
        assert_ne!(nonce1, nonce2);
    }
}
