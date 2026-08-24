// SPDX-License-Identifier: Apache-2.0
//! # exp184 — the client that must know
//!
//! exp174 verified that Chrome registers and authenticates against a minimal
//! FIDO_2_0 authenticator. Firefox, however, begins every WebAuthn session
//! on Linux by probing `authenticatorClientPIN` (`0x06`), asking for PIN
//! retry limits before it will send `makeCredential`.
//!
//! This experiment upgrades the authenticator to CTAP 2.1 minimal compatibility:
//! - Declares `FIDO_2_1` and `pinUvAuthProtocols: [1]`
//! - Advertises `options: { clientPin: false }`
//! - Handles `authenticatorClientPIN` (`0x06`) subCommand `0x01` (`getPinRetries`)
//! - Sets LED solid on while waiting for BOOTSEL

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
use embassy_rp::peripherals::TRNG;
use embassy_rp::trng::{Config as TrngConfig, Trng};
use sha2::{Digest, Sha256};
use usb_log::log;

include!(concat!(env!("OUT_DIR"), "/exp184_config.rs"));

const DEVICE_SECRET: [u8; 32] = [
    0x6e, 0x6f, 0x74, 0x20, 0x61, 0x20, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74, 0x2e, 0x20, 0x74, 0x68,
    0x69, 0x73, 0x20, 0x69, 0x73, 0x20, 0x61, 0x20, 0x74, 0x65, 0x73, 0x74, 0x20, 0x6b, 0x65, 0x79,
];

const VERSIONS: [&str; 3] = ["U2F_V2", "FIDO_2_0", "FIDO_2_1"];

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    TRNG_IRQ => embassy_rp::trng::InterruptHandler<TRNG>;
});

#[rustfmt::skip]
const FIDO_REPORT_DESCRIPTOR: &[u8] = &[
    0x06, 0xD0, 0xF1, // Usage Page (FIDO Alliance 0xF1D0)
    0x09, 0x01,       // Usage (U2F HID Authenticator Device)
    0xA1, 0x01,       // Collection (Application)
    0x09, 0x20,       //   Usage (Input Report Data)
    0x15, 0x00,       //   Logical Minimum (0)
    0x26, 0xFF, 0x00, //   Logical Maximum (255)
    0x75, 0x08,       //   Report Size (8 bits)
    0x95, 0x40,       //   Report Count (64)
    0x81, 0x02,       //   Input (Data, Variable, Absolute)
    0x09, 0x21,       //   Usage (Output Report Data)
    0x15, 0x00,       //   Logical Minimum (0)
    0x26, 0xFF, 0x00, //   Logical Maximum (255)
    0x75, 0x08,       //   Report Size (8 bits)
    0x95, 0x40,       //   Report Count (64)
    0x91, 0x02,       //   Output (Data, Variable, Absolute)
    0xC0,             // End Collection
];

const PACKET: usize = 64;
const INIT_HEADER: usize = 7;
const CONT_HEADER: usize = 5;
const INIT_PAYLOAD: usize = PACKET - INIT_HEADER;
const CONT_PAYLOAD: usize = PACKET - CONT_HEADER;
const MAX_MESSAGE: usize = 1024;
const TRANSACTION_TIMEOUT: Duration = Duration::from_millis(750);

const CTAPHID_PING: u8 = 0x01;
const CTAPHID_MSG: u8 = 0x03;
const CTAPHID_INIT: u8 = 0x06;
const CTAPHID_CBOR: u8 = 0x10;
const CTAPHID_CANCEL: u8 = 0x11;
const CTAPHID_KEEPALIVE: u8 = 0x3B;
const CTAPHID_ERROR: u8 = 0x3F;

const STATUS_UPNEEDED: u8 = 0x02;
const KEEPALIVE_INTERVAL: Duration = Duration::from_millis(100);
const PRESENCE_POLL: Duration = Duration::from_millis(20);

const ERR_INVALID_CMD: u8 = 0x01;
const ERR_INVALID_LEN: u8 = 0x03;
const ERR_INVALID_SEQ: u8 = 0x04;
const ERR_MSG_TIMEOUT: u8 = 0x05;
const ERR_CHANNEL_BUSY: u8 = 0x06;
const ERR_INVALID_CHANNEL: u8 = 0x0B;

