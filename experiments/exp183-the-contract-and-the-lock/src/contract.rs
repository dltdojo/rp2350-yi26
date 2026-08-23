// SPDX-License-Identifier: Apache-2.0
//! # Hardware Abstraction Contract for WebAuthn / FIDO2 Authenticator
//!
//! Unlike monolithic implementations where the hardware keys and crypto logic
//! are entangled directly in the protocol loops, this contract decouples
//! the CTAP2 WebAuthn engine from the underlying secret storage, persistence,
//! and user presence mechanisms.

use p256::ecdsa::{signature::Signer, Signature, SigningKey};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyError {
    Unprovisioned,
    HardwareFault,
    InvalidKey,
}

/// Abstract contract for where device secrets live and how keys are derived/signed.
pub trait KeyBackend {
    /// Human-readable identifier of this backend implementation.
    fn name(&self) -> &'static str;

    /// Derive a P-256 private key for a given relying party and credential random nonce.
    fn derive_credential_key(
        &mut self,
        rp_id_hash: &[u8; 32],
        cred_random: &[u8; 32],
        counter: u32,
    ) -> Result<SigningKey, KeyError>;

    /// Compute an authentication tag / HMAC over the credential ID to prove authenticity.
    fn sign_credential_id(
        &mut self,
        cred_random: &[u8; 32],
        rp_id_hash: &[u8; 32],
    ) -> Result<[u8; 16], KeyError>;

    /// Verify a credential ID tag in constant time.
    fn verify_credential_id(
        &mut self,
        cred_random: &[u8; 32],
        rp_id_hash: &[u8; 32],
        tag: &[u8; 16],
    ) -> bool {
        if let Ok(expected) = self.sign_credential_id(cred_random, rp_id_hash) {
            let mut diff = 0u8;
            for i in 0..16 {
                diff |= expected[i] ^ tag[i];
            }
            diff == 0
        } else {
            false
        }
    }

    /// Sign a digest with the derived signing key.
    fn sign(&mut self, key: &SigningKey, digest: &[u8; 32]) -> Result<Signature, KeyError> {
        Ok(key.sign(digest))
    }

    /// Zero-out / wipe any transient key buffers in memory.
    fn wipe(&mut self) {}
}

/// Abstract contract for persistent storage (e.g. signature counter, resident keys).
pub trait PersistStore {
    fn get_signature_counter(&self) -> u32;
    fn increment_counter(&mut self) -> u32;
}

/// Simple in-memory atomic signature counter.
pub struct MemoryPersistStore {
    counter: u32,
}

impl MemoryPersistStore {
    pub const fn new(initial: u32) -> Self {
        Self { counter: initial }
    }
}

impl PersistStore for MemoryPersistStore {
    fn get_signature_counter(&self) -> u32 {
        self.counter
    }

    fn increment_counter(&mut self) -> u32 {
        self.counter = self.counter.wrapping_add(1);
        self.counter
    }
}

impl<P: PersistStore> PersistStore for &mut P {
    fn get_signature_counter(&self) -> u32 {
        (**self).get_signature_counter()
    }

    fn increment_counter(&mut self) -> u32 {
        (**self).increment_counter()
    }
}
