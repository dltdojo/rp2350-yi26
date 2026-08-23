// SPDX-License-Identifier: Apache-2.0
//! Backend C: PufReconstructedBackend (exp181/exp182 SRAM PUF Key Backend)

use crate::contract::{KeyBackend, KeyError};
use hmac::{Mac, SimpleHmac};
use p256::ecdsa::SigningKey;
use sha2::Sha256;

pub struct PufReconstructedBackend {
    master_key: Option<[u8; 32]>,
}

impl PufReconstructedBackend {
    pub const fn new() -> Self {
        Self { master_key: None }
    }

    pub fn set_reconstructed_key(&mut self, key: [u8; 32]) {
        self.master_key = Some(key);
    }
}

impl KeyBackend for PufReconstructedBackend {
    fn name(&self) -> &'static str {
        "PufReconstructed (SRAM Startup PUF - exp181/182)"
    }

    fn derive_credential_key(
        &mut self,
        rp_id_hash: &[u8; 32],
        cred_random: &[u8; 32],
        counter: u32,
    ) -> Result<SigningKey, KeyError> {
        let key_bytes = self.master_key.as_ref().ok_or(KeyError::Unprovisioned)?;
        let mut mac = SimpleHmac::<Sha256>::new_from_slice(key_bytes)
            .map_err(|_| KeyError::HardwareFault)?;
        mac.update(b"rp2350-fido-key-puf");
        mac.update(&counter.to_be_bytes());
        mac.update(cred_random);
        mac.update(rp_id_hash);
        let scalar_bytes = mac.finalize().into_bytes();
        SigningKey::from_slice(&scalar_bytes).map_err(|_| KeyError::InvalidKey)
    }

    fn sign_credential_id(
        &mut self,
        cred_random: &[u8; 32],
        rp_id_hash: &[u8; 32],
    ) -> Result<[u8; 16], KeyError> {
        let key_bytes = self.master_key.as_ref().ok_or(KeyError::Unprovisioned)?;
        let mut mac = SimpleHmac::<Sha256>::new_from_slice(key_bytes)
            .map_err(|_| KeyError::HardwareFault)?;
        mac.update(b"rp2350-fido-id-puf");
        mac.update(cred_random);
        mac.update(rp_id_hash);
        let full_tag = mac.finalize().into_bytes();
        let mut tag16 = [0u8; 16];
        tag16.copy_from_slice(&full_tag[..16]);
        Ok(tag16)
    }

    fn wipe(&mut self) {
        // Option to clear in-memory key on demand
    }
}