type Cid = [u8; 4];
const BROADCAST: Cid = [0xff, 0xff, 0xff, 0xff];
const RESERVED: Cid = [0x00, 0x00, 0x00, 0x00];

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
const CTAP2_ERR_PIN_NOT_SET: u8 = 0x35;

const COSE_ES256: i64 = -7;
const USER_PRESENCE_TIMEOUT: Duration = Duration::from_millis(TIMEOUT_MS);

const AUTHENTICATOR_MAKE_CREDENTIAL: u8 = 0x01;
const AUTHENTICATOR_GET_ASSERTION: u8 = 0x02;
const AUTHENTICATOR_GET_INFO: u8 = 0x04;
const AUTHENTICATOR_CLIENT_PIN: u8 = 0x06;

const AAGUID: [u8; 16] = [0; 16];
const TRNG_SAMPLE_COUNT: u32 = 1000;
const PRODUCT: &str = "exp184 the client that must know";
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

fn cmd_name(cmd: u8) -> &'static str {
    match cmd {
        CTAPHID_PING => "PING",
        CTAPHID_MSG => "MSG",
        CTAPHID_INIT => "INIT",
        CTAPHID_CBOR => "CBOR",
        CTAPHID_ERROR => "ERROR",
        CTAPHID_CANCEL => "CANCEL",
        CTAPHID_KEEPALIVE => "KEEPALIVE",
        _ => "?",
    }
}

struct Transaction {
    cid: Cid,
    cmd: u8,
    want: usize,
    have: usize,
    seq: u8,
    started: Instant,
    buf: [u8; MAX_MESSAGE],
}

impl Transaction {
    const fn none() -> Self {
        Self {
            cid: RESERVED,
            cmd: 0,
            want: 0,
            have: 0,
            seq: 0,
            started: Instant::from_ticks(0),
            buf: [0; MAX_MESSAGE],
        }
    }
    fn busy(&self) -> bool {
        self.cid != RESERVED
    }
    fn clear(&mut self) {
        self.cid = RESERVED;
        self.have = 0;
        self.want = 0;
        self.seq = 0;
    }
}

