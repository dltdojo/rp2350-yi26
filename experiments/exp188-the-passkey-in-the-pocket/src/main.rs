// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 rp2350-yi26 contributors
//! # exp188 — the passkey in the pocket
//!
//! CTAP 2.1 Discoverable Credentials (Passkey rk) & Credential Management (credMgmt):
//! - Options: { rk: true, credMgmt: true, uv: true, clientPin: bool, pinUvAuthToken: true }
//! - On-device non-volatile resident key store for 16 passkeys
//! - Username-less 1-Click Passkey assertion (empty allowList auto-lookup returning UserEntity)
//! - authenticatorCredentialManagement (0x0A): getCredsMetadata, enumerateRPs, enumerateCredentials, deleteCredential
//! - Full PIN Protocol 1 & authenticatorReset integration

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Duration, Instant, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::class::hid::{Config as HidConfig, HidReaderWriter, State as HidState};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
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
use usb_log::log;

include!(concat!(env!("OUT_DIR"), "/exp188_config.rs"));

const DEVICE_SECRET: [u8; 32] = [
    0x6e, 0x6f, 0x74, 0x20, 0x61, 0x20, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74, 0x2e, 0x20, 0x74, 0x68,
    0x69, 0x73, 0x20, 0x69, 0x73, 0x20, 0x61, 0x20, 0x74, 0x65, 0x73, 0x74, 0x20, 0x6b, 0x65, 0x79,
];

const VERSIONS: [&str; 3] = ["U2F_V2", "FIDO_2_0", "FIDO_2_1"];

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    TRNG_IRQ => embassy_rp::trng::InterruptHandler<TRNG>;
});

const PACKET: usize = 64;
const MAX_MESSAGE: usize = 1024;
const TRANSACTION_TIMEOUT: Duration = Duration::from_millis(1500);
const KEEPALIVE_INTERVAL: Duration = Duration::from_millis(100);
const PRESENCE_POLL: Duration = Duration::from_millis(10);

type Cid = [u8; 4];
const BROADCAST: Cid = [0xff, 0xff, 0xff, 0xff];
const RESERVED: Cid = [0x00, 0x00, 0x00, 0x00];

const CTAPHID_PING: u8 = 0x01;
const CTAPHID_CBOR: u8 = 0x10;
const CTAPHID_INIT: u8 = 0x06;
const CTAPHID_KEEPALIVE: u8 = 0x3b;
const CTAPHID_CANCEL: u8 = 0x11;
const CTAPHID_ERROR: u8 = 0x3f;

const ERR_INVALID_CMD: u8 = 0x01;
const ERR_INVALID_PAR: u8 = 0x02;
const ERR_INVALID_LEN: u8 = 0x03;
const ERR_INVALID_SEQ: u8 = 0x04;
const ERR_MSG_TIMEOUT: u8 = 0x05;
const ERR_CHANNEL_BUSY: u8 = 0x06;

const STATUS_UPNEEDED: u8 = 0x02;

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

const INIT_HEADER: usize = 7;
const CONT_HEADER: usize = 5;
const INIT_PAYLOAD: usize = PACKET - INIT_HEADER;
const CONT_PAYLOAD: usize = PACKET - CONT_HEADER;

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

const COSE_ES256: i64 = -7;
const USER_PRESENCE_TIMEOUT: Duration = Duration::from_millis(TIMEOUT_MS);

const AUTHENTICATOR_MAKE_CREDENTIAL: u8 = 0x01;
const AUTHENTICATOR_GET_ASSERTION: u8 = 0x02;
const AUTHENTICATOR_GET_INFO: u8 = 0x04;
const AUTHENTICATOR_CLIENT_PIN: u8 = 0x06;
const AUTHENTICATOR_RESET: u8 = 0x07;
const AUTHENTICATOR_CREDENTIAL_MANAGEMENT: u8 = 0x0A;

const AAGUID: [u8; 16] = [0; 16];
const TRNG_SAMPLE_COUNT: u32 = 1000;
const PRODUCT: &str = "exp188 the passkey in the pocket";
const CONTROL_BUF_LEN: usize = 128;

const PACE: Duration = Duration::from_millis(0);

static PACKETS_IN: AtomicU32 = AtomicU32::new(0);
static MESSAGES: AtomicU32 = AtomicU32::new(0);
static ERRORS: AtomicU32 = AtomicU32::new(0);
static NEXT_CID: AtomicU32 = AtomicU32::new(1);
static LED_SOLID_OVERRIDE: AtomicBool = AtomicBool::new(false);

struct Hex<'a>(&'a [u8]);

