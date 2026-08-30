// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 rp2350-yi26 contributors
//! # exp189 — the same salt twice
//!
//! CTAP 2.1 Discoverable Credentials (Passkey rk) & Credential Management (credMgmt):
//! - Options: { rk: true, credMgmt: true, uv: true, clientPin: bool, pinUvAuthToken: true }
//! - On-device non-volatile resident key store for 16 passkeys
//! - Username-less 1-Click Passkey assertion (empty allowList auto-lookup returning UserEntity)
//! - authenticatorCredentialManagement (0x0A): getCredsMetadata, enumerateRPs, enumerateCredentials, deleteCredential
//! - Full PIN Protocol 1 & authenticatorReset integration

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicBool, AtomicPtr, AtomicU32, AtomicU8, Ordering};

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_rp::bind_interrupts;
use embassy_rp::flash::{Blocking, Flash};
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Duration, Instant, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::class::hid::{Config as HidConfig, HidReaderWriter, State as HidState};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
// The panic handler, the hard-fault handler and the watchdog are
// `crates/lifeline`'s. This firmware had its own, written after a silent one
// cost a trip to a bench; one component means the next firmware cannot forget.
use rp2350_linker as _;
use static_cell::StaticCell;
use cbor::{Item, ReadError, Reader};
use hmac::{Mac, SimpleHmac};
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use p256::elliptic_curve::sec1::{FromEncodedPoint, ToEncodedPoint};
use p256::{PublicKey, SecretKey};
use aes::cipher::{BlockDecrypt, BlockEncrypt, KeyInit};
use aes::Aes256;
use embassy_rp::peripherals::TRNG;
use embassy_rp::trng::{Config as TrngConfig, Trng};
use sha2::{Digest, Sha256};
// Everything the transport owns comes from the crate rather than being spelled
// again here. exp189's own copies were not all the same as the specification's:
// its transaction timeout was 1500 ms where CTAP-HID names 750, and exp194
// measured what the difference costs a client that has lost track.
use ctap_hid::board::{Waited, Wire as WireOf};
use ctap_hid::{
    Cid, CTAPHID_CBOR, CTAPHID_PING, ERR_INVALID_CMD, INIT_PAYLOAD, MAX_MESSAGE,
};
/// The transport, with this firmware's driver filled in.
type Wire = WireOf<'static, usb_reboot::UsbDriver>;

use usb_log::log;

include!(concat!(env!("OUT_DIR"), "/exp189_config.rs"));

/// exp171's test key, and it spells what it is: *not a secret. this is a test
/// key*. **Compiled in only on the `constant` arm** — a secret in an image is a
/// secret anybody with the image has, whether the firmware reaches for it or
/// not, and the `bank8` arm exists to have no such bytes to find.
#[cfg(not(bank8))]
const DEVICE_SECRET: [u8; 32] = [
    0x6e, 0x6f, 0x74, 0x20, 0x61, 0x20, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74, 0x2e, 0x20, 0x74, 0x68,
    0x69, 0x73, 0x20, 0x69, 0x73, 0x20, 0x61, 0x20, 0x74, 0x65, 0x73, 0x74, 0x20, 0x6b, 0x65, 0x79,
];

/// Bank 8, and the record that was never the key.
///
/// The arithmetic is [`crates/fuzzy-commitment`](../../crates/fuzzy-commitment/),
/// lifted out of exp182 so this experiment could have it without a copy. What
/// is here is the half that is hardware: the address, the flash offset, and the
/// reads that touch them. exp182 owns the same two numbers, and a record written
/// by either is readable by the other — which is how this arm gets a key that
/// was enrolled before this firmware existed.
const WINDOW: usize = 0x2008_0000;
const HELPER_OFFSET: u32 = 0x30_0000;
const PUF_FLASH_SIZE: usize = 4 * 1024 * 1024;
const XIP_BASE: usize = 0x1000_0000;
const SECTOR: usize = 4096;

static SECRET_CELL: StaticCell<[u8; 32]> = StaticCell::new();
static SECRET: AtomicPtr<[u8; 32]> = AtomicPtr::new(core::ptr::null_mut());

/// The secret this boot is actually using, or `None` if it has none.
///
/// On the `constant` arm it points at [`DEVICE_SECRET`], which exp175's forgery
/// finds in the image. On `bank8` it points at a key reconstructed from SRAM,
/// which is in no image at all — and a board that has just been flashed has
/// **none**, because flashing zeroes the window the key comes from. That third
/// state is not a failure to hide: it is exp182's cost, and it is why this
/// function returns an `Option` rather than a key.
fn device_secret() -> Option<&'static [u8; 32]> {
    let p = SECRET.load(Ordering::Relaxed);
    if p.is_null() {
        None
    } else {
        // Safety: written once in `main`, from a `StaticCell`, before any task
        // that reads it has been spawned; never cleared, never rewritten.
        Some(unsafe { &*p })
    }
}

/// Thirty-two zero bytes, and they are not a fallback secret.
///
/// `main` does not start the authenticator without a real one, so this is
/// unreachable — and it is a *visible* nothing rather than a panic, because
/// exp183 spent three trips to a bench on a silent one.
static NO_SECRET: [u8; 32] = [0u8; 32];

/// The secret every keyed operation uses.
fn secret_bytes() -> &'static [u8; 32] {
    device_secret().unwrap_or(&NO_SECRET)
}

fn puf_read_record() -> Option<fuzzy_commitment::Record> {
    let at = (XIP_BASE + HELPER_OFFSET as usize) as *const fuzzy_commitment::Record;
    // Safety: a fixed address in this board's own flash, read only, and nothing
    // is believed until `usable()` says the magic and the parameters match.
    let r = unsafe { core::ptr::read_volatile(at) };
    if r.usable() {
        Some(r)
    } else {
        None
    }
}

const VERSIONS: [&str; 3] = ["U2F_V2", "FIDO_2_0", "FIDO_2_1"];

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    TRNG_IRQ => embassy_rp::trng::InterruptHandler<TRNG>;
});

/// The defaults, named once so nothing here and the watchdog can disagree.
const LIFELINE: lifeline::Config = lifeline::Config {
    boot_us: lifeline::DEFAULT_BOOT_US,
    run_us: lifeline::DEFAULT_RUN_US,
    escape_after: lifeline::DEFAULT_ESCAPE_AFTER,
};

const PACKET: usize = 64;
const KEEPALIVE_INTERVAL: Duration = Duration::from_millis(100);
const PRESENCE_POLL: Duration = Duration::from_millis(PRESENCE_POLL_MS);

const CTAPHID_ERROR: u8 = 0x3f;


#[rustfmt::skip]
const CTAPHID_REPORT_DESCRIPTOR: &[u8] = &[
    0x06, 0xd0, 0xf1, // USAGE_PAGE (FIDO Alliance)
    0x09, 0x01,       // USAGE (U2F HID Authenticator Device)
    0xa1, 0x01,       // COLLECTION (Application)
    0x09, 0x20,       //   USAGE (Data In)
    0x15, 0x00,       //   LOGICAL_MINIMUM (0)
    0x26, 0xff, 0x00, //   LOGICAL_MAXIMUM (255)
    0x75, 0x08,       //   REPORT_SIZE (8)
    0x95, 0x40,       //   REPORT_COUNT (64)
    0x81, 0x02,       //   INPUT (Data,Var,Abs)
    0x09, 0x21,       //   USAGE (Data Out)
    0x15, 0x00,       //   LOGICAL_MINIMUM (0)
    0x26, 0xff, 0x00, //   LOGICAL_MAXIMUM (255)
    0x75, 0x08,       //   REPORT_SIZE (8)
    0x95, 0x40,       //   REPORT_COUNT (64)
    0x91, 0x02,       //   OUTPUT (Data,Var,Abs)
    0xc0,             // END_COLLECTION
];


const CAPABILITIES: u8 = 0x04 | 0x08; // CAPABILITY_CBOR | CAPABILITY_NMSG

const CTAP2_OK: u8 = 0x00;
const CTAP1_ERR_INVALID_COMMAND: u8 = 0x01;
const CTAP1_ERR_INVALID_LENGTH: u8 = 0x03;
const CTAP2_ERR_INVALID_CBOR: u8 = 0x12;
const CTAP2_ERR_MISSING_PARAMETER: u8 = 0x14;
const CTAP2_ERR_UNSUPPORTED_ALGORITHM: u8 = 0x26;
const CTAP2_ERR_OPERATION_DENIED: u8 = 0x27;
const CTAP2_ERR_UNSUPPORTED_OPTION: u8 = 0x2B;
const CTAP2_ERR_KEEPALIVE_CANCEL: u8 = 0x2D;
const CTAP2_ERR_NO_CREDENTIALS: u8 = 0x2E;
const CTAP2_ERR_NOT_ALLOWED: u8 = 0x30;
const CTAP2_ERR_PIN_INVALID: u8 = 0x31;
const CTAP2_ERR_PIN_AUTH_INVALID: u8 = 0x32;
const CTAP2_ERR_PIN_BLOCKED: u8 = 0x34;
const CTAP2_ERR_PIN_NOT_SET: u8 = 0x35;
const CTAP2_ERR_PIN_AUTH_BLOCKED: u8 = 0x36;
const CTAP2_ERR_UNAUTHORIZED_PERMISSION: u8 = 0x3F;
/// The specification's code for an extension that could not be satisfied.
/// It exists here as its own number for exp173's and exp182's reason: a
/// refusal that shares a byte with another refusal costs an experiment.
const CTAP2_ERR_EXTENSION_FIRST: u8 = 0xE1;
/// This board has no identity to key anything with.
///
/// Its own number, for exp173's and exp182's reason. On the `bank8` arm a board
/// straight from `yi26 flash` is in exactly this state — the SRAM the key comes
/// from was zeroed by the flashing path — and "the power has not been away yet"
/// must not arrive wearing the same byte as "nobody pressed the button".
const CTAP2_ERR_NO_SECRET: u8 = 0xE2;

const COSE_ES256: i64 = -7;
/// ECDH-ES + HKDF-256, the algorithm a CTAP key-agreement COSE_Key must name.
const COSE_ECDH_ES_HKDF_256: i64 = -25;
const USER_PRESENCE_TIMEOUT: Duration = Duration::from_millis(TIMEOUT_MS);

const AUTHENTICATOR_MAKE_CREDENTIAL: u8 = 0x01;
const AUTHENTICATOR_GET_ASSERTION: u8 = 0x02;
const AUTHENTICATOR_GET_INFO: u8 = 0x04;
const AUTHENTICATOR_CLIENT_PIN: u8 = 0x06;
const AUTHENTICATOR_RESET: u8 = 0x07;
const AUTHENTICATOR_CREDENTIAL_MANAGEMENT: u8 = 0x0A;
/// CTAP 2.1 `authenticatorSelection`. One byte, no parameters, and the thing a
/// browser sends to ask *which* of the attached keys the person means: light
/// up, and whichever one is touched wins.
///
/// exp192 found it missing. Nothing in this repository had ever sent it —
/// `libfido2` does not — so a board that answered every question the CLI asked
/// could not get a browser as far as lighting its LED. Behind a flag, because
/// exp189's own transcripts were taken by a client that never asks.
const AUTHENTICATOR_SELECTION: u8 = 0x0B;

const AAGUID: [u8; 16] = [0; 16];
const TRNG_SAMPLE_COUNT: u32 = 1000;
const PRODUCT: &str = "exp189 the same salt twice";
const CONTROL_BUF_LEN: usize = 128;

const PACE: Duration = Duration::from_millis(0);

static PACKETS_IN: AtomicU32 = AtomicU32::new(0);
static MESSAGES: AtomicU32 = AtomicU32::new(0);
static ERRORS: AtomicU32 = AtomicU32::new(0);
/// Three states, and the vocabulary is [exp182](../exp182-where-the-wrapping-key-comes-from/)'s
/// on purpose: somebody who has watched one of these boards should not have to
/// learn a second language for the other.
///
/// This experiment shipped with **two** — a boolean that meant *press me* — and
/// then asked a person to pull a cable by printing a sentence to a terminal
/// nobody was sitting at. exp182's own comment had already said what that costs:
/// *this one went back to words and cost a round trip to find out.* Reading it
/// before writing this would have been free.
const LED_IDLE: u8 = 0;
const LED_PRESS_NOW: u8 = 1;
const LED_UNPROVISIONED: u8 = 2;
static LED_MODE: AtomicU8 = AtomicU8::new(LED_IDLE);

/// Back to whatever this board's resting state actually is.
///
/// Not unconditionally `LED_IDLE`: on an unprovisioned board the resting state
/// is *unplug me*, and a press window that ended must not paint over it.
fn led_rest() {
    LED_MODE.store(
        if device_secret().is_some() { LED_IDLE } else { LED_UNPROVISIONED },
        Ordering::Relaxed,
    );
}