enum Action {
    Ignore(&'static str),
    Error(Cid, u8),
    Complete,
    More,
}

fn feed(t: &mut Transaction, pkt: &[u8]) -> Action {
    if pkt.len() < PACKET {
        return Action::Ignore("a report shorter than 64 bytes");
    }
    let cid: Cid = [pkt[0], pkt[1], pkt[2], pkt[3]];
    let is_init = pkt[4] & 0x80 != 0;

    if t.busy() && t.started.elapsed() > TRANSACTION_TIMEOUT {
        let stale = t.cid;
        t.clear();
        if cid == stale {
            return Action::Error(stale, ERR_MSG_TIMEOUT);
        }
    }

    if is_init {
        let cmd = pkt[4] & 0x7f;
        let want = ((pkt[5] as usize) << 8) | pkt[6] as usize;

        if cid == BROADCAST && cmd != CTAPHID_INIT {
            return Action::Error(cid, ERR_INVALID_CHANNEL);
        }
        if cid == RESERVED {
            return Action::Error(cid, ERR_INVALID_CHANNEL);
        }

        if cmd == CTAPHID_INIT {
            t.clear();
        } else if t.busy() && t.cid != cid {
            return Action::Error(cid, ERR_CHANNEL_BUSY);
        }

        if want > MAX_MESSAGE {
            return Action::Error(cid, ERR_INVALID_LEN);
        }
        if cmd == CTAPHID_INIT && want != 8 {
            return Action::Error(cid, ERR_INVALID_LEN);
        }

        t.cid = cid;
        t.cmd = cmd;
        t.want = want;
        t.have = 0;
        t.seq = 0;
        t.started = Instant::now();

        let n = want.min(INIT_PAYLOAD);
        t.buf[..n].copy_from_slice(&pkt[INIT_HEADER..INIT_HEADER + n]);
        t.have = n;
    } else {
        if !t.busy() {
            return Action::Ignore("a continuation packet with no transaction");
        }
        if cid != t.cid {
            return Action::Ignore("a continuation packet from another channel");
        }
        let seq = pkt[4];
        if seq != t.seq {
            let c = t.cid;
            t.clear();
            return Action::Error(c, ERR_INVALID_SEQ);
        }
        t.seq = t.seq.wrapping_add(1);
        let n = (t.want - t.have).min(CONT_PAYLOAD);
        t.buf[t.have..t.have + n].copy_from_slice(&pkt[CONT_HEADER..CONT_HEADER + n]);
        t.have += n;
    }

    if t.have >= t.want {
        Action::Complete
    } else {
        Action::More
    }
}

fn allocate_cid() -> Cid {
    let mut n = NEXT_CID.fetch_add(1, Ordering::Relaxed);
    if n == 0 || n == u32::from_be_bytes(BROADCAST) {
        n = NEXT_CID.fetch_add(1, Ordering::Relaxed) | 1;
    }
    n.to_be_bytes()
}

async fn send(
    writer: &mut embassy_usb::class::hid::HidWriter<'static, usb_reboot::UsbDriver, PACKET>,
    cid: Cid,
    cmd: u8,
    data: &[u8],
) -> usize {
    let mut pkt = [0u8; PACKET];
    pkt[..4].copy_from_slice(&cid);
    pkt[4] = 0x80 | cmd;
    pkt[5] = (data.len() >> 8) as u8;
    pkt[6] = data.len() as u8;
    let n = data.len().min(INIT_PAYLOAD);
    pkt[INIT_HEADER..INIT_HEADER + n].copy_from_slice(&data[..n]);
    let _ = writer.write(&pkt).await;

    let mut sent = n;
    let mut seq = 0u8;
    let mut packets = 1;
    while sent < data.len() {
        pkt = [0u8; PACKET];
        pkt[..4].copy_from_slice(&cid);
        pkt[4] = seq;
        let n = (data.len() - sent).min(CONT_PAYLOAD);
        pkt[CONT_HEADER..CONT_HEADER + n].copy_from_slice(&data[sent..sent + n]);
        let _ = writer.write(&pkt).await;
        sent += n;
        seq = seq.wrapping_add(1);
        packets += 1;
    }
    packets
}

const CRED_ID_LEN: usize = 48;
const TAG_LEN: usize = 16;
type Hmac = SimpleHmac<Sha256>;

fn mac(label: &[u8], nonce: &[u8], rp_id_hash: &[u8], out: &mut [u8]) {
    let mut m = <Hmac as Mac>::new_from_slice(&DEVICE_SECRET).unwrap();
    m.update(label);
    m.update(nonce);
    m.update(rp_id_hash);
    let tag = m.finalize().into_bytes();
    out.copy_from_slice(&tag[..out.len()]);
}

fn derive_key(nonce: &[u8], rp_id_hash: &[u8]) -> Option<SigningKey> {
    for counter in 0u8..=255 {
        let mut k = [0u8; 32];
        let mut m = <Hmac as Mac>::new_from_slice(&DEVICE_SECRET).unwrap();
        m.update(b"key");
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
const FLAG_AT: u8 = 0x40;

struct Built {
    response: usize,
    auth_len: usize,
    cose_len: usize,
    derive_us: u64,
    sign_us: u64,
}

fn build_credential(
    out: &mut [u8],
    auth: &mut [u8; 256],
    scratch: &mut [u8; 256],
    rp_id: &str,
    client_data_hash: &[u8],
    nonce: &[u8; 32],
    user_present: bool,
) -> Result<Built, ()> {
    let rp_id_hash: [u8; 32] = Sha256::digest(rp_id.as_bytes()).into();

    let mut cred_id = [0u8; CRED_ID_LEN];
    cred_id[..32].copy_from_slice(nonce);
    let (nonce_part, tag_part) = cred_id.split_at_mut(32);
    mac(b"id", nonce_part, &rp_id_hash, &mut tag_part[..TAG_LEN]);

    let t0 = Instant::now();
    let sk = derive_key(nonce, &rp_id_hash).ok_or(())?;
    let derive_us = t0.elapsed().as_micros();
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
    auth[n] = FLAG_AT | if user_present { FLAG_UP } else { 0 };
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
    let t1 = Instant::now();
    let sig: Signature = sk.sign(&signed[..auth_len + client_data_hash.len()]);
    let sign_us = t1.elapsed().as_micros();
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

    Ok(Built { response, auth_len, cose_len, derive_us, sign_us })
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

fn credential_is_ours(cred_id: &[u8], rp_id_hash: &[u8; 32]) -> bool {
    if cred_id.len() != CRED_ID_LEN {
        return false;
    }
    let (nonce, tag) = cred_id.split_at(32);
    let mut want = [0u8; TAG_LEN];
    mac(b"id", nonce, rp_id_hash, &mut want);
    tags_equal(&want, tag)
}

struct GetAssertion<'a> {
    rp_id: &'a str,
    client_data_hash: &'a [u8],
    allow: [&'a [u8]; MAX_ALLOW],
    n_allow: usize,
    allow_truncated: bool,
}

const MAX_ALLOW: usize = 8;

fn parse_get_assertion(body: &[u8]) -> Result<GetAssertion<'_>, u8> {
    let mut r = Reader::new(body);
    let pairs = r.map_header().map_err(status_for)?;

    let mut rp_id: Option<&str> = None;
    let mut client_data_hash: Option<&[u8]> = None;
    let mut allow: [&[u8]; MAX_ALLOW] = [&[]; MAX_ALLOW];
    let mut n_allow = 0usize;
    let mut allow_truncated = false;
    let mut had_allow = false;

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
                had_allow = true;
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
                                } else {
                                    allow_truncated = true;
                                }
                            }
                            _ => return Err(CTAP2_ERR_INVALID_CBOR),
                        }
                    }
                    skip_map_pairs(&mut r, n).map_err(status_for)?;
                }
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
    if !had_allow {
        return Err(CTAP2_ERR_NO_CREDENTIALS);
    }

    Ok(GetAssertion { rp_id, client_data_hash, allow, n_allow, allow_truncated })
}