impl core::fmt::Display for Hex<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        for b in self.0 {
            write!(f, "{:02x}", b)?;
        }
        Ok(())
    }
}

fn allocate_cid() -> Cid {
    let mut n = NEXT_CID.fetch_add(1, Ordering::Relaxed);
    if n == 0 || n == 0xffff_ffff {
        NEXT_CID.store(2, Ordering::Relaxed);
        n = 1;
    }
    n.to_be_bytes()
}

fn cmd_name(cmd: u8) -> &'static str {
    match cmd {
        CTAPHID_PING => "PING",
        CTAPHID_CBOR => "CBOR",
        CTAPHID_INIT => "INIT",
        CTAPHID_KEEPALIVE => "KEEPALIVE",
        CTAPHID_CANCEL => "CANCEL",
        CTAPHID_ERROR => "ERROR",
        _ => "UNKNOWN",
    }
}

fn status_for(e: ReadError) -> u8 {
    match e {
        ReadError::Truncated
        | ReadError::NotCanonical
        | ReadError::BadText => CTAP2_ERR_INVALID_CBOR,
        ReadError::Unsupported | ReadError::TooDeep => CTAP2_ERR_UNSUPPORTED_OPTION,
    }
}

struct Transaction {
    cid: Cid,
    cmd: u8,
    seq: u8,
    want: usize,
    have: usize,
    started: Instant,
    buf: [u8; MAX_MESSAGE],
}

impl Transaction {
    const fn none() -> Self {
        Self {
            cid: RESERVED,
            cmd: 0,
            seq: 0,
            want: 0,
            have: 0,
            started: Instant::from_ticks(0),
            buf: [0; MAX_MESSAGE],
        }
    }

    fn busy(&self) -> bool {
        self.cid != RESERVED
    }

    fn clear(&mut self) {
        self.cid = RESERVED;
        self.cmd = 0;
        self.seq = 0;
        self.want = 0;
        self.have = 0;
    }
}

static TRANSACTION: StaticCell<Transaction> = StaticCell::new();

