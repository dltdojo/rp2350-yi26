// SPDX-License-Identifier: Apache-2.0
//! Backend D: OtpSimulatedBackend (OTP Key Storage & Secure Lock Simulation)

use crate::contract::{KeyBackend, KeyError};
use hmac::{Mac, SimpleHmac};
use p256::ecdsa::SigningKey;
use sha2::Sha256;

pub struct OtpSimulatedBackend {
    /// Simulated or real OTP-derived master key
    otp_seed: [u8; 32],
    secure_lock_active: bool,
}

impl OtpSimulatedBackend {
    pub const fn new() -> Self {
        Self {
            otp_seed: [0x5A; 32], // Simulated OTP row 0x000 content
            secure_lock_active: false,
        }
    }

    /// Update with actual OTP row data if read from hardware
    pub fn set_otp_row_data(&mut self, row_bytes: [u8; 32], secure_lock_enabled: bool) {
        self.otp_seed = row_bytes;
        self.secure_lock_active = secure_lock_enabled;
    }

    pub fn is_secure_lock_active(&self) -> bool {
        self.secure_lock_active
    }
}

impl KeyBackend for OtpSimulatedBackend {
    fn name(&self) -> &'static str {
        "OtpSimulated (RP2350 OTP Row 0x000 + Secure Lock)"
    }

    fn derive_credential_key(
        &mut self,
        rp_id_hash: &[u8; 32],
        cred_random: &[u8; 32],
        counter: u32,
    ) -> Result<SigningKey, KeyError> {
        let mut mac = SimpleHmac::<Sha256>::new_from_slice(&self.otp_seed)
            .map_err(|_| KeyError::HardwareFault)?;
        mac.update(b"rp2350-fido-key-otp-sim");
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
        let mut mac = SimpleHmac::<Sha256>::new_from_slice(&self.otp_seed)
            .map_err(|_| KeyError::HardwareFault)?;
        mac.update(b"rp2350-fido-id-otp-sim");
        mac.update(cred_random);
        mac.update(rp_id_hash);
        let full_tag = mac.finalize().into_bytes();
        let mut tag16 = [0u8; 16];
        tag16.copy_from_slice(&full_tag[..16]);
        Ok(tag16)
    }

    fn wipe(&mut self) {
        // Transient buffers wiped
    }
}
