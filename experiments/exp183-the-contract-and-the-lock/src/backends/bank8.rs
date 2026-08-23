// SPDX-License-Identifier: Apache-2.0
//! Backend B: Bank8SecureBackend (exp159 isolated SRAM Bank 8 with wipe)

use crate::contract::{KeyBackend, KeyError};
use hmac::{Mac, SimpleHmac};
use p256::ecdsa::SigningKey;
use sha2::Sha256;

/// Bank 8 address on RP2350 (4 KB dedicated non-interleaved SRAM).
const BANK8_BASE: usize = 0x2008_0000;

pub struct Bank8SecureBackend {
    /// In this demonstration backend, dynamic keys are held exclusively in Bank 8
    configured: bool,
}

impl Bank8SecureBackend {
    pub const fn new() -> Self {
        Self { configured: false }
    }

    /// Load or initialize the master key directly into Bank 8 SRAM.
    pub fn init(&mut self, seed: &[u8; 32]) {
        let ptr = BANK8_BASE as *mut u8;
        unsafe {
            for (i, &b) in seed.iter().enumerate() {
                core::ptr::write_volatile(ptr.add(i), b);
            }
        }
        self.configured = true;
    }

    fn read_seed(&self) -> [u8; 32] {
        let mut buf = [0u8; 32];
        let ptr = BANK8_BASE as *const u8;
        unsafe {
            for (i, b) in buf.iter_mut().enumerate() {
                *b = core::ptr::read_volatile(ptr.add(i));
            }
        }
        buf
    }
}

impl KeyBackend for Bank8SecureBackend {
    fn name(&self) -> &'static str {
        "Bank8Secure (Isolated SRAM Bank 8 + Wipe)"
    }

    fn derive_credential_key(
        &mut self,
        rp_id_hash: &[u8; 32],
        cred_random: &[u8; 32],
        counter: u32,
    ) -> Result<SigningKey, KeyError> {
        let seed = self.read_seed();
        let mut mac = SimpleHmac::<Sha256>::new_from_slice(&seed)
            .map_err(|_| KeyError::HardwareFault)?;
        mac.update(b"rp2350-fido-key-bank8");
        mac.update(&counter.to_be_bytes());
        mac.update(cred_random);
        mac.update(rp_id_hash);
        let scalar_bytes = mac.finalize().into_bytes();
        let key = SigningKey::from_slice(&scalar_bytes).map_err(|_| KeyError::InvalidKey)?;
        self.wipe();
        Ok(key)
    }

    fn sign_credential_id(
        &mut self,
        cred_random: &[u8; 32],
        rp_id_hash: &[u8; 32],
    ) -> Result<[u8; 16], KeyError> {
        let seed = self.read_seed();
        let mut mac = SimpleHmac::<Sha256>::new_from_slice(&seed)
            .map_err(|_| KeyError::HardwareFault)?;
        mac.update(b"rp2350-fido-id-bank8");
        mac.update(cred_random);
        mac.update(rp_id_hash);
        let full_tag = mac.finalize().into_bytes();
        let mut tag16 = [0u8; 16];
        tag16.copy_from_slice(&full_tag[..16]);
        self.wipe();
        Ok(tag16)
    }

    fn wipe(&mut self) {
        // Zero-out working buffers in Bank 8
        let ptr = (BANK8_BASE + 64) as *mut u8;
        unsafe {
            for i in 0..256 {
                core::ptr::write_volatile(ptr.add(i), 0);
            }
        }
    }
}