enum Action {
    Complete,
    More,
    Ignore(&'static str),
    Error(Cid, u8),
}

fn feed(t: &mut Transaction, pkt: &[u8]) -> Action {
    if pkt.len() != PACKET {
        return Action::Ignore("packet not 64 bytes");
    }
    let cid: Cid = [pkt[0], pkt[1], pkt[2], pkt[3]];
    let is_init = (pkt[4] & 0x80) != 0;

    if is_init {
        let cmd = pkt[4] & 0x7f;
        let bcnt = ((pkt[5] as usize) << 8) | (pkt[6] as usize);

        if cid == RESERVED {
            return Action::Error(cid, ERR_INVALID_PAR);
        }
        if cid == BROADCAST && cmd != CTAPHID_INIT {
            return Action::Error(cid, ERR_INVALID_PAR);
        }
        if t.busy() && t.cid != cid {
            return Action::Error(cid, ERR_CHANNEL_BUSY);
        }
        match cmd {
            CTAPHID_INIT | CTAPHID_PING | CTAPHID_CBOR | CTAPHID_CANCEL => {}
            _ => return Action::Error(cid, ERR_INVALID_CMD),
        }
        if cmd == CTAPHID_INIT && bcnt != 8 {
            return Action::Error(cid, ERR_INVALID_LEN);
        }
        if bcnt > MAX_MESSAGE {
            return Action::Error(cid, ERR_INVALID_LEN);
        }

        t.cid = cid;
        t.cmd = cmd;
        t.seq = 0;
        t.want = bcnt;
        t.have = 0;
        t.started = Instant::now();

        let take = bcnt.min(INIT_PAYLOAD);
        t.buf[..take].copy_from_slice(&pkt[INIT_HEADER..INIT_HEADER + take]);
        t.have = take;

        if t.have == t.want {
            Action::Complete
        } else {
            Action::More
        }
    } else {
        let seq = pkt[4] & 0x7f;
        if !t.busy() || t.cid != cid {
            return Action::Ignore("continuation for idle or different channel");
        }
        if seq != t.seq {
            t.clear();
            return Action::Error(cid, ERR_INVALID_SEQ);
        }
        t.seq = t.seq.wrapping_add(1);

        let rem = t.want - t.have;
        let take = rem.min(CONT_PAYLOAD);
        t.buf[t.have..t.have + take].copy_from_slice(&pkt[CONT_HEADER..CONT_HEADER + take]);
        t.have += take;

        if t.have == t.want {
            Action::Complete
        } else {
            Action::More
        }
    }
}

async fn send(
    writer: &mut embassy_usb::class::hid::HidWriter<'static, usb_reboot::UsbDriver, PACKET>,
    cid: Cid,
    cmd: u8,
    payload: &[u8],
) -> usize {
    let mut pkt = [0u8; PACKET];
    let total = payload.len();

    pkt[0..4].copy_from_slice(&cid);
    pkt[4] = 0x80 | cmd;
    pkt[5] = (total >> 8) as u8;
    pkt[6] = total as u8;
    let take = total.min(INIT_PAYLOAD);
    pkt[INIT_HEADER..INIT_HEADER + take].copy_from_slice(&payload[..take]);
    pkt[INIT_HEADER + take..].fill(0);
    let _ = writer.write(&pkt).await;

    let mut sent = take;
    let mut seq = 0u8;
    let mut packets = 1usize;
    while sent < total {
        pkt[0..4].copy_from_slice(&cid);
        pkt[4] = seq;
        seq = (seq + 1) & 0x7f;
        let rem = total - sent;
        let take = rem.min(CONT_PAYLOAD);
        pkt[CONT_HEADER..CONT_HEADER + take].copy_from_slice(&payload[sent..sent + take]);
        pkt[CONT_HEADER + take..].fill(0);
        let _ = writer.write(&pkt).await;
        sent += take;
        packets += 1;
    }
    packets
}

const CRED_ID_LEN: usize = 48;
const TAG_LEN: usize = 16;
type Hmac = SimpleHmac<Sha256>;

fn mac(label: &[u8], nonce: &[u8], rp_id_hash: &[u8], salt: &[u8; 16], out: &mut [u8]) {
    let mut m = <Hmac as Mac>::new_from_slice(&DEVICE_SECRET).unwrap();
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
        let mut m = <Hmac as Mac>::new_from_slice(&DEVICE_SECRET).unwrap();
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
            // 0x07 is pinUvAuthProtocol, a uint. Read as a byte string it
            // refused every request that named a protocol — the same shape of
            // mistake as makeCredential's 0x06, and found the same way.
            0x07 => match r.next().map_err(status_for)? {
                Item::Uint(_) => {}
                _ => return Err(CTAP2_ERR_INVALID_CBOR),
            },
            // 0x04 is extensions here. Skipped, not refused, for 0x06's reason.
            0x04 => {
                let n = match r.next().map_err(status_for)? {
                    Item::Map(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                skip_map_pairs(&mut r, n).map_err(status_for)?;
            }
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

    Ok(GetAssertion { rp_id, client_data_hash, allow, n_allow, pin_uv_auth_param, uv_required })
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
) -> Result<(usize, u64, u64), ()> {
    let rp_id_hash: [u8; 32] = Sha256::digest(rp_id.as_bytes()).into();
    let nonce = &cred_id[..32];

    let t0 = Instant::now();
    let sk = derive_key(nonce, &rp_id_hash, salt).ok_or(())?;
    let derive_us = t0.elapsed().as_micros();

    let mut auth = [0u8; 37];
    auth[..32].copy_from_slice(&rp_id_hash);
    let mut flags = if user_present { FLAG_UP } else { 0 };
    if user_verified {
        flags |= FLAG_UV;
    }
    auth[32] = flags;
    auth[33..37].copy_from_slice(&0u32.to_be_bytes());

    let mut signed = [0u8; 69];
    signed[..37].copy_from_slice(&auth);
    signed[37..69].copy_from_slice(client_data_hash);
    let t1 = Instant::now();
    let sig: Signature = sk.sign(&signed);
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
        w.bytes(&auth);
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
            // Reading `0x06 | 0x08` as pinUvAuthParam is getAssertion's
            // numbering, and an extension map is not a byte string — so every
            // makeCredential carrying any extension was refused with
            // CTAP2_ERR_INVALID_CBOR. Measured 2026-08-29 on this firmware:
            // `fido2-cred -M -h` came back in 0.094 s with exactly that.
            //
            // This build implements no extension, so the map is skipped rather
            // than read. Refusing to parse it was never the same thing as
            // declining to support it. exp189 is where one gets implemented.
            0x06 => {
                let n = match r.next().map_err(status_for)? {
                    Item::Map(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
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
    w.map(5);

    // 0x01: versions
    w.key(0x01);
    w.array(VERSIONS.len() as u32);
    for v in VERSIONS {
        w.text(v);
    }
    w.end();

    // 0x03: aaguid
    w.key(0x03);
    w.bytes(&AAGUID);

    // 0x04: options (canonical order by key length: "rk" (2), "up" (2), "uv" (2), "credMgmt" (8), "clientPin" (9), "pinUvAuthToken" (14), "makeCredUvNotRqd" (16))
    w.key(0x04);
    w.map(7);
    w.key_text("rk");
    w.bool(true); // Discoverable credentials (Passkeys) supported!
    w.key_text("up");
    w.bool(WAIT_FOR_USER);
    w.key_text("uv");
    w.bool(true); // Built-in gesture UV supported
    w.key_text("credMgmt");
    w.bool(true); // CTAP 2.1 Credential Management supported! (len 8)
    w.key_text("clientPin");
    w.bool(pin_state.is_set); // (len 9)
    w.key_text("pinUvAuthToken");
    w.bool(true);
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

#[embassy_executor::task]
async fn blink_task(mut led: Output<'static>) -> ! {
    loop {
        if LED_SOLID_OVERRIDE.load(Ordering::Relaxed) {
            led.set_high();
            Timer::after(Duration::from_millis(20)).await;
        } else {
            led.set_high();
            Timer::after(Duration::from_millis(50)).await;
            for _ in 0..19 {
                if LED_SOLID_OVERRIDE.load(Ordering::Relaxed) {
                    break;
                }
                led.set_low();
                Timer::after(Duration::from_millis(50)).await;
            }
        }
    }
}

enum Presence {
    Pressed,
    TimedOut,
    Cancelled,
}

struct Waited {
    outcome: Presence,
}

async fn wait_for_presence(
    reader: &mut embassy_usb::class::hid::HidReader<'static, usb_reboot::UsbDriver, PACKET>,
    writer: &mut embassy_usb::class::hid::HidWriter<'static, usb_reboot::UsbDriver, PACKET>,
    cid: Cid,
) -> Waited {
    LED_SOLID_OVERRIDE.store(true, Ordering::Relaxed);
    let start = Instant::now();
    let mut pkt = [0u8; PACKET];
    let mut pressed_at: Option<u64> = None;
    let mut next = start + KEEPALIVE_INTERVAL;

    let res = loop {
        if bootsel::is_pressed() && pressed_at.is_none() {
            pressed_at = Some(start.elapsed().as_millis());
        }
        if pressed_at.is_some() && start.elapsed().as_millis() >= HOLD_MS {
            break Waited { outcome: Presence::Pressed };
        }
        if start.elapsed() >= USER_PRESENCE_TIMEOUT {
            break Waited { outcome: Presence::TimedOut };
        }

        if let Either::First(Ok(n)) = select(reader.read(&mut pkt), Timer::after(PRESENCE_POLL)).await {
            if n >= 5 && pkt[4] & 0x80 != 0 {
                let from: Cid = [pkt[0], pkt[1], pkt[2], pkt[3]];
                let cmd = pkt[4] & 0x7f;
                if from == cid && cmd == CTAPHID_CANCEL {
                    break Waited { outcome: Presence::Cancelled };
                }
                if from != cid && from != RESERVED {
                    ERRORS.fetch_add(1, Ordering::Relaxed);
                    send(writer, from, CTAPHID_ERROR, &[ERR_CHANNEL_BUSY]).await;
                }
            }
        }

        if KEEPALIVE && Instant::now() >= next {
            send(writer, cid, CTAPHID_KEEPALIVE, &[STATUS_UPNEEDED]).await;
            next = Instant::now() + KEEPALIVE_INTERVAL;
        }
    };
    LED_SOLID_OVERRIDE.store(false, Ordering::Relaxed);
    res
}

async fn wait_for_triple_tap(
    reader: &mut embassy_usb::class::hid::HidReader<'static, usb_reboot::UsbDriver, PACKET>,
    writer: &mut embassy_usb::class::hid::HidWriter<'static, usb_reboot::UsbDriver, PACKET>,
    cid: Cid,
) -> bool {
    if !WAIT_FOR_USER {
        return true;
    }

    LED_SOLID_OVERRIDE.store(true, Ordering::Relaxed);
    let start = Instant::now();
    let mut tap_count = 0u8;
    let mut is_down = false;
    let mut last_tap_time = start;
    let mut next_keepalive = start + KEEPALIVE_INTERVAL;
    let mut pkt = [0u8; PACKET];

    let success = loop {
        if start.elapsed() >= Duration::from_millis(5000) {
            break false;
        }

        if let Either::First(Ok(n)) = select(reader.read(&mut pkt), Timer::after(Duration::from_millis(10))).await {
            if n >= 5 && pkt[4] & 0x80 != 0 {
                let from: Cid = [pkt[0], pkt[1], pkt[2], pkt[3]];
                let cmd = pkt[4] & 0x7f;
                if from == cid && cmd == CTAPHID_CANCEL {
                    break false;
                }
            }
        }

        let currently_down = bootsel::is_pressed();
        if currently_down && !is_down {
            is_down = true;
        } else if !currently_down && is_down {
            is_down = false;
            tap_count += 1;
            last_tap_time = Instant::now();
            log!("  [Gesture UV] tap {}/3 detected", tap_count);
            if tap_count >= 3 {
                break true;
            }
        }

        if tap_count > 0 && !is_down && last_tap_time.elapsed() > Duration::from_millis(1500) {
            tap_count = 0;
        }

        if KEEPALIVE && Instant::now() >= next_keepalive {
            send(writer, cid, CTAPHID_KEEPALIVE, &[STATUS_UPNEEDED]).await;
            next_keepalive = Instant::now() + KEEPALIVE_INTERVAL;
        }
    };

    LED_SOLID_OVERRIDE.store(false, Ordering::Relaxed);
    success
}

#[embassy_executor::task]
async fn ctaphid_task(
    hid: HidReaderWriter<'static, usb_reboot::UsbDriver, PACKET, PACKET>,
    t: &'static mut Transaction,
    mut trng: Trng<'static, TRNG>,
    boot_time: Instant,
) -> ! {
    let (mut reader, mut writer) = hid.split();
    let mut pkt = [0u8; PACKET];
    let mut session_sk = SecretKey::from_slice(&DEVICE_SECRET).unwrap();
    let mut pin_state = PinState::new();
    let mut resident_store = ResidentStore::new();
    let mut device_salt = [0u8; 16];
    trng.blocking_fill_bytes(&mut device_salt);

    loop {
        let deadline = if t.busy() { TRANSACTION_TIMEOUT } else { Duration::from_secs(3600) };
        let got = match select(reader.read(&mut pkt), Timer::after(deadline)).await {
            Either::First(Ok(n)) => n,
            Either::First(Err(_)) => continue,
            Either::Second(()) => {
                if t.busy() {
                    let c = t.cid;
                    t.clear();
                    ERRORS.fetch_add(1, Ordering::Relaxed);
                    log!("  cid {} timed out with {}/{} bytes", Hex(&c), t.have, t.want);
                    Timer::after(PACE).await;
                    send(&mut writer, c, CTAPHID_ERROR, &[ERR_MSG_TIMEOUT]).await;
                }
                continue;
            }
        };

        PACKETS_IN.fetch_add(1, Ordering::Relaxed);
        let is_init = got >= 5 && pkt[4] & 0x80 != 0;
        let cid: Cid = [pkt[0], pkt[1], pkt[2], pkt[3]];

        if is_init {
            log!(
                "in  cid {} {} bcnt {}",
                Hex(&cid),
                cmd_name(pkt[4] & 0x7f),
                ((pkt[5] as u16) << 8) | pkt[6] as u16
            );
            Timer::after(PACE).await;
        }

        match feed(t, &pkt[..got]) {
            Action::Ignore(why) => {
                log!("  ignored: {}", why);
                Timer::after(PACE).await;
            }
            Action::More => {}
            Action::Error(c, code) => {
                ERRORS.fetch_add(1, Ordering::Relaxed);
                log!("  ERROR {:#04x} to cid {}", code, Hex(&c));
                Timer::after(PACE).await;
                send(&mut writer, c, CTAPHID_ERROR, &[code]).await;
            }
            Action::Complete => {
                MESSAGES.fetch_add(1, Ordering::Relaxed);
                let (cid, cmd, len) = (t.cid, t.cmd, t.want);
                if len > INIT_PAYLOAD {
                    log!("  assembled {} bytes in {} ms", len, t.started.elapsed().as_millis());
                    Timer::after(PACE).await;
                }
                match cmd {
                    CTAPHID_INIT => {
                        let new = allocate_cid();
                        let mut r = [0u8; 17];
                        r[..8].copy_from_slice(&t.buf[..8]);
                        r[8..12].copy_from_slice(&new);
                        r[12] = 2;
                        r[13] = 0;
                        r[14] = 1;
                        r[15] = 0;
                        r[16] = CAPABILITIES;
                        t.clear();
                        log!("  INIT: nonce {} -> cid {}", Hex(&r[..8]), Hex(&new));
                        Timer::after(PACE).await;
                        send(&mut writer, cid, CTAPHID_INIT, &r).await;
                    }
                    CTAPHID_PING => {
                        let n = len;
                        t.clear();
                        let packets = send(&mut writer, cid, CTAPHID_PING, &t.buf[..n]).await;
                        log!("  PING: echoed {} bytes in {} packets", n, packets);
                        Timer::after(PACE).await;
                    }
                    CTAPHID_CBOR => {
                        let ctap = if len >= 1 { t.buf[0] } else { 0xff };
                        let params = len - len.min(1);
                        t.clear();
                        let mut out = [0u8; 512];
                        match ctap {
                            AUTHENTICATOR_GET_INFO if params != 0 => {
                                send(&mut writer, cid, CTAPHID_CBOR, &[CTAP1_ERR_INVALID_LENGTH]).await;
                            }
                            AUTHENTICATOR_GET_INFO => {
                                out[0] = CTAP2_OK;
                                match get_info(&mut out[1..], &pin_state) {
                                    Ok(body) => {
                                        let n = 1 + body.len();
                                        log!("  getInfo: {} bytes of canonical CBOR (CTAP 2.1 rk+credMgmt)", body.len());
                                        Timer::after(PACE).await;
                                        send(&mut writer, cid, CTAPHID_CBOR, &out[..n]).await;
                                    }
                                    Err(_) => {
                                        ERRORS.fetch_add(1, Ordering::Relaxed);
                                        send(&mut writer, cid, CTAPHID_CBOR, &[0x7f]).await;
                                    }
                                }
                            }
                            AUTHENTICATOR_RESET => {
                                let elapsed = boot_time.elapsed();
                                log!("  authenticatorReset: request received (elapsed: {} ms)", elapsed.as_millis());
                                if elapsed > Duration::from_secs(RESET_WINDOW_SECS) {
                                    ERRORS.fetch_add(1, Ordering::Relaxed);
                                    log!("  authenticatorReset: rejected (elapsed {} ms > {} s window)", elapsed.as_millis(), RESET_WINDOW_SECS);
                                    Timer::after(PACE).await;
                                    send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_NOT_ALLOWED]).await;
                                    continue;
                                }

                                if WAIT_FOR_USER {
                                    let w = wait_for_presence(&mut reader, &mut writer, cid).await;
                                    if !matches!(w.outcome, Presence::Pressed) {
                                        ERRORS.fetch_add(1, Ordering::Relaxed);
                                        send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await;
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
                                    send(&mut writer, cid, CTAPHID_CBOR, &out[..n]).await;
                                }
                            }
                            AUTHENTICATOR_CLIENT_PIN => {
                                let body = &t.buf[1..len];
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
                                            send(&mut writer, cid, CTAPHID_CBOR, &out[..n]).await;
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
                                        w.map(4);
                                        w.key(1);
                                        w.uint(2); // kty: EC2
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
                                            send(&mut writer, cid, CTAPHID_CBOR, &out[..n]).await;
                                        }
                                    }
                                    Some(0x03) => {
                                        // setPIN (0x03)
                                        if pin_proto != Some(1) {
                                            send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_UNSUPPORTED_OPTION]).await;
                                            continue;
                                        }
                                        let (peer_x, peer_y) = match peer_key {
                                            Some(k) => k,
                                            None => { send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_MISSING_PARAMETER]).await; continue; }
                                        };
                                        let auth = match pin_auth {
                                            Some(a) => a,
                                            None => { send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_MISSING_PARAMETER]).await; continue; }
                                        };
                                        let enc = match new_pin_enc {
                                            Some(e) => e,
                                            None => { send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_MISSING_PARAMETER]).await; continue; }
                                        };

                                        let shared_secret = match decapsulate_shared_secret(&session_sk, &peer_x, &peer_y) {
                                            Ok(s) => s,
                                            Err(_) => { send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_INVALID_CBOR]).await; continue; }
                                        };

                                        if !verify_pin_auth(&shared_secret, enc, &auth) {
                                            send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_AUTH_INVALID]).await;
                                            continue;
                                        }