fn build_assertion(
    out: &mut [u8],
    rp_id: &str,
    cred_id: &[u8],
    client_data_hash: &[u8],
    user_present: bool,
) -> Result<(usize, u64, u64), ()> {
    let rp_id_hash: [u8; 32] = Sha256::digest(rp_id.as_bytes()).into();
    let nonce = &cred_id[..32];

    let t0 = Instant::now();
    let sk = derive_key(nonce, &rp_id_hash).ok_or(())?;
    let derive_us = t0.elapsed().as_micros();

    let mut auth = [0u8; 37];
    auth[..32].copy_from_slice(&rp_id_hash);
    auth[32] = if user_present { FLAG_UP } else { 0 };
    auth[33..37].copy_from_slice(&0u32.to_be_bytes());

    let mut signed = [0u8; 69];
    signed[..37].copy_from_slice(&auth);
    signed[37..69].copy_from_slice(client_data_hash);
    let t1 = Instant::now();
    let sig: Signature = sk.sign(&signed);
    let sign_us = t1.elapsed().as_micros();
    let der = sig.to_der();

    let n = {
        let mut w = cbor::Writer::new(out);
        w.map(3);
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
        w.end();
        w.finish().map_err(|_| ())?.len()
    };
    Ok((n, derive_us, sign_us))
}

struct MakeCredential<'a> {
    client_data_hash: &'a [u8],
    rp_id: &'a str,
    user_id: &'a [u8],
    algs: [i64; MAX_ALGS],
    n_algs: usize,
    algs_truncated: bool,
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
    let mut algs = [0i64; MAX_ALGS];
    let mut n_algs = 0usize;
    let mut algs_truncated = false;
    let mut have_params = false;

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
                let mut it = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it, n, "id").map_err(status_for)? {
                    match it.next().map_err(status_for)? {
                        Item::Bytes(v) => user_id = Some(v),
                        _ => return Err(CTAP2_ERR_INVALID_CBOR),
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
                        } else {
                            algs_truncated = true;
                        }
                    }
                    skip_map_pairs(&mut r, n).map_err(status_for)?;
                }
            }
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

    Ok(MakeCredential { client_data_hash, rp_id, user_id, algs, n_algs, algs_truncated })
}

fn skip_map_pairs(r: &mut Reader, pairs: u64) -> Result<(), ReadError> {
    for _ in 0..pairs {
        r.skip()?;
        r.skip()?;
    }
    Ok(())
}

fn status_for(_e: ReadError) -> u8 {
    CTAP2_ERR_INVALID_CBOR
}