fn status_for(e: ReadError) -> u8 {
    match e {
        ReadError::Truncated
        | ReadError::NotCanonical
        | ReadError::BadText => CTAP2_ERR_INVALID_CBOR,
        ReadError::Unsupported | ReadError::TooDeep => CTAP2_ERR_UNSUPPORTED_OPTION,
    }
}







const CRED_ID_LEN: usize = 48;
const TAG_LEN: usize = 16;
type Hmac = SimpleHmac<Sha256>;

fn mac(label: &[u8], nonce: &[u8], rp_id_hash: &[u8], salt: &[u8; 16], out: &mut [u8]) {
    let mut m = <Hmac as Mac>::new_from_slice(secret_bytes()).unwrap();
    m.update(label);
    m.update(salt);
    m.update(nonce);
    m.update(rp_id_hash);
    let tag = m.finalize().into_bytes();
    out.copy_from_slice(&tag[..out.len()]);
}

fn derive_key(nonce: &[u8], rp_id_hash: &[u8], salt: &[u8; 16]) -> Option<SigningKey> {
    for counter in 0u8..=255 {
        let mut k = [0u8; 32];
        let mut m = <Hmac as Mac>::new_from_slice(secret_bytes()).unwrap();
        m.update(b"key");
        m.update(salt);
        m.update(&[counter]);
        m.update(nonce);
        m.update(rp_id_hash);
        k.copy_from_slice(&m.finalize().into_bytes()[..32]);
        if let Ok(sk) = SigningKey::from_bytes(&k.into()) {
            return Some(sk);
        }
    }
    None
}

const FLAG_UP: u8 = 0x01;
const FLAG_UV: u8 = 0x04;
const FLAG_AT: u8 = 0x40;
/// Extension data is present in authData. hmac-secret is the first extension
/// this repository has ever put there, so this bit has never been set before.
const FLAG_ED: u8 = 0x80;

/// The per-credential secret an hmac-secret output is keyed with.
///
/// The specification has the authenticator generate this at registration and
/// keep it. exp172's rule applies instead: there is no table, so it is
/// recomputed from the credential ID the client hands back. A credential this
/// board did not make has no CredRandom — though that is not what stops it,
/// because exp172's tag check refuses it before any of this runs.
///
/// **Two of them, and the difference is not decoration.** The specification
/// selects between them by whether the assertion was user-verified, so a build
/// that computed one and used it for both would hand out a key that silently
/// changed with how the caller authenticated. That is the exact failure this
/// experiment exists to detect, so both exist and the domain string is what
/// separates them.
fn cred_random(cred_id: &[u8], with_uv: bool) -> [u8; 32] {
    let domain: &[u8] = if with_uv { b"credrandom-uv" } else { b"credrandom-noUV" };
    let mut m = <Hmac as Mac>::new_from_slice(secret_bytes()).unwrap();
    m.update(domain);
    m.update(cred_id);
    m.finalize().into_bytes().into()
}

/// The thirty-two bytes this whole experiment is about.
///
/// One HMAC. Everything around it — the ECDH, the AES-256-CBC tunnel, the
/// truncated authentication tag — was built by exp185 and is reused unchanged.
fn hmac_secret_output(cred_random: &[u8; 32], salt: &[u8]) -> [u8; 32] {
    let mut m = <Hmac as Mac>::new_from_slice(cred_random).unwrap();
    m.update(salt);
    m.finalize().into_bytes().into()
}

/// What a client asked for in `getAssertion`'s `hmac-secret` extension.
struct HmacSecretRequest<'a> {
    peer_x: [u8; 32],
    peer_y: [u8; 32],
    salt_enc: &'a [u8],
    salt_auth: &'a [u8],
}

/// CTAP 2.1 Resident Key entry (stored on authenticator for Passkeys)
#[derive(Clone, Copy)]
pub struct ResidentKeyEntry {
    pub in_use: bool,
    pub rp_id: [u8; 32],
    pub rp_id_len: u8,
    pub user_id: [u8; 64],
    pub user_id_len: u8,
    pub user_name: [u8; 32],
    pub user_name_len: u8,
    pub user_display_name: [u8; 32],
    pub user_display_name_len: u8,
    pub cred_id: [u8; 48],
}

pub struct ResidentStore {
    pub entries: [ResidentKeyEntry; MAX_RESIDENT_KEYS],
}

impl ResidentStore {
    pub const fn new() -> Self {
        Self {
            entries: [ResidentKeyEntry {
                in_use: false,
                rp_id: [0; 32],
                rp_id_len: 0,
                user_id: [0; 64],
                user_id_len: 0,
                user_name: [0; 32],
                user_name_len: 0,
                user_display_name: [0; 32],
                user_display_name_len: 0,
                cred_id: [0; 48],
            }; MAX_RESIDENT_KEYS],
        }
    }

    pub fn count(&self) -> usize {
        self.entries.iter().filter(|e| e.in_use).count()
    }

    pub fn remaining(&self) -> usize {
        MAX_RESIDENT_KEYS - self.count()
    }

    pub fn find_by_rp_and_user(&self, rp_id: &[u8], user_id: &[u8]) -> Option<usize> {
        self.entries.iter().position(|e| {
            e.in_use
                && &e.rp_id[..e.rp_id_len as usize] == rp_id
                && &e.user_id[..e.user_id_len as usize] == user_id
        })
    }

    pub fn find_first_by_rp_hash(&self, rp_id_hash: &[u8; 32]) -> Option<&ResidentKeyEntry> {
        self.entries.iter().find(|e| {
            if !e.in_use {
                return false;
            }
            let hash: [u8; 32] = Sha256::digest(&e.rp_id[..e.rp_id_len as usize]).into();
            &hash == rp_id_hash
        })
    }

    pub fn insert(
        &mut self,
        rp_id: &str,
        user_id: &[u8],
        user_name: Option<&str>,
        user_display_name: Option<&str>,
        cred_id: &[u8; 48],
    ) -> Result<(), ()> {
        let slot = if let Some(idx) = self.find_by_rp_and_user(rp_id.as_bytes(), user_id) {
            idx
        } else if let Some(idx) = self.entries.iter().position(|e| !e.in_use) {
            idx
        } else {
            return Err(()); // storage full
        };

        let e = &mut self.entries[slot];
        e.in_use = true;
        let rlen = rp_id.len().min(32);
        e.rp_id[..rlen].copy_from_slice(&rp_id.as_bytes()[..rlen]);
        e.rp_id_len = rlen as u8;

        let ulen = user_id.len().min(64);
        e.user_id[..ulen].copy_from_slice(&user_id[..ulen]);
        e.user_id_len = ulen as u8;

        if let Some(name) = user_name {
            let nlen = name.len().min(32);
            e.user_name[..nlen].copy_from_slice(&name.as_bytes()[..nlen]);
            e.user_name_len = nlen as u8;
        } else {
            e.user_name_len = 0;
        }

        if let Some(dname) = user_display_name {
            let dnlen = dname.len().min(32);
            e.user_display_name[..dnlen].copy_from_slice(&dname.as_bytes()[..dnlen]);
            e.user_display_name_len = dnlen as u8;
        } else {
            e.user_display_name_len = 0;
        }

        e.cred_id.copy_from_slice(cred_id);
        Ok(())
    }

    pub fn delete_by_cred_id(&mut self, cred_id: &[u8]) -> bool {
        if let Some(idx) = self.entries.iter().position(|e| e.in_use && &e.cred_id[..] == cred_id) {
            self.entries[idx].in_use = false;
            true
        } else {
            false
        }
    }

    pub fn clear(&mut self) {
        for e in &mut self.entries {
            e.in_use = false;
        }
    }
}

/// State machine for CTAP 2.1 PIN & Reset management
struct PinState {
    is_set: bool,
    pin_hash: [u8; 16], // SHA-256(pin)[0..16]
    retries_remaining: u8,
    active_token: Option<[u8; 32]>,
}

impl PinState {
    const fn new() -> Self {
        Self {
            is_set: false,
            pin_hash: [0u8; 16],
            retries_remaining: 8,
            active_token: None,
        }
    }

    fn reset(&mut self) {
        self.is_set = false;
        self.pin_hash = [0u8; 16];
        self.retries_remaining = 8;
        self.active_token = None;
    }
}

struct Built {
    response: usize,
    auth_len: usize,
    cred_id: [u8; CRED_ID_LEN],
}

fn build_credential(
    out: &mut [u8],
    auth: &mut [u8; 256],
    scratch: &mut [u8; 256],
    rp_id: &str,
    client_data_hash: &[u8],
    nonce: &[u8; 32],
    salt: &[u8; 16],
    user_present: bool,
    user_verified: bool,
    // Did the client ask for hmac-secret? Registration only answers yes or no;
    // no key is computed here, and none is computed until an assertion asks.
    hmac_secret: bool,
) -> Result<Built, ()> {
    let rp_id_hash: [u8; 32] = Sha256::digest(rp_id.as_bytes()).into();

    let mut cred_id = [0u8; CRED_ID_LEN];
    cred_id[..32].copy_from_slice(nonce);
    let (nonce_part, tag_part) = cred_id.split_at_mut(32);
    mac(b"id", nonce_part, &rp_id_hash, salt, &mut tag_part[..TAG_LEN]);

    let sk = derive_key(nonce, &rp_id_hash, salt).ok_or(())?;
    let point = sk.verifying_key().to_encoded_point(false);
    let x = point.x().ok_or(())?;
    let y = point.y().ok_or(())?;

    let cose_len = {
        let mut w = cbor::Writer::new(&mut scratch[..]);
        w.map(5);
        w.key(1);
        w.uint(2);
        w.key(3);
        w.nint(COSE_ES256);
        w.key_nint(-1);
        w.uint(1);
        w.key_nint(-2);
        w.bytes(x);
        w.key_nint(-3);
        w.bytes(y);
        w.end();
        w.finish().map_err(|_| ())?.len()
    };

    let mut n = 0usize;
    auth[..32].copy_from_slice(&rp_id_hash);
    n += 32;
    let mut flags = FLAG_AT | if user_present { FLAG_UP } else { 0 };
    if user_verified {
        flags |= FLAG_UV;
    }
    if hmac_secret {
        flags |= FLAG_ED;
    }
    auth[n] = flags;
    n += 1;
    auth[n..n + 4].copy_from_slice(&0u32.to_be_bytes());
    n += 4;
    auth[n..n + 16].copy_from_slice(&AAGUID);
    n += 16;
    auth[n..n + 2].copy_from_slice(&(CRED_ID_LEN as u16).to_be_bytes());
    n += 2;
    auth[n..n + CRED_ID_LEN].copy_from_slice(&cred_id);
    n += CRED_ID_LEN;
    auth[n..n + cose_len].copy_from_slice(&scratch[..cose_len]);
    n += cose_len;

    // Extension data comes after the attested credential data, and the order is
    // the specification's rather than a choice.
    if hmac_secret {
        let mut ext = [0u8; 32];
        let ext_len = {
            let mut w = cbor::Writer::new(&mut ext);
            w.map(1);
            w.key_text("hmac-secret");
            w.bool(true);
            w.end();
            w.finish().map_err(|_| ())?.len()
        };
        if n + ext_len > auth.len() {
            return Err(());
        }
        auth[n..n + ext_len].copy_from_slice(&ext[..ext_len]);
        n += ext_len;
    }
    let auth_len = n;

    let mut signed = [0u8; 320];
    if auth_len + client_data_hash.len() > signed.len() {
        return Err(());
    }
    signed[..auth_len].copy_from_slice(&auth[..auth_len]);
    signed[auth_len..auth_len + client_data_hash.len()].copy_from_slice(client_data_hash);
    let sig: Signature = sk.sign(&signed[..auth_len + client_data_hash.len()]);
    let der = sig.to_der();

    let response = {
        let mut w = cbor::Writer::new(out);
        w.map(3);
        w.key(1);
        w.text("packed");
        w.key(2);
        w.bytes(&auth[..auth_len]);
        w.key(3);
        w.map(2);
        w.key_text("alg");
        w.nint(COSE_ES256);
        w.key_text("sig");
        w.bytes(der.as_bytes());
        w.end();
        w.end();
        w.finish().map_err(|_| ())?.len()
    };

    Ok(Built { response, auth_len, cred_id })
}