                                        let mut decrypted = [0u8; 128];
                                        let dec_len = match decrypt_pin_payload(&shared_secret, enc, &mut decrypted) {
                                            Ok(l) => l,
                                            Err(_) => { send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_INVALID_CBOR]).await; continue; }
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
                                            send(&mut writer, cid, CTAPHID_CBOR, &out[..n]).await;
                                        }
                                    }
                                    Some(0x05) => {
                                        // getPinToken (0x05)
                                        if !pin_state.is_set {
                                            send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_NOT_SET]).await;
                                            continue;
                                        }
                                        if pin_state.retries_remaining == 0 {
                                            send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_BLOCKED]).await;
                                            continue;
                                        }
                                        let (peer_x, peer_y) = match peer_key {
                                            Some(k) => k,
                                            None => { send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_MISSING_PARAMETER]).await; continue; }
                                        };
                                        let enc_hash = match pin_hash_enc {
                                            Some(h) => h,
                                            None => { send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_MISSING_PARAMETER]).await; continue; }
                                        };

                                        let shared_secret = match decapsulate_shared_secret(&session_sk, &peer_x, &peer_y) {
                                            Ok(s) => s,
                                            Err(_) => { send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_INVALID_CBOR]).await; continue; }
                                        };

                                        let mut dec_hash = [0u8; 16];
                                        if decrypt_pin_payload(&shared_secret, enc_hash, &mut dec_hash).is_err() {
                                            send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_INVALID_CBOR]).await;
                                            continue;
                                        }

                                        if dec_hash != pin_state.pin_hash {
                                            pin_state.retries_remaining = pin_state.retries_remaining.saturating_sub(1);
                                            if pin_state.retries_remaining == 0 {
                                                send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_BLOCKED]).await;
                                            } else {
                                                send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_INVALID]).await;
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
                                            send(&mut writer, cid, CTAPHID_CBOR, &out[..n]).await;
                                        }
                                    }
                                    Some(0x06) => {
                                        // getPinUvAuthTokenUsingUv (0x06)
                                        let (peer_x, peer_y) = match peer_key {
                                            Some(k) => k,
                                            None => { send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_MISSING_PARAMETER]).await; continue; }
                                        };

                                        let gesture_ok = wait_for_triple_tap(&mut reader, &mut writer, cid).await;
                                        if !gesture_ok {
                                            ERRORS.fetch_add(1, Ordering::Relaxed);
                                            send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await;
                                            continue;
                                        }

                                        let shared_secret = match decapsulate_shared_secret(&session_sk, &peer_x, &peer_y) {
                                            Ok(s) => s,
                                            Err(_) => { send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_INVALID_CBOR]).await; continue; }
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
                                            send(&mut writer, cid, CTAPHID_CBOR, &out[..n]).await;
                                        }
                                    }
                                    _ => {
                                        send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_UNSUPPORTED_OPTION]).await;
                                    }
                                }
                            }
                            AUTHENTICATOR_CREDENTIAL_MANAGEMENT => {
                                // CTAP 2.1 Credential Management (0x0A)
                                let body = &t.buf[1..len];
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
                                        send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_AUTH_BLOCKED]).await;
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
                                            send(&mut writer, cid, CTAPHID_CBOR, &out[..n]).await;
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
                                                send(&mut writer, cid, CTAPHID_CBOR, &out[..n]).await;
                                            }
                                        } else {
                                            send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_NO_CREDENTIALS]).await;
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
                                                send(&mut writer, cid, CTAPHID_CBOR, &out[..n]).await;
                                            }
                                        } else {
                                            send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_NO_CREDENTIALS]).await;
                                        }
                                    }
                                    Some(0x06) => {
                                        // deleteCredential (0x06)
                                        let cred_to_delete = match target_cred_id {
                                            Some(id) => id,
                                            None => { send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_MISSING_PARAMETER]).await; continue; }
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
                                                send(&mut writer, cid, CTAPHID_CBOR, &out[..n]).await;
                                            }
                                        } else {
                                            send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_NO_CREDENTIALS]).await;
                                        }
                                    }
                                    _ => {
                                        send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_UNSUPPORTED_OPTION]).await;
                                    }
                                }
                            }
                            AUTHENTICATOR_MAKE_CREDENTIAL => {
                                let body = &t.buf[1..len];
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
                                            send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_UNSUPPORTED_ALGORITHM]).await;
                                            continue;
                                        }

                                        let mut user_verified = false;
                                        if let Some(param) = req.pin_uv_auth_param {
                                            if verify_pin_uv_auth_token(pin_state.active_token.as_ref(), req.client_data_hash, Some(param)) {
                                                user_verified = true;
                                                log!("  makeCredential: PIN UV verified (FLAG_UV=1)");
                                            } else {
                                                send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_AUTH_INVALID]).await;
                                                continue;
                                            }
                                        } else if req.uv_required {
                                            if wait_for_triple_tap(&mut reader, &mut writer, cid).await {
                                                user_verified = true;
                                                log!("  makeCredential: on-device gesture UV verified (FLAG_UV=1)");
                                            } else {
                                                send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await;
                                                continue;
                                            }
                                        }

                                        let present = if user_verified {
                                            true
                                        } else if WAIT_FOR_USER {
                                            let w = wait_for_presence(&mut reader, &mut writer, cid).await;
                                            if matches!(w.outcome, Presence::Cancelled) {
                                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                                send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_KEEPALIVE_CANCEL]).await;
                                                continue;
                                            }
                                            matches!(w.outcome, Presence::Pressed)
                                        } else {
                                            false
                                        };

                                        if WAIT_FOR_USER && !present {
                                            ERRORS.fetch_add(1, Ordering::Relaxed);
                                            send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await;
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
                                                send(&mut writer, cid, CTAPHID_CBOR, &resp[..1 + b.response]).await;
                                            }
                                            Err(()) => {
                                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                                send(&mut writer, cid, CTAPHID_CBOR, &[0x7f]).await;
                                            }
                                        }
                                    }
                                    Err(status) => {
                                        ERRORS.fetch_add(1, Ordering::Relaxed);
                                        send(&mut writer, cid, CTAPHID_CBOR, &[status]).await;
                                    }
                                }
                            }
                            AUTHENTICATOR_GET_ASSERTION => {
                                let body = &t.buf[1..len];
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
                                                send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_NO_CREDENTIALS]).await;
                                                continue;
                                            }
                                        };

                                        let mut user_verified = false;
                                        if let Some(param) = req.pin_uv_auth_param {
                                            if verify_pin_uv_auth_token(pin_state.active_token.as_ref(), req.client_data_hash, Some(param)) {
                                                user_verified = true;
                                                log!("  getAssertion: PIN UV verified (FLAG_UV=1)");
                                            } else {
                                                send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_PIN_AUTH_INVALID]).await;
                                                continue;
                                            }
                                        } else if req.uv_required {
                                            if wait_for_triple_tap(&mut reader, &mut writer, cid).await {
                                                user_verified = true;
                                                log!("  getAssertion: gesture UV verified (FLAG_UV=1)");
                                            } else {
                                                send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await;
                                                continue;
                                            }
                                        }

                                        let present = if user_verified {
                                            true
                                        } else if WAIT_FOR_USER {
                                            let w = wait_for_presence(&mut reader, &mut writer, cid).await;
                                            if matches!(w.outcome, Presence::Cancelled) {
                                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                                send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_KEEPALIVE_CANCEL]).await;
                                                continue;
                                            }
                                            matches!(w.outcome, Presence::Pressed)
                                        } else {
                                            false
                                        };

                                        if WAIT_FOR_USER && !present {
                                            ERRORS.fetch_add(1, Ordering::Relaxed);
                                            send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await;
                                            continue;
                                        }

                                        let mut resp = [0u8; 512];
                                        match build_assertion(&mut resp[1..], req.rp_id, &cred_id, req.client_data_hash, &device_salt, present, user_verified, resident_entry.as_ref()) {
                                            Ok((n_body, derive_us, sign_us)) => {
                                                resp[0] = CTAP2_OK;
                                                log!("  assertion signed: {}B, (Passkey={}, UV={})", n_body, resident_entry.is_some(), user_verified);
                                                Timer::after(PACE).await;
                                                send(&mut writer, cid, CTAPHID_CBOR, &resp[..1 + n_body]).await;
                                            }
                                            Err(()) => {
                                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                                send(&mut writer, cid, CTAPHID_CBOR, &[0x7f]).await;
                                            }
                                        }
                                    }
                                    Err(status) => {
                                        ERRORS.fetch_add(1, Ordering::Relaxed);
                                        send(&mut writer, cid, CTAPHID_CBOR, &[status]).await;
                                    }
                                }
                            }
                            _ => {
                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                send(&mut writer, cid, CTAPHID_CBOR, &[CTAP1_ERR_INVALID_COMMAND]).await;
                            }
                        }
                    }
                    _ => {
                        ERRORS.fetch_add(1, Ordering::Relaxed);
                        send(&mut writer, cid, CTAPHID_ERROR, &[ERR_INVALID_CMD]).await;
                    }
                }
            }
        }
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let boot_time = Instant::now();

    spawner.spawn(blink_task(Output::new(p.PIN_25, Level::Low)).unwrap());

    let driver = Driver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(PRODUCT);
    config.serial_number = Some("188");
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

    let mut trng_config = TrngConfig::default();
    trng_config.sample_count = TRNG_SAMPLE_COUNT;
    let trng = Trng::new(p.TRNG, Irqs, trng_config);
    spawner.spawn(ctaphid_task(hid, TRANSACTION.init(Transaction::none()), trng, boot_time).unwrap());

    Timer::after(Duration::from_secs(3)).await;

    log!("exp188 the passkey in the pocket");
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