fn read_error_name(e: ReadError) -> &'static str {
    match e {
        ReadError::Truncated => "a length that runs past the message",
        ReadError::NotCanonical => "valid CBOR that is not canonical",
        ReadError::Unsupported => "a CBOR type this device does not read",
        ReadError::TooDeep => "nesting past the depth limit",
        ReadError::BadText => "a text string that is not UTF-8",
    }
}

/// Build an `authenticatorGetInfo` response for CTAP 2.1.
///
/// Keys in canonical CBOR:
/// - 0x01: versions -> ["FIDO_2_0", "FIDO_2_1"]
/// - 0x03: aaguid -> 16 zeros
/// - 0x04: options -> {"rk": false, "up": bool, "clientPin": false}
/// - 0x05: maxMsgSize -> 1024
/// - 0x06: pinUvAuthProtocols -> [1]
fn get_info(buf: &mut [u8]) -> Result<&[u8], cbor::Error> {
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

    // 0x04: options (canonical order by length: "rk", "up", "clientPin", "pinUvAuthToken", "makeCredUvNotRqd")
    w.key(0x04);
    w.map(5);
    w.key_text("rk");
    w.bool(false);
    w.key_text("up");
    w.bool(WAIT_FOR_USER);
    w.key_text("clientPin");
    w.bool(false); // PIN supported by CTAP 2.1 protocol, not set yet
    w.key_text("pinUvAuthToken");
    w.bool(true); // CTAP 2.1: pinUvAuthToken supported
    w.key_text("makeCredUvNotRqd");
    w.bool(true); // CTAP 2.1: allow makeCredential without PIN/UV when UV is preferred
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

static TRANSACTION: StaticCell<Transaction> = StaticCell::new();

enum Presence {
    Pressed,
    TimedOut,
    Cancelled,
}

struct Waited {
    outcome: Presence,
    ms: u64,
    pressed_at: Option<u64>,
    keepalives: u32,
}

async fn wait_for_presence(
    reader: &mut embassy_usb::class::hid::HidReader<'static, usb_reboot::UsbDriver, PACKET>,
    writer: &mut embassy_usb::class::hid::HidWriter<'static, usb_reboot::UsbDriver, PACKET>,
    cid: Cid,
) -> Waited {
    LED_SOLID_OVERRIDE.store(true, Ordering::Relaxed);
    let start = Instant::now();
    let mut pkt = [0u8; PACKET];
    let mut keepalives = 0u32;
    let mut pressed_at: Option<u64> = None;
    let mut next = start + KEEPALIVE_INTERVAL;

    let res = loop {
        if bootsel::is_pressed() && pressed_at.is_none() {
            pressed_at = Some(start.elapsed().as_millis());
        }
        if pressed_at.is_some() && start.elapsed().as_millis() >= HOLD_MS {
            break Waited {
                outcome: Presence::Pressed,
                ms: start.elapsed().as_millis(),
                pressed_at,
                keepalives,
            };
        }
        if start.elapsed() >= USER_PRESENCE_TIMEOUT {
            break Waited {
                outcome: Presence::TimedOut,
                ms: start.elapsed().as_millis(),
                pressed_at,
                keepalives,
            };
        }

        if let Either::First(Ok(n)) = select(reader.read(&mut pkt), Timer::after(PRESENCE_POLL)).await {
            if n >= 5 && pkt[4] & 0x80 != 0 {
                let from: Cid = [pkt[0], pkt[1], pkt[2], pkt[3]];
                let cmd = pkt[4] & 0x7f;
                if from == cid && cmd == CTAPHID_CANCEL {
                    break Waited {
                        outcome: Presence::Cancelled,
                        ms: start.elapsed().as_millis(),
                        pressed_at,
                        keepalives,
                    };
                }
                if from != cid && from != RESERVED {
                    ERRORS.fetch_add(1, Ordering::Relaxed);
                    send(writer, from, CTAPHID_ERROR, &[ERR_CHANNEL_BUSY]).await;
                }
            }
        }

        if KEEPALIVE && Instant::now() >= next {
            send(writer, cid, CTAPHID_KEEPALIVE, &[STATUS_UPNEEDED]).await;
            keepalives += 1;
            next = Instant::now() + KEEPALIVE_INTERVAL;
        }
    };
    LED_SOLID_OVERRIDE.store(false, Ordering::Relaxed);
    res
}

#[embassy_executor::task]
async fn ctaphid_task(
    hid: HidReaderWriter<'static, usb_reboot::UsbDriver, PACKET, PACKET>,
    t: &'static mut Transaction,
    mut trng: Trng<'static, TRNG>,
) -> ! {
    let (mut reader, mut writer) = hid.split();
    let mut pkt = [0u8; PACKET];

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
                        let mut out = [0u8; 256];
                        match ctap {
                            AUTHENTICATOR_GET_INFO if params != 0 => {
                                log!("  getInfo takes no parameters; {} arrived", params);
                                Timer::after(PACE).await;
                                send(&mut writer, cid, CTAPHID_CBOR, &[CTAP1_ERR_INVALID_LENGTH])
                                    .await;
                            }
                            AUTHENTICATOR_GET_INFO => {
                                out[0] = CTAP2_OK;
                                match get_info(&mut out[1..]) {
                                    Ok(body) => {
                                        let n = 1 + body.len();
                                        log!("  getInfo: {} bytes of canonical CBOR (CTAP 2.1)", body.len());
                                        Timer::after(PACE).await;
                                        send(&mut writer, cid, CTAPHID_CBOR, &out[..n]).await;
                                    }
                                    Err(_) => {
                                        ERRORS.fetch_add(1, Ordering::Relaxed);
                                        log!("  getInfo: the encoder refused; sending error");
                                        Timer::after(PACE).await;
                                        send(&mut writer, cid, CTAPHID_CBOR, &[0x7f]).await;
                                    }
                                }
                            }
                            AUTHENTICATOR_CLIENT_PIN => {
                                // Subcommand 0x01 = getPinRetries, 0x02 = getKeyAgreement, etc.
                                let body = &t.buf[1..len];
                                let mut r = Reader::new(body);
                                let mut sub_cmd: Option<u64> = None;
                                if let Ok(pairs) = r.map_header() {
                                    for _ in 0..pairs {
                                        if let Ok(Item::Uint(k)) = r.next() {
                                            match k {
                                                0x02 => {
                                                    if let Ok(Item::Uint(sc)) = r.next() {
                                                        sub_cmd = Some(sc);
                                                    }
                                                }
                                                _ => { let _ = r.skip(); }
                                            }
                                        }
                                    }
                                }
                                match sub_cmd {
                                    Some(0x01) => {
                                        // getPinRetries: answer 8 retries remaining (CTAP2 key 0x03)
                                        log!("  clientPIN: getPinRetries -> 8 retries remaining");
                                        out[0] = CTAP2_OK;
                                        let mut w = cbor::Writer::new(&mut out[1..]);
                                        w.map(1);
                                        w.key(0x03); // pinRetries (key 0x03 per CTAP 2.0/2.1 spec)
                                        w.uint(8);
                                        w.end();
                                        if let Ok(b) = w.finish() {
                                            let n = 1 + b.len();
                                            send(&mut writer, cid, CTAPHID_CBOR, &out[..n]).await;
                                        } else {
                                            send(&mut writer, cid, CTAPHID_CBOR, &[0x7f]).await;
                                        }
                                    }
                                    Some(0x02) => {
                                        // getKeyAgreement: CTAP 2.1 requires returning ephemeral P-256 public key (COSE_Key)
                                        log!("  clientPIN: getKeyAgreement -> ephemeral P-256 COSE_Key");
                                        let mut eph_bytes = [0u8; 32];
                                        trng.blocking_fill_bytes(&mut eph_bytes);
                                        // Ensure non-zero scalar for valid P-256 private key
                                        eph_bytes[0] |= 0x01;
                                        eph_bytes[31] &= 0x7f;
                                        let sk = derive_key(&eph_bytes, b"eph").unwrap();
                                        let point = sk.verifying_key().to_encoded_point(false);
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
                                        } else {
                                            send(&mut writer, cid, CTAPHID_CBOR, &[0x7f]).await;
                                        }
                                    }
                                    _ => {
                                        log!("  clientPIN: subCommand {:?} unsupported (no PIN configured)", sub_cmd);
                                        send(&mut writer, cid, CTAPHID_CBOR, &[CTAP2_ERR_UNSUPPORTED_OPTION]).await;
                                    }
                                }
                            }
                            AUTHENTICATOR_MAKE_CREDENTIAL => {
                                let body = &t.buf[1..len];
                                match parse_make_credential(body) {
                                    Ok(req) => {
                                        log!("  makeCredential: rp={:?}, user={}B", req.rp_id, req.user_id.len());
                                        Timer::after(PACE).await;
                                        let mut es256 = false;
                                        for a in &req.algs[..req.n_algs] {
                                            if *a == COSE_ES256 {
                                                es256 = true;
                                            }
                                        }
                                        if !es256 {
                                            ERRORS.fetch_add(1, Ordering::Relaxed);
                                            log!("  ES256 was not offered; refusing.");
                                            Timer::after(PACE).await;
                                            send(
                                                &mut writer,
                                                cid,
                                                CTAPHID_CBOR,
                                                &[CTAP2_ERR_UNSUPPORTED_ALGORITHM],
                                            )
                                            .await;
                                            continue;
                                        }

                                        let present = if WAIT_FOR_USER {
                                            log!("  waiting for BOOTSEL (LED solid on)...");
                                            Timer::after(PACE).await;
                                            let w = wait_for_presence(&mut reader, &mut writer, cid).await;
                                            match w.outcome {
                                                Presence::Pressed => log!(
                                                    "  pressed at {} ms, answered at {} ms, {} keepalives",
                                                    w.pressed_at.unwrap_or(0),
                                                    w.ms,
                                                    w.keepalives
                                                ),
                                                Presence::TimedOut => log!("  timeout at {} ms", w.ms),
                                                Presence::Cancelled => log!("  cancelled at {} ms", w.ms),
                                            }
                                            Timer::after(PACE).await;
                                            if matches!(w.outcome, Presence::Cancelled) {
                                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                                send(
                                                    &mut writer,
                                                    cid,
                                                    CTAPHID_CBOR,
                                                    &[CTAP2_ERR_KEEPALIVE_CANCEL],
                                                )
                                                .await;
                                                continue;
                                            }
                                            matches!(w.outcome, Presence::Pressed)
                                        } else {
                                            false
                                        };

                                        if WAIT_FOR_USER && !present {
                                            ERRORS.fetch_add(1, Ordering::Relaxed);
                                            send(
                                                &mut writer,
                                                cid,
                                                CTAPHID_CBOR,
                                                &[CTAP2_ERR_OPERATION_DENIED],
                                            )
                                            .await;
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
                                            present,
                                        );
                                        match built {
                                            Ok(b) => {
                                                resp[0] = CTAP2_OK;
                                                log!(
                                                    "  credential created: authData {}B, total {}B",
                                                    b.auth_len,
                                                    b.response
                                                );
                                                Timer::after(PACE).await;
                                                send(
                                                    &mut writer,
                                                    cid,
                                                    CTAPHID_CBOR,
                                                    &resp[..1 + b.response],
                                                )
                                                .await;
                                            }
                                            Err(()) => {
                                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                                log!("  credential building failed.");
                                                Timer::after(PACE).await;
                                                send(&mut writer, cid, CTAPHID_CBOR, &[0x7f]).await;
                                            }
                                        }
                                    }
                                    Err(status) => {
                                        ERRORS.fetch_add(1, Ordering::Relaxed);
                                        let why = {
                                            let mut probe = Reader::new(body);
                                            match probe.skip() {
                                                Err(e) => read_error_name(e),
                                                Ok(()) if !probe.is_empty() => "trailing bytes after map",
                                                Ok(()) => "missing required field",
                                            }
                                        };
                                        log!("  makeCredential refused: {}", why);
                                        Timer::after(PACE).await;
                                        send(&mut writer, cid, CTAPHID_CBOR, &[status]).await;
                                    }
                                }
                            }
                            AUTHENTICATOR_GET_ASSERTION => {
                                let body = &t.buf[1..len];
                                match parse_get_assertion(body) {
                                    Err(status) => {
                                        ERRORS.fetch_add(1, Ordering::Relaxed);
                                        log!("  getAssertion refused: {:#04x}", status);
                                        Timer::after(PACE).await;
                                        send(&mut writer, cid, CTAPHID_CBOR, &[status]).await;
                                    }
                                    Ok(req) => {
                                        log!("  getAssertion for {:?}", req.rp_id);
                                        Timer::after(PACE).await;
                                        let rp_id_hash: [u8; 32] =
                                            Sha256::digest(req.rp_id.as_bytes()).into();

                                        let mut chosen: Option<&[u8]> = None;
                                        for c in &req.allow[..req.n_allow] {
                                            if credential_is_ours(c, &rp_id_hash) && chosen.is_none() {
                                                chosen = Some(c);
                                            }
                                        }
                                        let Some(cred_id) = chosen else {
                                            ERRORS.fetch_add(1, Ordering::Relaxed);
                                            log!("  no credential matching RP ID found.");
                                            Timer::after(PACE).await;
                                            send(
                                                &mut writer,
                                                cid,
                                                CTAPHID_CBOR,
                                                &[CTAP2_ERR_NO_CREDENTIALS],
                                            )
                                            .await;
                                            continue;
                                        };

                                        let present = if WAIT_FOR_USER {
                                            log!("  waiting for BOOTSEL (LED solid on)...");
                                            Timer::after(PACE).await;
                                            let w = wait_for_presence(&mut reader, &mut writer, cid).await;
                                            if matches!(w.outcome, Presence::Cancelled) {
                                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                                send(
                                                    &mut writer,
                                                    cid,
                                                    CTAPHID_CBOR,
                                                    &[CTAP2_ERR_KEEPALIVE_CANCEL],
                                                )
                                                .await;
                                                continue;
                                            }
                                            matches!(w.outcome, Presence::Pressed)
                                        } else {
                                            false
                                        };

                                        if WAIT_FOR_USER && !present {
                                            ERRORS.fetch_add(1, Ordering::Relaxed);
                                            send(
                                                &mut writer,
                                                cid,
                                                CTAPHID_CBOR,
                                                &[CTAP2_ERR_OPERATION_DENIED],
                                            )
                                            .await;
                                            continue;
                                        }

                                        let mut resp = [0u8; 320];
                                        match build_assertion(
                                            &mut resp[1..],
                                            req.rp_id,
                                            cred_id,
                                            req.client_data_hash,
                                            present,
                                        ) {
                                            Ok((n, _, _)) => {
                                                resp[0] = CTAP2_OK;
                                                log!("  assertion signed: {}B", n);
                                                Timer::after(PACE).await;
                                                send(&mut writer, cid, CTAPHID_CBOR, &resp[..1 + n])
                                                    .await;
                                            }
                                            Err(()) => {
                                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                                log!("  building assertion failed.");
                                                Timer::after(PACE).await;
                                                send(&mut writer, cid, CTAPHID_CBOR, &[0x7f]).await;
                                            }
                                        }
                                    }
                                }
                            }
                            other => {
                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                log!("  CTAP2 command {:#04x} is unknown; returning INVALID_COMMAND", other);
                                Timer::after(PACE).await;
                                send(&mut writer, cid, CTAPHID_CBOR, &[CTAP1_ERR_INVALID_COMMAND])
                                    .await;
                            }
                        }
                    }
                    other => {
                        t.clear();
                        ERRORS.fetch_add(1, Ordering::Relaxed);
                        log!("  {} not implemented: ERR_INVALID_CMD", cmd_name(other));
                        Timer::after(PACE).await;
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

    spawner.spawn(blink_task(Output::new(p.PIN_25, Level::Low)).unwrap());

    let driver = Driver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(PRODUCT);
    config.serial_number = Some("184");
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

    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), PACKET as u16);
    let hid = HidReaderWriter::<_, PACKET, PACKET>::new(
        &mut builder,
        HID_STATE.init(HidState::new()),
        HidConfig {
            report_descriptor: FIDO_REPORT_DESCRIPTOR,
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
    spawner.spawn(ctaphid_task(hid, TRANSACTION.init(Transaction::none()), trng).unwrap());

    Timer::after(Duration::from_secs(3)).await;

    log!("exp184 the client that must know");
    Timer::after(PACE).await;
    log!("  CTAP 2.1 minimal compatibility layer with clientPIN getPinRetries support");
    Timer::after(PACE).await;
    log!("  versions: FIDO_2_0, FIDO_2_1");
    Timer::after(PACE).await;
    log!("  options: rk=false, up=true, clientPin=false");
    Timer::after(PACE).await;
    log!("  pinUvAuthProtocols: [1]");
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