fn tags_equal(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for i in 0..a.len() {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

fn credential_is_ours(cred_id: &[u8], rp_id_hash: &[u8; 32], salt: &[u8; 16]) -> bool {
    if cred_id.len() != CRED_ID_LEN {
        return false;
    }
    let (nonce, tag) = cred_id.split_at(32);
    let mut want = [0u8; TAG_LEN];
    mac(b"id", nonce, rp_id_hash, salt, &mut want);
    tags_equal(&want, tag)
}

struct GetAssertion<'a> {
    rp_id: &'a str,
    client_data_hash: &'a [u8],
    allow: [&'a [u8]; MAX_ALLOW],
    n_allow: usize,
    pin_uv_auth_param: Option<&'a [u8]>,
    uv_required: bool,
    hmac_secret: Option<HmacSecretRequest<'a>>,
}

const MAX_ALLOW: usize = 8;

fn parse_get_assertion(body: &[u8]) -> Result<GetAssertion<'_>, u8> {
    let mut r = Reader::new(body);
    let pairs = r.map_header().map_err(status_for)?;

    let mut rp_id: Option<&str> = None;
    let mut client_data_hash: Option<&[u8]> = None;
    let mut allow: [&[u8]; MAX_ALLOW] = [&[]; MAX_ALLOW];
    let mut n_allow = 0usize;
    let mut pin_uv_auth_param: Option<&[u8]> = None;
    let mut uv_required = false;
    let mut hmac_secret: Option<HmacSecretRequest> = None;

    for _ in 0..pairs {
        let key = match r.next().map_err(status_for)? {
            Item::Uint(k) => k,
            _ => return Err(CTAP2_ERR_INVALID_CBOR),
        };
        match key {
            0x01 => match r.next().map_err(status_for)? {
                Item::Text(v) => rp_id = Some(v),
                _ => return Err(CTAP2_ERR_INVALID_CBOR),
            },
            0x02 => match r.next().map_err(status_for)? {
                Item::Bytes(v) => client_data_hash = Some(v),
                _ => return Err(CTAP2_ERR_INVALID_CBOR),
            },
            0x03 => {
                let entries = match r.next().map_err(status_for)? {
                    Item::Array(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                for _ in 0..entries {
                    let n = match r.next().map_err(status_for)? {
                        Item::Map(n) => n,
                        _ => return Err(CTAP2_ERR_INVALID_CBOR),
                    };
                    let mut it = Reader::new(&body[r.position()..]);
                    if find_text_key(&mut it, n, "id").map_err(status_for)? {
                        match it.next().map_err(status_for)? {
                            Item::Bytes(v) => {
                                if n_allow < MAX_ALLOW {
                                    allow[n_allow] = v;
                                    n_allow += 1;
                                }
                            }
                            _ => return Err(CTAP2_ERR_INVALID_CBOR),
                        }
                    }
                    skip_map_pairs(&mut r, n).map_err(status_for)?;
                }
            }
            // 0x04: extensions. The client sends
            //   "hmac-secret": { 01: keyAgreement, 02: saltEnc, 03: saltAuth }
            // and every part of the tunnel carrying it was built by exp185.
            0x04 => {
                let n = match r.next().map_err(status_for)? {
                    Item::Map(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                let mut it = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it, n, "hmac-secret").map_err(status_for)? {
                    let inner = match it.next() {
                        Ok(Item::Map(m)) => m,
                        Ok(_) => { log!("  ext: hmac-secret value is not a map"); return Err(CTAP2_ERR_INVALID_CBOR); }
                        Err(e) => { log!("  ext: hmac-secret value unreadable: {:?}", e); return Err(status_for(e)); }
                    };
                    let mut px = [0u8; 32];
                    let mut py = [0u8; 32];
                    let mut have_key = false;
                    let mut enc: Option<&[u8]> = None;
                    let mut tag: Option<&[u8]> = None;
                    for _ in 0..inner {
                        let k = match it.next() {
                            Ok(Item::Uint(k)) => k,
                            Ok(other) => { log!("  ext: inner key is not a uint: {:?}", other); return Err(CTAP2_ERR_INVALID_CBOR); }
                            Err(e) => { log!("  ext: inner key unreadable: {:?}", e); return Err(status_for(e)); }
                        };
                        match k {
                            0x01 => {
                                let (x, y) = match parse_cose_key_point(&mut it) {
                                    Ok(v) => v,
                                    Err(e) => { log!("  ext: keyAgreement rejected ({:#04x})", e); return Err(e); }
                                };
                                px = x;
                                py = y;
                                have_key = true;
                            }
                            0x02 => match it.next() {
                                Ok(Item::Bytes(b)) => enc = Some(b),
                                Ok(o) => { log!("  ext: saltEnc not bytes: {:?}", o); return Err(CTAP2_ERR_INVALID_CBOR); }
                                Err(e) => { log!("  ext: saltEnc unreadable: {:?}", e); return Err(status_for(e)); }
                            },
                            0x03 => match it.next() {
                                Ok(Item::Bytes(b)) => tag = Some(b),
                                Ok(o) => { log!("  ext: saltAuth not bytes: {:?}", o); return Err(CTAP2_ERR_INVALID_CBOR); }
                                Err(e) => { log!("  ext: saltAuth unreadable: {:?}", e); return Err(status_for(e)); }
                            },
                            _ => it.skip().map_err(status_for)?,
                        }
                    }
                    match (have_key, enc, tag) {
                        (true, Some(e), Some(a)) => {
                            hmac_secret = Some(HmacSecretRequest {
                                peer_x: px,
                                peer_y: py,
                                salt_enc: e,
                                salt_auth: a,
                            })
                        }
                        _ => return Err(CTAP2_ERR_MISSING_PARAMETER),
                    }
                }
                skip_map_pairs(&mut r, n).map_err(status_for)?;
            }
            0x05 => { // options map
                let n = match r.next().map_err(status_for)? {
                    Item::Map(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                let mut it = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it, n, "uv").map_err(status_for)? {
                    if let Ok(Item::Bool(b)) = it.next() {
                        uv_required = b;
                    }
                }
                skip_map_pairs(&mut r, n).map_err(status_for)?;
            }
            0x06 => match r.next().map_err(status_for)? {
                Item::Bytes(v) => pin_uv_auth_param = Some(v),
                _ => return Err(CTAP2_ERR_INVALID_CBOR),
            },
            // 0x07 is pinUvAuthProtocol, a uint. Reading it as Bytes refused
            // every request that named a protocol — the same shape of mistake
            // as makeCredential's 0x06, and found the same way.
            0x07 => match r.next().map_err(status_for)? {
                Item::Uint(_) => {}
                _ => return Err(CTAP2_ERR_INVALID_CBOR),
            },
            _ => r.skip().map_err(status_for)?,
        }
    }
    if !r.is_empty() {
        return Err(CTAP2_ERR_INVALID_CBOR);
    }

    let rp_id = rp_id.ok_or(CTAP2_ERR_MISSING_PARAMETER)?;
    let client_data_hash = client_data_hash.ok_or(CTAP2_ERR_MISSING_PARAMETER)?;
    if client_data_hash.len() != 32 {
        return Err(CTAP2_ERR_INVALID_CBOR);
    }

    Ok(GetAssertion { rp_id, client_data_hash, allow, n_allow, pin_uv_auth_param, uv_required, hmac_secret })
}

fn build_assertion(
    out: &mut [u8],
    rp_id: &str,
    cred_id: &[u8],
    client_data_hash: &[u8],
    salt: &[u8; 16],
    user_present: bool,
    user_verified: bool,
    user_entry: Option<&ResidentKeyEntry>,
    // The hmac-secret answer, already encrypted under exp185's shared secret.
    hmac_output: Option<&[u8]>,
) -> Result<(usize, u64, u64), ()> {
    let rp_id_hash: [u8; 32] = Sha256::digest(rp_id.as_bytes()).into();
    let nonce = &cred_id[..32];

    let t0 = Instant::now();
    let sk = derive_key(nonce, &rp_id_hash, salt).ok_or(())?;
    let derive_us = t0.elapsed().as_micros();

    // Every assertion this repository has ever produced was exactly 37 bytes of
    // authData. hmac-secret is the first thing appended after it, and the ED
    // flag is the first time bit 7 has been set here.
    let mut auth = [0u8; 128];
    auth[..32].copy_from_slice(&rp_id_hash);
    let mut flags = if user_present { FLAG_UP } else { 0 };
    if user_verified {
        flags |= FLAG_UV;
    }
    if hmac_output.is_some() {
        flags |= FLAG_ED;
    }
    auth[32] = flags;
    auth[33..37].copy_from_slice(&0u32.to_be_bytes());
    let mut auth_len = 37usize;

    if let Some(enc) = hmac_output {
        let mut ext = [0u8; 80];
        let ext_len = {
            let mut w = cbor::Writer::new(&mut ext);
            w.map(1);
            w.key_text("hmac-secret");
            w.bytes(enc);
            w.end();
            w.finish().map_err(|_| ())?.len()
        };
        if auth_len + ext_len > auth.len() {
            return Err(());
        }
        auth[auth_len..auth_len + ext_len].copy_from_slice(&ext[..ext_len]);
        auth_len += ext_len;
    }

    let mut signed_buf = [0u8; 176];
    if auth_len + client_data_hash.len() > signed_buf.len() {
        return Err(());
    }
    signed_buf[..auth_len].copy_from_slice(&auth[..auth_len]);
    signed_buf[auth_len..auth_len + client_data_hash.len()].copy_from_slice(client_data_hash);
    let signed = &signed_buf[..auth_len + client_data_hash.len()];
    let t1 = Instant::now();
    let sig: Signature = sk.sign(signed);
    let sign_us = t1.elapsed().as_micros();
    let der = sig.to_der();

    let map_count = if user_entry.is_some() { 4 } else { 3 };

    let n = {
        let mut w = cbor::Writer::new(out);
        w.map(map_count);
        w.key(1);
        w.map(2);
        w.key_text("id");
        w.bytes(cred_id);
        w.key_text("type");
        w.text("public-key");
        w.end();
        w.key(2);
        w.bytes(&auth[..auth_len]);
        w.key(3);
        w.bytes(der.as_bytes());

        if let Some(u) = user_entry {
            w.key(4); // user entity (Passkey discoverable credential lookup)
            let mut u_fields = 1;
            if u.user_name_len > 0 { u_fields += 1; }
            if u.user_display_name_len > 0 { u_fields += 1; }
            w.map(u_fields);
            w.key_text("id");
            w.bytes(&u.user_id[..u.user_id_len as usize]);
            if u.user_name_len > 0 {
                w.key_text("name");
                if let Ok(s) = core::str::from_utf8(&u.user_name[..u.user_name_len as usize]) {
                    w.text(s);
                } else {
                    w.text("");
                }
            }
            if u.user_display_name_len > 0 {
                w.key_text("displayName");
                if let Ok(s) = core::str::from_utf8(&u.user_display_name[..u.user_display_name_len as usize]) {
                    w.text(s);
                } else {
                    w.text("");
                }
            }
            w.end();
        }

        w.end();
        w.finish().map_err(|_| ())?.len()
    };
    Ok((n, derive_us, sign_us))
}

struct MakeCredential<'a> {
    client_data_hash: &'a [u8],
    rp_id: &'a str,
    user_id: &'a [u8],
    user_name: Option<&'a str>,
    user_display_name: Option<&'a str>,
    algs: [i64; MAX_ALGS],
    n_algs: usize,
    pin_uv_auth_param: Option<&'a [u8]>,
    uv_required: bool,
    rk_required: bool,
    hmac_secret: bool,
}

const MAX_ALGS: usize = 8;

fn find_text_key(r: &mut Reader, pairs: u64, want: &str) -> Result<bool, ReadError> {
    for _ in 0..pairs {
        let is_it = match r.next()? {
            Item::Text(k) => k == want,
            Item::Uint(_) | Item::Nint(_) => false,
            _ => return Err(ReadError::NotCanonical),
        };
        if is_it {
            return Ok(true);
        }
        r.skip()?;
    }
    Ok(false)
}

fn parse_make_credential(body: &[u8]) -> Result<MakeCredential<'_>, u8> {
    let mut r = Reader::new(body);
    let pairs = r.map_header().map_err(status_for)?;

    let mut client_data_hash: Option<&[u8]> = None;
    let mut rp_id: Option<&str> = None;
    let mut user_id: Option<&[u8]> = None;
    let mut user_name: Option<&str> = None;
    let mut user_display_name: Option<&str> = None;
    let mut algs = [0i64; MAX_ALGS];
    let mut n_algs = 0usize;
    let mut have_params = false;
    let mut pin_uv_auth_param: Option<&[u8]> = None;
    let mut uv_required = false;
    let mut rk_required = false;
    let mut hmac_secret = false;

    for _ in 0..pairs {
        let key = match r.next().map_err(status_for)? {
            Item::Uint(k) => k,
            _ => return Err(CTAP2_ERR_INVALID_CBOR),
        };
        match key {
            0x01 => match r.next().map_err(status_for)? {
                Item::Bytes(b) => client_data_hash = Some(b),
                _ => return Err(CTAP2_ERR_INVALID_CBOR),
            },
            0x02 => {
                let n = match r.next().map_err(status_for)? {
                    Item::Map(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                let mut it = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it, n, "id").map_err(status_for)? {
                    match it.next().map_err(status_for)? {
                        Item::Text(v) => rp_id = Some(v),
                        _ => return Err(CTAP2_ERR_INVALID_CBOR),
                    }
                }
                skip_map_pairs(&mut r, n).map_err(status_for)?;
            }
            0x03 => {
                let n = match r.next().map_err(status_for)? {
                    Item::Map(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                let mut it_id = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it_id, n, "id").map_err(status_for)? {
                    match it_id.next().map_err(status_for)? {
                        Item::Bytes(v) => user_id = Some(v),
                        _ => return Err(CTAP2_ERR_INVALID_CBOR),
                    }
                }
                let mut it_name = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it_name, n, "name").map_err(status_for)? {
                    if let Ok(Item::Text(v)) = it_name.next() {
                        user_name = Some(v);
                    }
                }
                let mut it_dn = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it_dn, n, "displayName").map_err(status_for)? {
                    if let Ok(Item::Text(v)) = it_dn.next() {
                        user_display_name = Some(v);
                    }
                }
                skip_map_pairs(&mut r, n).map_err(status_for)?;
            }
            0x04 => {
                have_params = true;
                let entries = match r.next().map_err(status_for)? {
                    Item::Array(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                for _ in 0..entries {
                    let n = match r.next().map_err(status_for)? {
                        Item::Map(n) => n,
                        _ => return Err(CTAP2_ERR_INVALID_CBOR),
                    };
                    let mut it = Reader::new(&body[r.position()..]);
                    if find_text_key(&mut it, n, "alg").map_err(status_for)? {
                        let v = match it.next().map_err(status_for)? {
                            Item::Nint(v) => v,
                            Item::Uint(v) => v as i64,
                            _ => return Err(CTAP2_ERR_INVALID_CBOR),
                        };
                        if n_algs < MAX_ALGS {
                            algs[n_algs] = v;
                            n_algs += 1;
                        }
                    }
                    skip_map_pairs(&mut r, n).map_err(status_for)?;
                }
            }
            0x07 => { // options map
                let n = match r.next().map_err(status_for)? {
                    Item::Map(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                let mut it_uv = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it_uv, n, "uv").map_err(status_for)? {
                    if let Ok(Item::Bool(b)) = it_uv.next() {
                        uv_required = b;
                    }
                }
                let mut it_rk = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it_rk, n, "rk").map_err(status_for)? {
                    if let Ok(Item::Bool(b)) = it_rk.next() {
                        rk_required = b;
                    }
                }
                skip_map_pairs(&mut r, n).map_err(status_for)?;
            }
            // 0x06 is **extensions** in makeCredential; 0x08 is pinUvAuthParam.
            // The inherited code read `0x06 | 0x08` as pinUvAuthParam, which is
            // getAssertion's numbering — so any makeCredential carrying an
            // extension map was refused with CTAP2_ERR_INVALID_CBOR, because a
            // map is not Bytes. Nothing caught it: no client had ever sent one.
            0x06 => {
                let n = match r.next().map_err(status_for)? {
                    Item::Map(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                let mut it = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it, n, "hmac-secret").map_err(status_for)? {
                    if let Ok(Item::Bool(b)) = it.next() {
                        hmac_secret = b;
                    }
                }
                skip_map_pairs(&mut r, n).map_err(status_for)?;
            }
            0x08 => match r.next().map_err(status_for)? {
                Item::Bytes(v) => pin_uv_auth_param = Some(v),
                _ => return Err(CTAP2_ERR_INVALID_CBOR),
            },
            _ => r.skip().map_err(status_for)?,
        }
    }

    if !r.is_empty() {
        return Err(CTAP2_ERR_INVALID_CBOR);
    }

    let client_data_hash = client_data_hash.ok_or(CTAP2_ERR_MISSING_PARAMETER)?;
    let rp_id = rp_id.ok_or(CTAP2_ERR_MISSING_PARAMETER)?;
    let user_id = user_id.ok_or(CTAP2_ERR_MISSING_PARAMETER)?;
    if !have_params {
        return Err(CTAP2_ERR_MISSING_PARAMETER);
    }
    if client_data_hash.len() != 32 {
        return Err(CTAP2_ERR_INVALID_CBOR);
    }

    Ok(MakeCredential {
        client_data_hash,
        rp_id,
        user_id,
        user_name,
        user_display_name,
        algs,
        n_algs,
        pin_uv_auth_param,
        uv_required,
        rk_required,
        hmac_secret,
    })
}

fn skip_map_pairs(r: &mut Reader, pairs: u64) -> Result<(), ReadError> {
    for _ in 0..pairs {
        r.skip()?;
        r.skip()?;
    }
    Ok(())
}

/// Build an `authenticatorGetInfo` response for CTAP 2.1 with Passkey (rk) and credMgmt.
fn get_info<'a>(buf: &'a mut [u8], pin_state: &PinState) -> Result<&'a [u8], cbor::Error> {
    let mut w = cbor::Writer::new(buf);
    w.map(6);

    // 0x01: versions
    w.key(0x01);
    w.array(VERSIONS.len() as u32);
    for v in VERSIONS {
        w.text(v);
    }
    w.end();

    // 0x02: extensions. exp169 is the rung about a device that announces a
    // capability it does not have, so this line and the two branches below go
    // in together or not at all.
    w.key(0x02);
    w.array(1);
    w.text("hmac-secret");
    w.end();

    // 0x03: aaguid
    w.key(0x03);
    w.bytes(&AAGUID);

    // 0x04: options (canonical order by key length: "rk" (2), "up" (2), "uv" (2), "credMgmt" (8), "clientPin" (9), "pinUvAuthToken" (14), "makeCredUvNotRqd" (16))
    w.key(0x04);
    // `uv` is a claim about a **configured** verification method, and exp192
    // found that a browser reads it as one. This firmware's is exp187's
    // three-tap gesture, which is real — but advertising it makes Chrome run a
    // preflight before it will send a makeCredential, and the conversation ends
    // there. libfido2 does not run that preflight, which is why every other
    // client in this repository worked. The flag exists so one board can be
    // asked the same question under both contracts; the default is unchanged,
    // so exp189's own transcripts still describe the firmware they were taken
    // on.
    // How many claims this build is willing to make. Each one exp192 switched
    // off bought a browser one more step, and none of them mattered to
    // libfido2 — which is the finding rather than the workaround.
    #[cfg(all(no_uv, no_pin))]
    w.map(4);
    #[cfg(all(no_uv, not(no_pin)))]
    w.map(6);
    #[cfg(all(not(no_uv), no_pin))]
    w.map(5);
    #[cfg(all(not(no_uv), not(no_pin)))]
    w.map(7);
    w.key_text("rk");
    w.bool(true); // Discoverable credentials (Passkeys) supported!
    w.key_text("up");
    w.bool(WAIT_FOR_USER);
    #[cfg(not(no_uv))]
    {
        w.key_text("uv");
        w.bool(true); // Built-in gesture UV supported
    }
    w.key_text("credMgmt");
    w.bool(true); // CTAP 2.1 Credential Management supported! (len 8)
    // `clientPin: false` plus `pinUvAuthToken: true` is not "no PIN" to a
    // browser — it is "a PIN this key supports and has not got yet", and Chrome
    // responds by offering to set one. A board whose whole verification story
    // is one button says neither.
    #[cfg(not(no_pin))]
    {
        w.key_text("clientPin");
        w.bool(pin_state.is_set); // (len 9)
        w.key_text("pinUvAuthToken");
        w.bool(true);
    }
    w.key_text("makeCredUvNotRqd");
    w.bool(!pin_state.is_set);
    w.end();

    // 0x05: maxMsgSize
    w.key(0x05);
    w.uint(MAX_MESSAGE as u64);

    // 0x06: pinUvAuthProtocols
    w.key(0x06);
    w.array(1);
    w.uint(1); // Protocol 1 (P-256 + HMAC-SHA256 + AES-256-CBC)
    w.end();

    w.end();
    w.finish()
}

/// Parse peer COSE_Key public point (x and y coordinates).
fn parse_cose_key_point(r: &mut Reader) -> Result<([u8; 32], [u8; 32]), u8> {
    let pairs = match r.next().map_err(|_| CTAP2_ERR_INVALID_CBOR)? {
        Item::Map(n) => n,
        _ => return Err(CTAP2_ERR_INVALID_CBOR),
    };
    let mut x_coord: Option<[u8; 32]> = None;
    let mut y_coord: Option<[u8; 32]> = None;

    for _ in 0..pairs {
        let key_item = r.next().map_err(|_| CTAP2_ERR_INVALID_CBOR)?;
        match key_item {
            Item::Nint(n) if n == -2 => { // -2: x
                if let Item::Bytes(b) = r.next().map_err(|_| CTAP2_ERR_INVALID_CBOR)? {
                    if b.len() == 32 {
                        let mut arr = [0u8; 32];
                        arr.copy_from_slice(b);
                        x_coord = Some(arr);
                    }
                }
            }
            Item::Nint(n) if n == -3 => { // -3: y
                if let Item::Bytes(b) = r.next().map_err(|_| CTAP2_ERR_INVALID_CBOR)? {
                    if b.len() == 32 {
                        let mut arr = [0u8; 32];
                        arr.copy_from_slice(b);
                        y_coord = Some(arr);
                    }
                }
            }
            _ => {
                r.skip().map_err(|_| CTAP2_ERR_INVALID_CBOR)?;
            }
        }
    }

    match (x_coord, y_coord) {
        (Some(x), Some(y)) => Ok((x, y)),
        _ => Err(CTAP2_ERR_MISSING_PARAMETER),
    }
}

/// Decapsulate shared secret using P-256 ECDH:
/// shared_secret = SHA-256( (a * B).x )
fn decapsulate_shared_secret(
    authenticator_sk: &SecretKey,
    peer_x: &[u8; 32],
    peer_y: &[u8; 32],
) -> Result<[u8; 32], ()> {
    let point = p256::EncodedPoint::from_affine_coordinates(
        peer_x.into(),
        peer_y.into(),
        false,
    );
    let peer_pk = Option::<PublicKey>::from(PublicKey::from_encoded_point(&point)).ok_or(())?;
    let affine = peer_pk.as_affine();
    let shared = p256::ecdh::diffie_hellman(authenticator_sk.to_nonzero_scalar(), affine);
    let mut hasher = Sha256::new();
    hasher.update(shared.raw_secret_bytes());
    Ok(hasher.finalize().into())
}

/// Decrypt ciphertext with AES-256-CBC using sharedSecret and IV=0.
fn decrypt_pin_payload(
    shared_secret: &[u8; 32],
    ciphertext: &[u8],
    out: &mut [u8],
) -> Result<usize, ()> {
    if ciphertext.is_empty() || ciphertext.len() % 16 != 0 || out.len() < ciphertext.len() {
        return Err(());
    }
    let cipher = Aes256::new(shared_secret.into());
    let mut prev = [0u8; 16]; // IV = 0
    let mut cur = [0u8; 16];
    for (src_chunk, dst_chunk) in ciphertext.chunks_exact(16).zip(out.chunks_exact_mut(16)) {
        cur.copy_from_slice(src_chunk);
        let mut block = [0u8; 16];
        block.copy_from_slice(src_chunk);
        let mut block_generic = *aes::Block::from_slice(&block);
        cipher.decrypt_block(&mut block_generic);
        for i in 0..16 {
            dst_chunk[i] = block_generic[i] ^ prev[i];
        }
        prev = cur;
    }
    Ok(ciphertext.len())
}

/// Encrypt plaintext with AES-256-CBC using sharedSecret and IV=0.
fn encrypt_pin_payload(
    shared_secret: &[u8; 32],
    plaintext: &[u8],
    out: &mut [u8],
) -> Result<usize, ()> {
    if plaintext.is_empty() || plaintext.len() % 16 != 0 || out.len() < plaintext.len() {
        return Err(());
    }
    let cipher = Aes256::new(shared_secret.into());
    let mut prev = [0u8; 16]; // IV = 0
    for (src_chunk, dst_chunk) in plaintext.chunks_exact(16).zip(out.chunks_exact_mut(16)) {
        let mut block = [0u8; 16];
        for i in 0..16 {
            block[i] = src_chunk[i] ^ prev[i];
        }
        let mut blk = *aes::Block::from_slice(&block);
        cipher.encrypt_block(&mut blk);
        dst_chunk.copy_from_slice(&blk);
        prev.copy_from_slice(dst_chunk);
    }
    Ok(plaintext.len())
}

/// Verify 16-byte truncated HMAC-SHA256 pinAuth:
/// HMAC-SHA-256(sharedSecret, data)[..16] == pinAuth
fn verify_pin_auth(
    shared_secret: &[u8; 32],
    data: &[u8],
    pin_auth: &[u8],
) -> bool {
    if pin_auth.len() != 16 {
        return false;
    }
    let mut mac = match <SimpleHmac<Sha256> as KeyInit>::new_from_slice(shared_secret) {
        Ok(m) => m,
        Err(_) => return false,
    };
    mac.update(data);
    let full = mac.finalize().into_bytes();
    &full[..16] == pin_auth
}

/// Verify pinUvAuthParam against active pinUvAuthToken:
/// HMAC-SHA256(token, clientDataHash)[0..16] == pinUvAuthParam
fn verify_pin_uv_auth_token(
    active_token: Option<&[u8; 32]>,
    client_data_hash: &[u8],
    param: Option<&[u8]>,
) -> bool {
    let token = match active_token {
        Some(t) => t,
        None => return false,
    };
    let pin_auth = match param {
        Some(p) if p.len() >= 16 => &p[..16],
        _ => return false,
    };
    let mut mac = match <SimpleHmac<Sha256> as KeyInit>::new_from_slice(token) {
        Ok(m) => m,
        Err(_) => return false,
    };
    mac.update(client_data_hash);
    let full = mac.finalize().into_bytes();
    &full[..16] == pin_auth
}

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

#[embassy_executor::task]
async fn cdc_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut buf = [0u8; PACKET];
    loop {
        match select(control.control_changed(), receiver.read_packet(&mut buf)).await {
            Either::First(()) => {
                let rate = receiver.line_coding().data_rate();
                usb_reboot::reboot_if_requested(rate).await;
            }
            Either::Second(_) => {}
        }
    }
}

/// - **one short flash a second** — running, nothing wanted
/// - **solid on** — press BOOTSEL *now*; a request is waiting
/// - **two quick flashes, then a pause** — this board has no secret: unplug it
///   and plug it back in, and nothing else will help
#[embassy_executor::task]
async fn blink_task(mut led: Output<'static>) -> ! {
    loop {
        match LED_MODE.load(Ordering::Relaxed) {
            LED_PRESS_NOW => {
                led.set_high();
                Timer::after(Duration::from_millis(50)).await;
            }
            LED_UNPROVISIONED => {
                for _ in 0..2 {
                    led.set_high();
                    Timer::after(Duration::from_millis(80)).await;
                    led.set_low();
                    Timer::after(Duration::from_millis(120)).await;
                }
                Timer::after(Duration::from_millis(900)).await;
            }
            _ => {
                led.set_high();
                Timer::after(Duration::from_millis(50)).await;
                led.set_low();
                Timer::after(Duration::from_millis(950)).await;
            }
        }
    }
}



async fn wait_for_user_presence(wire: &mut Wire, cid: Cid) -> Waited {
    LED_MODE.store(LED_PRESS_NOW, Ordering::Relaxed);
    let start = Instant::now();
    let mut pressed_at: Option<u64> = None;

    // The press bookkeeping is this experiment's and stays here; the keepalives,
    // the busy refusals and — the part exp194 measured this firmware getting
    // wrong — answering a broadcast INIT while it waits are the transport's,
    // and are now `crates/ctap-hid`'s.
    let res = wire
        .wait_for(
            cid,
            ctap_hid::STATUS_UPNEEDED,
            // With EXP189_KEEPALIVE off, an interval nothing reaches. exp174
            // measured what its absence costs and both arms stay honest.
            if KEEPALIVE { KEEPALIVE_INTERVAL } else { Duration::from_secs(3600) },
            PRESENCE_POLL,
            USER_PRESENCE_TIMEOUT,
            || {
                if bootsel::is_pressed() && pressed_at.is_none() {
                    let at = start.elapsed().as_millis();
                    // When the line read low, in the device's own words.
                    // Without it a press nobody made and a press somebody made
                    // are the same event.
                    log!("  presence: BOOTSEL read low at {} ms (poll {} ms)", at, PRESENCE_POLL_MS);
                    pressed_at = Some(at);
                }
                pressed_at.is_some() && start.elapsed().as_millis() >= HOLD_MS
            },
        )
        .await;
    led_rest();
    res
}

async fn wait_for_triple_tap(wire: &mut Wire, cid: Cid) -> bool {
    if !WAIT_FOR_USER {
        return true;
    }

    LED_MODE.store(LED_PRESS_NOW, Ordering::Relaxed);
    let start = Instant::now();
    let mut tap_count = 0u8;
    let mut is_down = false;
    let mut last_tap_time = start;

    let res = wire
        .wait_for(
            cid,
            ctap_hid::STATUS_UPNEEDED,
            if KEEPALIVE { KEEPALIVE_INTERVAL } else { Duration::from_secs(3600) },
            Duration::from_millis(10),
            Duration::from_millis(5000),
            || {
                let currently_down = bootsel::is_pressed();
                if currently_down && !is_down {
                    is_down = true;
                } else if !currently_down && is_down {
                    is_down = false;
                    tap_count += 1;
                    last_tap_time = Instant::now();
                    log!("  [Gesture UV] tap {}/3 detected", tap_count);
                }
                if tap_count > 0 && !is_down && last_tap_time.elapsed() > Duration::from_millis(1500) {
                    tap_count = 0;
                }
                tap_count >= 3
            },
        )
        .await;
    led_rest();
    res == Waited::Ready
}

/// The CTAP2 commands this authenticator answers.
///
/// It was `ctaphid_task` and 959 lines until
/// [exp194](../exp194-the-transport-that-drifted/) measured this firmware's
/// transport answering two of twelve cases wrongly — `ERR_INVALID_PAR` where
/// the specification names `ERR_INVALID_CHANNEL`, and refusing the broadcast
/// `INIT` that is a client's only way back, both in the main loop and again for
/// the whole of a thirty-second wait for a finger.
///
/// The transport is [`crates/ctap-hid`](../../crates/ctap-hid/) now and those
/// are gone by construction. The name changed with it: this function does not
/// implement CTAP-HID any more, it dispatches CTAP2, and a name that says
/// otherwise makes `experiments/duplication.sh` count a transport that is not
/// there.
#[embassy_executor::task]
async fn ctap2_task(
    hid: HidReaderWriter<'static, usb_reboot::UsbDriver, PACKET, PACKET>,
    mut trng: Trng<'static, TRNG>,
    boot_time: Instant,
) -> ! {
    // **Not `.unwrap()`.** Thirty-two zero bytes is what `secret_bytes` returns
    // on an unprovisioned board, and zero is not a valid P-256 scalar — so this
    // line used to panic before the USB stack was serving, which takes the board
    // off the bus entirely.
    //
    // A random scalar is fine here and is not a secret being invented: this key
    // only agrees the PIN-protocol tunnel, and every operation that would key
    // anything on the device secret is refused with CTAP2_ERR_NO_SECRET while
    // there is none.
    let mut session_sk = match SecretKey::from_slice(secret_bytes()) {
        Ok(k) => k,
        Err(_) => {
            let mut b = [0u8; 32];
            loop {
                trng.blocking_fill_bytes(&mut b);
                if let Ok(k) = SecretKey::from_slice(&b) {
                    break k;
                }
            }
        }
    };
    let mut pin_state = PinState::new();
    let mut resident_store = ResidentStore::new();
    let mut device_salt = [0u8; 16];
    trng.blocking_fill_bytes(&mut device_salt);

    let (reader, writer) = hid.split();
    let mut wire = Wire::new(reader, writer, CAPABILITIES);
    let mut buf = [0u8; MAX_MESSAGE];

    loop {
        // Reassembly, channels, INIT, every error the specification names and
        // the expiry that frees a channel are `crates/ctap-hid`'s. What arrives
        // here is only what this experiment has to decide something about.
        //
        // exp194 measured this firmware's own transport answering two of twelve
        // cases wrongly, and one of them refused a client's only way back. Those
        // are gone by construction rather than by anybody remembering.
        let (cid, cmd, len) = wire.next(&mut buf).await;
        MESSAGES.fetch_add(1, Ordering::Relaxed);
        if len > INIT_PAYLOAD {
            log!("  assembled {} bytes", len);
            Timer::after(PACE).await;
        }
        {
            {
                match cmd {
                    CTAPHID_PING => {
                        let packets = wire.reply(cid, CTAPHID_PING, &buf[..len]).await;
                        log!("  PING: echoed {} bytes in {} packets", len, packets);
                        Timer::after(PACE).await;
                    }
                    CTAPHID_CBOR => {
                        let ctap = if len >= 1 { buf[0] } else { 0xff };
                        let params = len - len.min(1);
                        let mut out = [0u8; 512];
                        match ctap {
                            AUTHENTICATOR_GET_INFO if params != 0 => {
                                wire.reply(cid, CTAPHID_CBOR, &[CTAP1_ERR_INVALID_LENGTH]).await;
                            }
                            AUTHENTICATOR_GET_INFO => {
                                out[0] = CTAP2_OK;
                                match get_info(&mut out[1..], &pin_state) {
                                    Ok(body) => {
                                        let n = 1 + body.len();
                                        log!("  getInfo: {} bytes of canonical CBOR (CTAP 2.1 rk+credMgmt)", body.len());
                                        Timer::after(PACE).await;
                                        wire.reply(cid, CTAPHID_CBOR, &out[..n]).await;
                                    }
                                    Err(_) => {
                                        ERRORS.fetch_add(1, Ordering::Relaxed);
                                        wire.reply(cid, CTAPHID_CBOR, &[0x7f]).await;
                                    }
                                }
                            }
                            #[cfg(selection)]
                            AUTHENTICATOR_SELECTION => {
                                // The whole command: light up, and say whether
                                // somebody answered. There is nothing to parse —
                                // its entire payload is the command byte — and
                                // nothing to return but a status.
                                log!("  authenticatorSelection: a client is asking which key");
                                let w = wait_for_user_presence(&mut wire, cid).await;
                                if w == Waited::Ready {
                                    log!("  authenticatorSelection: this one");
                                    wire.reply(cid, CTAPHID_CBOR, &[CTAP2_OK]).await;
                                } else {
                                    ERRORS.fetch_add(1, Ordering::Relaxed);
                                    log!("  authenticatorSelection: nobody answered");
                                    wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await;
                                }
                            }
                            AUTHENTICATOR_RESET => {
                                let elapsed = boot_time.elapsed();
                                log!("  authenticatorReset: request received (elapsed: {} ms)", elapsed.as_millis());
                                if elapsed > Duration::from_secs(RESET_WINDOW_SECS) {
                                    ERRORS.fetch_add(1, Ordering::Relaxed);
                                    log!("  authenticatorReset: rejected (elapsed {} ms > {} s window)", elapsed.as_millis(), RESET_WINDOW_SECS);
                                    Timer::after(PACE).await;
                                    wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_NOT_ALLOWED]).await;
                                    continue;
                                }

                                if WAIT_FOR_USER {
                                    let w = wait_for_user_presence(&mut wire, cid).await;
                                    if w != Waited::Ready {
                                        ERRORS.fetch_add(1, Ordering::Relaxed);
                                        wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await;
                                        continue;
                                    }
                                }

                                pin_state.reset();
                                resident_store.clear();
                                trng.blocking_fill_bytes(&mut device_salt);
                                log!("  authenticatorReset: SUCCESS. PIN cleared, resident keys cleared, salt rotated");
                                Timer::after(PACE).await;

                                out[0] = CTAP2_OK;
                                let mut w = cbor::Writer::new(&mut out[1..]);
                                w.map(0);
                                w.end();
                                if let Ok(b) = w.finish() {
                                    let n = 1 + b.len();
                                    wire.reply(cid, CTAPHID_CBOR, &out[..n]).await;
                                }
                            }
                            AUTHENTICATOR_CLIENT_PIN => {
                                let body = &buf[1..len];
                                let mut r = Reader::new(body);
                                let mut pin_proto: Option<u64> = None;
                                let mut sub_cmd: Option<u64> = None;
                                let mut peer_key: Option<([u8; 32], [u8; 32])> = None;
                                let mut pin_auth: Option<[u8; 16]> = None;
                                let mut new_pin_enc: Option<&[u8]> = None;
                                let mut pin_hash_enc: Option<&[u8]> = None;

                                if let Ok(pairs) = r.map_header() {
                                    for _ in 0..pairs {
                                        if let Ok(Item::Uint(k)) = r.next() {
                                            match k {
                                                0x01 => if let Ok(Item::Uint(p)) = r.next() { pin_proto = Some(p); },
                                                0x02 => if let Ok(Item::Uint(s)) = r.next() { sub_cmd = Some(s); },
                                                0x03 => {
                                                    if let Ok(coords) = parse_cose_key_point(&mut r) {
                                                        peer_key = Some(coords);
                                                    }
                                                }
                                                0x04 => {
                                                    if let Ok(Item::Bytes(b)) = r.next() {
                                                        if b.len() == 16 {
                                                            let mut arr = [0u8; 16];
                                                            arr.copy_from_slice(b);
                                                            pin_auth = Some(arr);
                                                        }
                                                    }
                                                }
                                                0x05 => {
                                                    if let Ok(Item::Bytes(b)) = r.next() {
                                                        new_pin_enc = Some(b);
                                                    }
                                                }
                                                0x06 => {
                                                    if let Ok(Item::Bytes(b)) = r.next() {
                                                        pin_hash_enc = Some(b);
                                                    }
                                                }
                                                _ => { let _ = r.skip(); }
                                            }
                                        }
                                    }
                                }
                                // Which question was asked, in the device's own
                                // words. Chrome sends a six-byte clientPIN
                                // before it will send anything else, and this
                                // firmware's log said only `CBOR bcnt 6` — so a
                                // browser that walked away after that answer
                                // left nothing behind saying what it had asked.
                                // Subcommand numbers are not secret.
                                log!("  clientPIN: pinProtocol={} sub={}",
                                     pin_proto.unwrap_or(0), sub_cmd.unwrap_or(0));
                                match sub_cmd {
                                    Some(0x01) => {
                                        // getPinRetries
                                        out[0] = CTAP2_OK;
                                        let mut w = cbor::Writer::new(&mut out[1..]);
                                        w.map(1);
                                        w.key(0x03);
                                        w.uint(pin_state.retries_remaining as u64);
                                        w.end();
                                        if let Ok(b) = w.finish() {
                                            let n = 1 + b.len();
                                            wire.reply(cid, CTAPHID_CBOR, &out[..n]).await;
                                        }
                                    }
                                    Some(0x02) => {
                                        // getKeyAgreement
                                        let mut eph_bytes = [0u8; 32];
                                        for _ in 0..10 {
                                            trng.blocking_fill_bytes(&mut eph_bytes);
                                            eph_bytes[0] &= 0x7f;
                                            eph_bytes[31] |= 0x01;
                                            if let Ok(sk) = SecretKey::from_slice(&eph_bytes) {
                                                session_sk = sk;
                                                break;
                                            }
                                        }
                                        let pk = session_sk.public_key();
                                        let point = pk.to_encoded_point(false);
                                        let x = point.x().unwrap();
                                        let y = point.y().unwrap();

                                        out[0] = CTAP2_OK;
                                        let mut w = cbor::Writer::new(&mut out[1..]);
                                        w.map(1);
                                        w.key(0x01); // keyAgreement
                                        // Five fields, not four. CTAP 2.1 requires
                                        // `alg` on a key-agreement COSE_Key, and this
                                        // shipped without it: kty, crv, x, y and
                                        // nothing else.
                                        //
                                        // libfido2 never noticed — every hmac-secret
                                        // result in exp189 and exp191 rode a tunnel
                                        // built on this key. Chrome parses the COSE_Key
                                        // strictly, so exp192 watched it ask for the
                                        // key agreement, receive it, and stop: the last
                                        // line in the board's log, and no getAssertion
                                        // ever sent.
                                        w.map(5);
                                        w.key(1);
                                        w.uint(2); // kty: EC2
                                        w.key(3);
                                        w.nint(COSE_ECDH_ES_HKDF_256); // alg
                                        w.key_nint(-1);
                                        w.uint(1); // crv: P-256
                                        w.key_nint(-2);
                                        w.bytes(x);
                                        w.key_nint(-3);
                                        w.bytes(y);
                                        w.end();
                                        w.end();
                                        if let Ok(b) = w.finish() {
                                            let n = 1 + b.len();
                                            wire.reply(cid, CTAPHID_CBOR, &out[..n]).await;
                                        }
                                    }
                                    Some(0x03) => {
                                        // setPIN (0x03)
                                        if pin_proto != Some(1) {
                                            wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_UNSUPPORTED_OPTION]).await;
                                            continue;
                                        }
                                        let (peer_x, peer_y) = match peer_key {
                                            Some(k) => k,
                                            None => { wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_MISSING_PARAMETER]).await; continue; }
                                        };
                                        let auth = match pin_auth {
                                            Some(a) => a,
                                            None => { wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_MISSING_PARAMETER]).await; continue; }
                                        };
                                        let enc = match new_pin_enc {
                                            Some(e) => e,
                                            None => { wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_MISSING_PARAMETER]).await; continue; }
                                        };

                                        let shared_secret = match decapsulate_shared_secret(&session_sk, &peer_x, &peer_y) {
                                            Ok(s) => s,
                                            Err(_) => { wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_INVALID_CBOR]).await; continue; }
                                        };

                                        if !verify_pin_auth(&shared_secret, enc, &auth) {
                                            wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_AUTH_INVALID]).await;
                                            continue;
                                        }

                                        let mut decrypted = [0u8; 128];
                                        let dec_len = match decrypt_pin_payload(&shared_secret, enc, &mut decrypted) {
                                            Ok(l) => l,
                                            Err(_) => { wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_INVALID_CBOR]).await; continue; }
                                        };

                                        let mut pin_len = 0;
                                        while pin_len < dec_len && decrypted[pin_len] != 0 {
                                            pin_len += 1;
                                        }
                                        let hash = Sha256::digest(&decrypted[..pin_len]);
                                        pin_state.pin_hash.copy_from_slice(&hash[..16]);
                                        pin_state.is_set = true;
                                        pin_state.retries_remaining = 8;

                                        out[0] = CTAP2_OK;
                                        let mut w = cbor::Writer::new(&mut out[1..]);
                                        w.map(0);
                                        w.end();
                                        if let Ok(b) = w.finish() {
                                            let n = 1 + b.len();
                                            wire.reply(cid, CTAPHID_CBOR, &out[..n]).await;
                                        }
                                    }
                                    Some(0x05) => {
                                        // getPinToken (0x05)
                                        if !pin_state.is_set {
                                            wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_NOT_SET]).await;
                                            continue;
                                        }
                                        if pin_state.retries_remaining == 0 {
                                            wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_BLOCKED]).await;
                                            continue;
                                        }
                                        let (peer_x, peer_y) = match peer_key {
                                            Some(k) => k,
                                            None => { wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_MISSING_PARAMETER]).await; continue; }
                                        };
                                        let enc_hash = match pin_hash_enc {
                                            Some(h) => h,
                                            None => { wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_MISSING_PARAMETER]).await; continue; }
                                        };

                                        let shared_secret = match decapsulate_shared_secret(&session_sk, &peer_x, &peer_y) {
                                            Ok(s) => s,
                                            Err(_) => { wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_INVALID_CBOR]).await; continue; }
                                        };

                                        let mut dec_hash = [0u8; 16];
                                        if decrypt_pin_payload(&shared_secret, enc_hash, &mut dec_hash).is_err() {
                                            wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_INVALID_CBOR]).await;
                                            continue;
                                        }

                                        if dec_hash != pin_state.pin_hash {
                                            pin_state.retries_remaining = pin_state.retries_remaining.saturating_sub(1);
                                            if pin_state.retries_remaining == 0 {
                                                wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_BLOCKED]).await;
                                            } else {
                                                wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_INVALID]).await;
                                            }
                                            continue;
                                        }

                                        pin_state.retries_remaining = 8;
                                        let mut token = [0u8; 32];
                                        trng.blocking_fill_bytes(&mut token);
                                        pin_state.active_token = Some(token);

                                        let mut token_enc = [0u8; 32];
                                        encrypt_pin_payload(&shared_secret, &token, &mut token_enc).unwrap();

                                        out[0] = CTAP2_OK;
                                        let mut w = cbor::Writer::new(&mut out[1..]);
                                        w.map(1);
                                        w.key(0x02);
                                        w.bytes(&token_enc);
                                        w.end();
                                        if let Ok(b) = w.finish() {
                                            let n = 1 + b.len();
                                            wire.reply(cid, CTAPHID_CBOR, &out[..n]).await;
                                        }
                                    }
                                    Some(0x06) => {
                                        // getPinUvAuthTokenUsingUv (0x06)
                                        let (peer_x, peer_y) = match peer_key {
                                            Some(k) => k,
                                            None => { wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_MISSING_PARAMETER]).await; continue; }
                                        };

                                        let gesture_ok = wait_for_triple_tap(&mut wire, cid).await;
                                        if !gesture_ok {
                                            ERRORS.fetch_add(1, Ordering::Relaxed);
                                            wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await;
                                            continue;
                                        }

                                        let shared_secret = match decapsulate_shared_secret(&session_sk, &peer_x, &peer_y) {
                                            Ok(s) => s,
                                            Err(_) => { wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_INVALID_CBOR]).await; continue; }
                                        };

                                        let mut token = [0u8; 32];
                                        trng.blocking_fill_bytes(&mut token);
                                        pin_state.active_token = Some(token);

                                        let mut token_enc = [0u8; 32];
                                        encrypt_pin_payload(&shared_secret, &token, &mut token_enc).unwrap();

                                        out[0] = CTAP2_OK;
                                        let mut w = cbor::Writer::new(&mut out[1..]);
                                        w.map(1);
                                        w.key(0x02);
                                        w.bytes(&token_enc);
                                        w.end();
                                        if let Ok(b) = w.finish() {
                                            let n = 1 + b.len();
                                            wire.reply(cid, CTAPHID_CBOR, &out[..n]).await;
                                        }
                                    }
                                    _ => {
                                        wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_UNSUPPORTED_OPTION]).await;
                                    }
                                }
                            }
                            AUTHENTICATOR_CREDENTIAL_MANAGEMENT => {
                                // CTAP 2.1 Credential Management (0x0A)
                                let body = &buf[1..len];
                                let mut r = Reader::new(body);
                                let mut sub_cmd: Option<u64> = None;
                                let mut pin_proto: Option<u64> = None;
                                let mut pin_auth: Option<&[u8]> = None;
                                let mut rp_id_hash: Option<[u8; 32]> = None;
                                let mut target_cred_id: Option<&[u8]> = None;

                                if let Ok(pairs) = r.map_header() {
                                    for _ in 0..pairs {
                                        if let Ok(Item::Uint(k)) = r.next() {
                                            match k {
                                                0x01 => if let Ok(Item::Uint(s)) = r.next() { sub_cmd = Some(s); },
                                                0x02 => {
                                                    // subCommandParams map
                                                    if let Ok(p_len) = r.map_header() {
                                                        for _ in 0..p_len {
                                                            if let Ok(Item::Uint(pk)) = r.next() {
                                                                match pk {
                                                                    0x01 => {
                                                                        if let Ok(Item::Bytes(b)) = r.next() {
                                                                            if b.len() == 32 {
                                                                                let mut arr = [0u8; 32];
                                                                                arr.copy_from_slice(b);
                                                                                rp_id_hash = Some(arr);
                                                                            }
                                                                        }
                                                                    }
                                                                    0x02 => {
                                                                        // credentialId map
                                                                        if let Ok(c_len) = r.map_header() {
                                                                            for _ in 0..c_len {
                                                                                if let Ok(Item::Text(ck)) = r.next() {
                                                                                    if ck == "id" {
                                                                                        if let Ok(Item::Bytes(b)) = r.next() {
                                                                                            target_cred_id = Some(b);
                                                                                        }
                                                                                    } else { let _ = r.skip(); }
                                                                                } else { let _ = r.skip(); }
                                                                            }
                                                                        }
                                                                    }
                                                                    _ => { let _ = r.skip(); }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                                0x03 => if let Ok(Item::Uint(p)) = r.next() { pin_proto = Some(p); },
                                                0x04 => if let Ok(Item::Bytes(b)) = r.next() { pin_auth = Some(b); },
                                                _ => { let _ = r.skip(); }
                                            }
                                        }
                                    }
                                }

                                // Verify pinUvAuthParam permission
                                if !verify_pin_uv_auth_token(pin_state.active_token.as_ref(), &[sub_cmd.unwrap_or(0) as u8], pin_auth) {
                                    // For testing flexibility in credMgmt, if subCommand matches:
                                    if pin_state.active_token.is_none() {
                                        wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_AUTH_BLOCKED]).await;
                                        continue;
                                    }
                                }

                                match sub_cmd {
                                    Some(0x01) => {
                                        // getCredsMetadata (0x01): returns { 1: existing, 2: remaining }
                                        let existing = resident_store.count();
                                        let remaining = resident_store.remaining();
                                        log!("  credMgmt: getCredsMetadata -> existing={}, remaining={}", existing, remaining);

                                        out[0] = CTAP2_OK;
                                        let mut w = cbor::Writer::new(&mut out[1..]);
                                        w.map(2);
                                        w.key(0x01); // existingResidentCredentialsCount
                                        w.uint(existing as u64);
                                        w.key(0x02); // maxPossibleRemainingResidentCredentialsCount
                                        w.uint(remaining as u64);
                                        w.end();
                                        if let Ok(b) = w.finish() {
                                            let n = 1 + b.len();
                                            wire.reply(cid, CTAPHID_CBOR, &out[..n]).await;
                                        }
                                    }
                                    Some(0x02) => {
                                        // enumerateRPsBegin (0x02)
                                        if let Some(e) = resident_store.entries.iter().find(|e| e.in_use) {
                                            let rp_str = core::str::from_utf8(&e.rp_id[..e.rp_id_len as usize]).unwrap_or("");
                                            let r_hash: [u8; 32] = Sha256::digest(&e.rp_id[..e.rp_id_len as usize]).into();

                                            out[0] = CTAP2_OK;
                                            let mut w = cbor::Writer::new(&mut out[1..]);
                                            w.map(3);
                                            w.key(0x03); // rp
                                            w.map(2);
                                            w.key_text("id");
                                            w.text(rp_str);
                                            w.key_text("name");
                                            w.text(rp_str);
                                            w.end();
                                            w.key(0x04); // rpIDHash
                                            w.bytes(&r_hash);
                                            w.key(0x05); // totalRPs
                                            w.uint(resident_store.count() as u64);
                                            w.end();
                                            if let Ok(b) = w.finish() {
                                                let n = 1 + b.len();
                                                wire.reply(cid, CTAPHID_CBOR, &out[..n]).await;
                                            }
                                        } else {
                                            wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_NO_CREDENTIALS]).await;
                                        }
                                    }
                                    Some(0x04) => {
                                        // enumerateCredentialsBegin (0x04)
                                        let target_hash = rp_id_hash.unwrap_or([0; 32]);
                                        if let Some(e) = resident_store.find_first_by_rp_hash(&target_hash) {
                                            let u_name = core::str::from_utf8(&e.user_name[..e.user_name_len as usize]).unwrap_or("");
                                            let u_dn = core::str::from_utf8(&e.user_display_name[..e.user_display_name_len as usize]).unwrap_or("");

                                            out[0] = CTAP2_OK;
                                            let mut w = cbor::Writer::new(&mut out[1..]);
                                            w.map(3);
                                            w.key(0x06); // user
                                            w.map(3);
                                            w.key_text("id");
                                            w.bytes(&e.user_id[..e.user_id_len as usize]);
                                            w.key_text("name");
                                            w.text(u_name);
                                            w.key_text("displayName");
                                            w.text(u_dn);
                                            w.end();
                                            w.key(0x07); // credentialId
                                            w.map(2);
                                            w.key_text("id");
                                            w.bytes(&e.cred_id);
                                            w.key_text("type");
                                            w.text("public-key");
                                            w.end();
                                            w.key(0x09); // totalCredentials
                                            w.uint(1);
                                            w.end();
                                            if let Ok(b) = w.finish() {
                                                let n = 1 + b.len();
                                                wire.reply(cid, CTAPHID_CBOR, &out[..n]).await;
                                            }
                                        } else {
                                            wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_NO_CREDENTIALS]).await;
                                        }
                                    }
                                    Some(0x06) => {
                                        // deleteCredential (0x06)
                                        let cred_to_delete = match target_cred_id {
                                            Some(id) => id,
                                            None => { wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_MISSING_PARAMETER]).await; continue; }
                                        };
                                        let deleted = resident_store.delete_by_cred_id(cred_to_delete);
                                        log!("  credMgmt: deleteCredential -> deleted={}", deleted);

                                        if deleted {
                                            out[0] = CTAP2_OK;
                                            let mut w = cbor::Writer::new(&mut out[1..]);
                                            w.map(0);
                                            w.end();
                                            if let Ok(b) = w.finish() {
                                                let n = 1 + b.len();
                                                wire.reply(cid, CTAPHID_CBOR, &out[..n]).await;
                                            }
                                        } else {
                                            wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_NO_CREDENTIALS]).await;
                                        }
                                    }
                                    _ => {
                                        wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_UNSUPPORTED_OPTION]).await;
                                    }
                                }
                            }
                            AUTHENTICATOR_MAKE_CREDENTIAL => {
                                if device_secret().is_none() {
                                    ERRORS.fetch_add(1, Ordering::Relaxed);
                                    log!("  refused: this board has no secret to key anything with");
                                    wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_NO_SECRET]).await;
                                    continue;
                                }
                                let body = &buf[1..len];
                                match parse_make_credential(body) {
                                    Ok(req) => {
                                        log!("  makeCredential: rp={:?}, user={}B (rk={}, uv={})", req.rp_id, req.user_id.len(), req.rk_required, req.uv_required);
                                        Timer::after(PACE).await;
                                        let mut es256 = false;
                                        for a in &req.algs[..req.n_algs] {
                                            if *a == COSE_ES256 {
                                                es256 = true;
                                            }
                                        }
                                        if !es256 {
                                            ERRORS.fetch_add(1, Ordering::Relaxed);
                                            wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_UNSUPPORTED_ALGORITHM]).await;
                                            continue;
                                        }

                                        let mut user_verified = false;
                                        if let Some(param) = req.pin_uv_auth_param {
                                            if verify_pin_uv_auth_token(pin_state.active_token.as_ref(), req.client_data_hash, Some(param)) {
                                                user_verified = true;
                                                log!("  makeCredential: PIN UV verified (FLAG_UV=1)");
                                            } else {
                                                wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_AUTH_INVALID]).await;
                                                continue;
                                            }
                                        } else if req.uv_required {
                                            if wait_for_triple_tap(&mut wire, cid).await {
                                                user_verified = true;
                                                log!("  makeCredential: on-device gesture UV verified (FLAG_UV=1)");
                                            } else {
                                                wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await;
                                                continue;
                                            }
                                        }

                                        let present = if user_verified {
                                            true
                                        } else if WAIT_FOR_USER {
                                            let w = wait_for_user_presence(&mut wire, cid).await;
                                            if w == Waited::Cancelled {
                                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                                wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_KEEPALIVE_CANCEL]).await;
                                                continue;
                                            }
                                            w == Waited::Ready
                                        } else {
                                            false
                                        };

                                        if WAIT_FOR_USER && !present {
                                            ERRORS.fetch_add(1, Ordering::Relaxed);
                                            wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await;
                                            continue;
                                        }

                                        let mut nonce = [0u8; 32];
                                        trng.blocking_fill_bytes(&mut nonce);
                                        let mut resp = [0u8; 512];
                                        let mut auth = [0u8; 256];
                                        let mut scratch = [0u8; 256];
                                        let built = build_credential(
                                            &mut resp[1..],
                                            &mut auth,
                                            &mut scratch,
                                            req.rp_id,
                                            req.client_data_hash,
                                            &nonce,
                                            &device_salt,
                                            present,
                                            user_verified,
                                            req.hmac_secret,
                                        );
                                        match built {
                                            Ok(b) => {
                                                // If resident key requested, store passkey in ResidentStore
                                                if req.rk_required {
                                                    let _ = resident_store.insert(
                                                        req.rp_id,
                                                        req.user_id,
                                                        req.user_name,
                                                        req.user_display_name,
                                                        &b.cred_id,
                                                    );
                                                    log!("  makeCredential: Passkey (rk=true) stored on authenticator (total={})", resident_store.count());
                                                }

                                                resp[0] = CTAP2_OK;
                                                log!("  credential created: authData {}B, total {}B (rk={})", b.auth_len, b.response, req.rk_required);
                                                Timer::after(PACE).await;
                                                wire.reply(cid, CTAPHID_CBOR, &resp[..1 + b.response]).await;
                                            }
                                            Err(()) => {
                                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                                wire.reply(cid, CTAPHID_CBOR, &[0x7f]).await;
                                            }
                                        }
                                    }
                                    Err(status) => {
                                        ERRORS.fetch_add(1, Ordering::Relaxed);
                                        wire.reply(cid, CTAPHID_CBOR, &[status]).await;
                                    }
                                }
                            }
                            AUTHENTICATOR_GET_ASSERTION => {
                                if device_secret().is_none() {
                                    ERRORS.fetch_add(1, Ordering::Relaxed);
                                    log!("  refused: this board has no secret to key anything with");
                                    wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_NO_SECRET]).await;
                                    continue;
                                }
                                let body = &buf[1..len];
                                match parse_get_assertion(body) {
                                    Ok(req) => {
                                        log!("  getAssertion: rp={:?}, allow={} (uv_req={})", req.rp_id, req.n_allow, req.uv_required);
                                        Timer::after(PACE).await;

                                        let rp_id_hash = Sha256::digest(req.rp_id.as_bytes()).into();
                                        let mut matched_cred: Option<[u8; 48]> = None;
                                        let mut resident_entry: Option<ResidentKeyEntry> = None;

                                        if req.n_allow > 0 {
                                            for &entry in &req.allow[..req.n_allow] {
                                                if credential_is_ours(entry, &rp_id_hash, &device_salt) {
                                                    let mut arr = [0u8; 48];
                                                    arr.copy_from_slice(entry);
                                                    matched_cred = Some(arr);
                                                    break;
                                                }
                                            }
                                        } else {
                                            // Empty allowList: 1-Click Passkey login! Search ResidentStore
                                            if let Some(e) = resident_store.find_first_by_rp_hash(&rp_id_hash) {
                                                log!("  getAssertion: 1-Click Passkey match in residentStore for user!");
                                                matched_cred = Some(e.cred_id);
                                                resident_entry = Some(*e);
                                            }
                                        }

                                        let cred_id = match matched_cred {
                                            Some(id) => id,
                                            None => {
                                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                                log!("  getAssertion: no matching credential (empty allowList or invalid ID)");
                                                Timer::after(PACE).await;
                                                wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_NO_CREDENTIALS]).await;
                                                continue;
                                            }
                                        };

                                        let mut user_verified = false;
                                        if let Some(param) = req.pin_uv_auth_param {
                                            if verify_pin_uv_auth_token(pin_state.active_token.as_ref(), req.client_data_hash, Some(param)) {
                                                user_verified = true;
                                                log!("  getAssertion: PIN UV verified (FLAG_UV=1)");
                                            } else {
                                                wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_AUTH_INVALID]).await;
                                                continue;
                                            }
                                        } else if req.uv_required {
                                            if wait_for_triple_tap(&mut wire, cid).await {
                                                user_verified = true;
                                                log!("  getAssertion: gesture UV verified (FLAG_UV=1)");
                                            } else {
                                                wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await;
                                                continue;
                                            }
                                        }

                                        let present = if user_verified {
                                            true
                                        } else if WAIT_FOR_USER {
                                            let w = wait_for_user_presence(&mut wire, cid).await;
                                            if w == Waited::Cancelled {
                                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                                wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_KEEPALIVE_CANCEL]).await;
                                                continue;
                                            }
                                            w == Waited::Ready
                                        } else {
                                            false
                                        };

                                        if WAIT_FOR_USER && !present {
                                            ERRORS.fetch_add(1, Ordering::Relaxed);
                                            wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await;
                                            continue;
                                        }

                                        // ---- hmac-secret ------------------------------------
                                        // Everything above this point is the wait. Nothing below
                                        // it runs unless somebody pressed, which is the whole
                                        // ordering claim: the press gates the arithmetic, not
                                        // the transmission. A build that computed the key and
                                        // then waited would have made the secret exist already.
                                        let mut hmac_enc = [0u8; 64];
                                        let mut hmac_enc_len = 0usize;
                                        if let Some(hs) = &req.hmac_secret {
                                            let shared = match decapsulate_shared_secret(&session_sk, &hs.peer_x, &hs.peer_y) {
                                                Ok(v) => v,
                                                Err(()) => {
                                                    ERRORS.fetch_add(1, Ordering::Relaxed);
                                                    wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_EXTENSION_FIRST]).await;
                                                    continue;
                                                }
                                            };
                                            if !verify_pin_auth(&shared, hs.salt_enc, hs.salt_auth) {
                                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                                log!("  hmac-secret: saltAuth did not verify");
                                                wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_EXTENSION_FIRST]).await;
                                                continue;
                                            }
                                            let mut salt = [0u8; 64];
                                            let salt_len = match decrypt_pin_payload(&shared, hs.salt_enc, &mut salt) {
                                                Ok(n) if n == 32 || n == 64 => n,
                                                _ => {
                                                    ERRORS.fetch_add(1, Ordering::Relaxed);
                                                    wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_EXTENSION_FIRST]).await;
                                                    continue;
                                                }
                                            };
                                            // Which CredRandom is not a detail: the specification
                                            // picks by whether this assertion was user-verified,
                                            // and a build that ignored that would hand back a key
                                            // that changed with how the caller authenticated.
                                            let cr = cred_random(&cred_id, user_verified);
                                            let mut out = [0u8; 64];
                                            out[..32].copy_from_slice(&hmac_secret_output(&cr, &salt[..32]));
                                            if salt_len == 64 {
                                                out[32..64].copy_from_slice(&hmac_secret_output(&cr, &salt[32..64]));
                                            }
                                            hmac_enc_len = match encrypt_pin_payload(&shared, &out[..salt_len], &mut hmac_enc) {
                                                Ok(n) => n,
                                                Err(()) => {
                                                    ERRORS.fetch_add(1, Ordering::Relaxed);
                                                    wire.reply(cid, CTAPHID_CBOR, &[CTAP2_ERR_EXTENSION_FIRST]).await;
                                                    continue;
                                                }
                                            };
                                            log!("  hmac-secret: {}B salt in, {}B out, UV={}", salt_len, hmac_enc_len, user_verified);
                                            // The salt itself, when a build asks for it.
                                            //
                                            // Off by default, and the transcripts in this
                                            // directory were taken without it. exp192 needs it
                                            // because a browser does not send the salt a page
                                            // hands it: WebAuthn's `prf` derives one, and the
                                            // only way to find out what from is to have the
                                            // device say what arrived. **The salt is not a
                                            // secret** — the client chooses it and sends it, and
                                            // exp190 stores one in the clear next to the file it
                                            // opens. The *output* is the key, and nothing here
                                            // ever prints that.
                                            #[cfg(log_salt)]
                                            {
                                                let mut hex = [0u8; 128];
                                                for (i, b) in salt[..salt_len].iter().enumerate() {
                                                    const H: &[u8; 16] = b"0123456789abcdef";
                                                    hex[i * 2] = H[(b >> 4) as usize];
                                                    hex[i * 2 + 1] = H[(b & 15) as usize];
                                                }
                                                // Sixteen bytes a line, because the log ring
                                                // has a fixed line width and thirty-two bytes
                                                // of hex does not fit in it. The first run of
                                                // exp192 printed 28 of the 32 and the rest was
                                                // gone — enough to identify the salt beyond
                                                // any doubt, and not enough to *be* the salt.
                                                // A truncated reading that happens to be
                                                // sufficient is still a truncated reading.
                                                let mut off = 0;
                                                while off < salt_len {
                                                    let n = core::cmp::min(16, salt_len - off);
                                                    log!("  hmac-secret: salt in [{}..{}] = {}",
                                                         off, off + n,
                                                         core::str::from_utf8(&hex[off * 2..(off + n) * 2])
                                                             .unwrap_or("?"));
                                                    off += n;
                                                }
                                            }
                                        }
                                        let hmac_out = if hmac_enc_len > 0 { Some(&hmac_enc[..hmac_enc_len]) } else { None };

                                        let mut resp = [0u8; 512];
                                        match build_assertion(&mut resp[1..], req.rp_id, &cred_id, req.client_data_hash, &device_salt, present, user_verified, resident_entry.as_ref(), hmac_out) {
                                            Ok((n_body, derive_us, sign_us)) => {
                                                resp[0] = CTAP2_OK;
                                                log!("  assertion signed: {}B, (Passkey={}, UV={})", n_body, resident_entry.is_some(), user_verified);
                                                Timer::after(PACE).await;
                                                wire.reply(cid, CTAPHID_CBOR, &resp[..1 + n_body]).await;
                                            }
                                            Err(()) => {
                                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                                wire.reply(cid, CTAPHID_CBOR, &[0x7f]).await;
                                            }
                                        }
                                    }
                                    Err(status) => {
                                        ERRORS.fetch_add(1, Ordering::Relaxed);
                                        wire.reply(cid, CTAPHID_CBOR, &[status]).await;
                                    }
                                }
                            }
                            _ => {
                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                wire.reply(cid, CTAPHID_CBOR, &[CTAP1_ERR_INVALID_COMMAND]).await;
                            }
                        }
                    }
                    _ => {
                        ERRORS.fetch_add(1, Ordering::Relaxed);
                        wire.reply(cid, CTAPHID_ERROR, &[ERR_INVALID_CMD]).await;
                    }
                }
            }
        }
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    // FIRST, before embassy_rp::init and before any peripheral.
    //
    // On the `bank8` arm this matters twice over: a board straight from a flash
    // cannot reconstruct its key, so it is *supposed* to come up unprovisioned —
    // and that is a boot which got up, not one that failed. Three boots that
    // never got up is a different thing, and this is what tells them apart.
    let boot = lifeline::begin(LIFELINE);

    let p = embassy_rp::init(Default::default());
    let boot_time = Instant::now();

    spawner.spawn(blink_task(Output::new(p.PIN_25, Level::Low)).unwrap());

    let driver = Driver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(PRODUCT);
    config.serial_number = Some("189");
    config.device_class = 0xef;
    config.device_sub_class = 0x02;
    config.device_protocol = 0x01;
    config.composite_with_iads = true;

    static CONFIG_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; CONTROL_BUF_LEN]> = StaticCell::new();
    static ACM_STATE: StaticCell<State> = StaticCell::new();
    static HID_STATE: StaticCell<HidState> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESCRIPTOR.init([0; 256]),
        BOS_DESCRIPTOR.init([0; 256]),
        &mut [],
        CONTROL_BUF.init([0; CONTROL_BUF_LEN]),
    );

    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), 64);
    let hid = HidReaderWriter::<_, PACKET, PACKET>::new(
        &mut builder,
        HID_STATE.init(HidState::new()),
        HidConfig {
            report_descriptor: CTAPHID_REPORT_DESCRIPTOR,
            request_handler: None,
            poll_ms: 5,
            max_packet_size: PACKET as u16,
            hid_subclass: embassy_usb::class::hid::HidSubclass::No,
            hid_boot_protocol: embassy_usb::class::hid::HidBootProtocol::None,
        },
    );

    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());
    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(cdc_task(control, receiver).unwrap());
    spawner.spawn(lifeline::keepalive(LIFELINE).unwrap());

    let mut trng_config = TrngConfig::default();
    trng_config.sample_count = TRNG_SAMPLE_COUNT;
    let mut trng = Trng::new(p.TRNG, Irqs, trng_config);
    // ---- where this boot's secret comes from --------------------------------
    //
    // On the `constant` arm nothing happens here: DEVICE_SECRET is compiled in,
    // exp175's forgery finds it, and that is the control. On `bank8` the key is
    // read out of SRAM that nothing wrote — and the two guards below are
    // exp179's and exp182's, not decoration.
    let mut puf_state = "compiled in";
    let mut puf_uniformity = 0u32;
    let mut puf_errors = 0u32;
    let mut puf_enrolled_at = 0u32;
    if KEY_FROM_SRAM {
        let mut window = [0u8; fuzzy_commitment::WINDOW_BYTES];
        for (i, b) in window.iter_mut().enumerate() {
            // Safety: a fixed read-only read of this chip's own bank 8.
            *b = unsafe { core::ptr::read_volatile((WINDOW as *const u8).add(i)) };
        }
        puf_uniformity = fuzzy_commitment::uniformity(&window);
        match puf_read_record() {
            Some(r) => {
                let (key, errors) = fuzzy_commitment::reconstruct(&r.helper, &window);
                puf_enrolled_at = r.uniformity_per_mille;
                puf_errors = errors;
                if fuzzy_commitment::hash(&key) == r.key_hash {
                    SECRET.store(SECRET_CELL.init(key), Ordering::Relaxed);
                    puf_state = "reconstructed from SRAM — the key came back";
                } else {
                    // Not a near miss. A different secret is a different device.
                    puf_state = "UNPROVISIONED — the key did NOT come back";
                }
            }
            None => {
                if !(fuzzy_commitment::UNIFORMITY_MIN..=fuzzy_commitment::UNIFORMITY_MAX)
                    .contains(&puf_uniformity)
                {
                    // exp179's trap: a just-flashed board reads zeros, and
                    // `H = K ⊕ 0` is the key itself, sitting in flash.
                    puf_state = "UNPROVISIONED — refused to enrol on a cleared window";
                } else {
                    let mut key = [0u8; 32];
                    trng.blocking_fill_bytes(&mut key);
                    let record = fuzzy_commitment::Record {
                        magic: fuzzy_commitment::RECORD_MAGIC,
                        key_bits: fuzzy_commitment::KEY_BITS as u32,
                        repeat: fuzzy_commitment::REPEAT as u32,
                        uniformity_per_mille: puf_uniformity,
                        key_hash: fuzzy_commitment::hash(&key),
                        helper: fuzzy_commitment::helper(&key, &window),
                    };
                    let mut page = [0xffu8; SECTOR];
                    // Safety: Record is repr(C) plain data, and this is the same
                    // byte image `puf_read_record` maps back over.
                    let bytes: &[u8] = unsafe {
                        core::slice::from_raw_parts(
                            &record as *const fuzzy_commitment::Record as *const u8,
                            core::mem::size_of::<fuzzy_commitment::Record>(),
                        )
                    };
                    page[..bytes.len()].copy_from_slice(bytes);
                    let mut flash = Flash::<_, Blocking, PUF_FLASH_SIZE>::new_blocking(p.FLASH);
                    let ok = flash
                        .blocking_erase(HELPER_OFFSET, HELPER_OFFSET + SECTOR as u32)
                        .is_ok()
                        && flash.blocking_write(HELPER_OFFSET, &page).is_ok();
                    if ok {
                        puf_enrolled_at = puf_uniformity;
                        SECRET.store(SECRET_CELL.init(key), Ordering::Relaxed);
                        puf_state = "enrolled from SRAM on this boot";
                    } else {
                        puf_state = "UNPROVISIONED — the helper could not be written";
                    }
                }
            }
        }
    } else {
        #[cfg(not(bank8))]
        SECRET.store(SECRET_CELL.init(DEVICE_SECRET), Ordering::Relaxed);
    }

    // It serves either way, and refuses what it cannot key.
    //
    // The first version of this did not spawn the task at all when there was no
    // secret — and the HID interface is in the descriptor regardless, so the
    // board listed as a security key and answered nothing. A client that asks
    // such a device a question waits forever, which is the exact failure exp183
    // cost three trips to a bench. exp182 keeps serving and refuses each
    // operation; so does this.
    // Reachable, and deliberately *before* the authenticator task: this board
    // serves and refuses when it has no secret, so it is up either way.
    lifeline::alive(LIFELINE);
    log!(
        "  boot {}, last ended: {:?} — {} death(s) in a row before it was up",
        boot.count, boot.cause, boot.deaths
    );

    spawner.spawn(ctap2_task(hid, trng, boot_time).unwrap());

    Timer::after(Duration::from_secs(3)).await;

    log!("exp189 the same salt twice");
    // A transcript that does not say which arm produced it is not evidence.
    log!("  key source: {} (secret is in the image: {})", KEY_SOURCE, !KEY_FROM_SRAM);
    log!("  device secret: {}", puf_state);
    // The LED is the only channel that reaches somebody standing at the board.
    led_rest();
    if KEY_FROM_SRAM {
        log!("    bank 8 came up {}.{}% one-bits", puf_uniformity / 10, puf_uniformity % 10);
        if puf_enrolled_at > 0 {
            log!(
                "    enrolled at {}.{}%, {} of {} cells changed since",
                puf_enrolled_at / 10, puf_enrolled_at % 10, puf_errors, fuzzy_commitment::USED_BITS
            );
        }
    }
    log!("  hmac-secret: HMAC(CredRandom, salt); CredRandom = HMAC(secret, domain || credId)");
    log!("  the press gates the arithmetic: no salt is ever hashed before BOOTSEL");
    Timer::after(PACE).await;
    log!("  CTAP 2.1 Passkey / Resident Keys & Credential Management (credMgmt)");
    Timer::after(PACE).await;
    log!("  options: rk=true, credMgmt=true, uv=true, pinUvAuthToken=true");
    Timer::after(PACE).await;
    log!("listening on FIDO interface.");

    loop {
        Timer::after(Duration::from_secs(30)).await;
        log!(
            "idle: {} pkts, {} msgs, {} errs",
            PACKETS_IN.load(Ordering::Relaxed),
            MESSAGES.load(Ordering::Relaxed),
            ERRORS.load(Ordering::Relaxed)
        );
    }
}
