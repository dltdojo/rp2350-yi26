// SPDX-License-Identifier: Apache-2.0
//! Backend A: TestKeyBackend (exp174 compiled-in test key)

use crate::contract::{KeyBackend, KeyError};
use hmac::{Mac, SimpleHmac};
use p256::ecdsa::SigningKey;
use sha2::Sha256;

pub const COMPILED_IN_TEST_KEY: [u8; 32] = *b"rp2350-yi26-test-key-0123456789\0";

pub struct TestKeyBackend {
    secret: [u8; 32],
}

impl TestKeyBackend {
    pub const fn new() -> Self {
        Self {
            secret: COMPILED_IN_TEST_KEY,
        }
    }
}

impl KeyBackend for TestKeyBackend {
    fn name(&self) -> &'static str {
        "TestKey (exp174 static constant)"
    }

    fn derive_credential_key(
        &mut self,
        rp_id_hash: &[u8; 32],
        cred_random: &[u8; 32],
        counter: u32,
    ) -> Result<SigningKey, KeyError> {
        let mut mac = SimpleHmac::<Sha256>::new_from_slice(&self.secret)
            .map_err(|_| KeyError::HardwareFault)?;
        mac.update(b"rp2350-fido-key-v1");
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
        let mut mac = SimpleHmac::<Sha256>::new_from_slice(&self.secret)
            .map_err(|_| KeyError::HardwareFault)?;
        mac.update(b"rp2350-fido-id-v1");
        mac.update(cred_random);
        mac.update(rp_id_hash);
        let full_tag = mac.finalize().into_bytes();
        let mut tag16 = [0u8; 16];
        tag16.copy_from_slice(&full_tag[..16]);
        Ok(tag16)
    }

    fn wipe(&mut self) {
        // Test key is static in flash, wipe is a no-op
    }
}
