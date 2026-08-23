// SPDX-License-Identifier: Apache-2.0
//! # exp183 — the contract and the lock
//!
//! Refactoring hand-rolled FIDO2 WebAuthn firmware into a lightweight zero-allocation
//! trait abstraction contract, supporting 4 pluggable key backends, and providing
//! an inspection/verification pipeline for RP2350 Secure Boot and Secure Lock.

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicU32, AtomicU8, Ordering};

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_rp::bind_interrupts;
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver as RpDriver, InterruptHandler};
use embassy_time::{Duration, Instant, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::class::hid::{Config as HidConfig, HidReaderWriter, State as HidState};
use embassy_usb::driver::Driver;
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;

use cbor::{Item, Reader};
use sha2::{Digest, Sha256};
use usb_log::log;

pub mod backends;
pub mod contract;

use backends::{Bank8SecureBackend, OtpSimulatedBackend, PufReconstructedBackend, TestKeyBackend};
use contract::{KeyBackend, MemoryPersistStore, PersistStore};

// UP_MODE, ACTIVE_BACKEND, and WAIT_FOR_USER from build.rs
include!(concat!(env!("OUT_DIR"), "/exp183_config.rs"));

const VERSIONS: [&str; 1] = ["FIDO_2_0"];

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

#[rustfmt::skip]
const FIDO_REPORT_DESCRIPTOR: &[u8] = &[
    0x06, 0xD0, 0xF1, // Usage Page (vendor-defined 0xF1D0 — FIDO Alliance)
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
const BUTTON_POLL: Duration = Duration::from_millis(10);

const ERR_INVALID_CMD: u8 = 0x01;
const ERR_INVALID_PAR: u8 = 0x02;
const ERR_INVALID_LEN: u8 = 0x03;
const ERR_INVALID_SEQ: u8 = 0x04;
const ERR_MSG_TIMEOUT: u8 = 0x05;
const ERR_CHANNEL_BUSY: u8 = 0x06;
const ERR_LOCK_REQUIRED: u8 = 0x0A;
const ERR_INVALID_CHANNEL: u8 = 0x0B;
const ERR_OTHER: u8 = 0x7F;

const CTAP2_OK: u8 = 0x00;
const CTAP2_ERR_INVALID_COMMAND: u8 = 0x01;
const CTAP2_ERR_INVALID_PARAMETER: u8 = 0x02;
const CTAP2_ERR_INVALID_LENGTH: u8 = 0x03;
const CTAP2_ERR_UNSUPPORTED_ALGORITHM: u8 = 0x26;
const CTAP2_ERR_OPERATION_DENIED: u8 = 0x27;
const CTAP2_ERR_NO_CREDENTIALS: u8 = 0x2E;
const CTAP2_ERR_UNSUPPORTED_OPTION: u8 = 0x2B;
const CTAP2_ERR_KEEPALIVE_CANCEL: u8 = 0x2D;

const CMD_AUTHENTICATOR_MAKE_CREDENTIAL: u8 = 0x01;
const CMD_AUTHENTICATOR_GET_ASSERTION: u8 = 0x02;
const CMD_AUTHENTICATOR_GET_INFO: u8 = 0x04;

const CID_BROADCAST: u32 = 0xFFFF_FFFF;

#[derive(Clone, Copy, PartialEq, Eq)]
enum StateKind {
    Idle,
    Accumulating,
}

struct ChannelState {
    cid: u32,
    state: StateKind,
    cmd: u8,
    total_len: usize,
    received: usize,
    next_seq: u8,
    deadline: Instant,
    buf: [u8; MAX_MESSAGE],
}

impl ChannelState {
    const fn new() -> Self {
        Self {
            cid: 0,
            state: StateKind::Idle,
            cmd: 0,
            total_len: 0,
            received: 0,
            next_seq: 0,
            deadline: Instant::from_ticks(0),
            buf: [0u8; MAX_MESSAGE],
        }
    }

    fn reset(&mut self) {
        self.state = StateKind::Idle;
        self.cmd = 0;
        self.total_len = 0;
        self.received = 0;
        self.next_seq = 0;
    }
}

static NEXT_CID: AtomicU32 = AtomicU32::new(1);
fn alloc_cid() -> u32 {
    loop {
        let cid = NEXT_CID.fetch_add(1, Ordering::Relaxed);
        if cid != 0 && cid != CID_BROADCAST {
            return cid;
        }
    }
}

static CHANNEL: StaticCell<ChannelState> = StaticCell::new();
static IN_PACKET: StaticCell<[u8; PACKET]> = StaticCell::new();
static CBOR_BUF: StaticCell<[u8; MAX_MESSAGE]> = StaticCell::new();

static PRESENCE_CANCELLED: AtomicU8 = AtomicU8::new(0);

fn read_u32_be(b: &[u8]) -> u32 {
    u32::from_be_bytes([b[0], b[1], b[2], b[3]])
}

fn write_u32_be(buf: &mut [u8], v: u32) {
    buf[..4].copy_from_slice(&v.to_be_bytes());
}

fn write_u16_be(buf: &mut [u8], v: u16) {
    buf[..2].copy_from_slice(&v.to_be_bytes());
}

async fn send_hid<'a, D: Driver<'a>>(
    class: &mut HidReaderWriter<'a, D, 64, 64>,
    packet: &[u8; PACKET],
) -> bool {
    class.write(packet).await.is_ok()
}

async fn send_response<'a, D: Driver<'a>>(
    class: &mut HidReaderWriter<'a, D, 64, 64>,
    cid: u32,
    cmd: u8,
    data: &[u8],
) -> bool {
    let mut pkt = [0u8; PACKET];
    write_u32_be(&mut pkt[0..4], cid);
    pkt[4] = 0x80 | cmd;
    write_u16_be(&mut pkt[5..7], data.len() as u16);

    let first = data.len().min(INIT_PAYLOAD);
    pkt[INIT_HEADER..INIT_HEADER + first].copy_from_slice(&data[..first]);
    if !send_hid(class, &pkt).await {
        return false;
    }

    let mut sent = first;
    let mut seq = 0u8;
    while sent < data.len() {
        pkt.fill(0);
        write_u32_be(&mut pkt[0..4], cid);
        pkt[4] = seq;
        seq = (seq + 1) & 0x7F;
        let chunk = (data.len() - sent).min(CONT_PAYLOAD);
        pkt[CONT_HEADER..CONT_HEADER + chunk].copy_from_slice(&data[sent..sent + chunk]);
        if !send_hid(class, &pkt).await {
            return false;
        }
        sent += chunk;
    }
    true
}

async fn send_error<'a, D: Driver<'a>>(
    class: &mut HidReaderWriter<'a, D, 64, 64>,
    cid: u32,
    code: u8,
) -> bool {
    send_response(class, cid, CTAPHID_ERROR, &[code]).await
}

async fn wait_for_user_presence<'a, D: Driver<'a>>(
    class: &mut HidReaderWriter<'a, D, 64, 64>,
    cid: u32,
) -> Result<bool, u8> {
    if !WAIT_FOR_USER {
        return Ok(true);
    }

    let start = Instant::now();
    let mut next_keepalive = start + KEEPALIVE_INTERVAL;
    let timeout = Duration::from_millis(TIMEOUT_MS);

    loop {
        if PRESENCE_CANCELLED.swap(0, Ordering::Relaxed) != 0 {
            return Err(CTAP2_ERR_KEEPALIVE_CANCEL);
        }

        if bootsel::is_pressed() {
            let elapsed = Instant::now() - start;
            if elapsed >= Duration::from_millis(HOLD_MS) {
                return Ok(true);
            }
        }

        let now = Instant::now();
        if now - start >= timeout {
            return Err(CTAP2_ERR_OPERATION_DENIED);
        }

        if KEEPALIVE && now >= next_keepalive {
            let mut pkt = [0u8; PACKET];
            write_u32_be(&mut pkt[0..4], cid);
            pkt[4] = 0x80 | CTAPHID_KEEPALIVE;
            pkt[5] = 0x00;
            pkt[6] = 0x01;
            pkt[7] = STATUS_UPNEEDED;
            let _ = send_hid(class, &pkt).await;
            next_keepalive = now + KEEPALIVE_INTERVAL;
        }

        Timer::after(BUTTON_POLL).await;
    }
}

// Minimal CBOR encoders for GetInfo, MakeCredential, and GetAssertion
fn encode_get_info(buf: &mut [u8]) -> usize {
    let mut w = 0;
    buf[w] = 0x00; w += 1; // CTAP2_OK
    buf[w] = 0xA2; w += 1; // map(2)

    // 0x01: versions: ["FIDO_2_0"]
    buf[w] = 0x01; w += 1;
    buf[w] = 0x81; w += 1; // array(1)
    buf[w] = 0x68; w += 1; // text(8)
    buf[w..w + 8].copy_from_slice(b"FIDO_2_0"); w += 8;

    // 0x03: aaguid: 16 zero bytes (self-attestation)
    buf[w] = 0x03; w += 1;
    buf[w] = 0x50; w += 1; // bytes(16)
    buf[w..w + 16].fill(0); w += 16;

    w
}

async fn handle_cbor<'a, D: Driver<'a>, K: KeyBackend, P: PersistStore>(
    class: &mut HidReaderWriter<'a, D, 64, 64>,
    cid: u32,
    req: &[u8],
    backend: &mut K,
    persist: &mut P,
) -> bool {
    if req.is_empty() {
        return send_response(class, cid, CTAPHID_CBOR, &[CTAP2_ERR_INVALID_LENGTH]).await;
    }

    let cmd = req[0];
    let out = CBOR_BUF.init([0u8; MAX_MESSAGE]);

    match cmd {
        CMD_AUTHENTICATOR_GET_INFO => {
            let len = encode_get_info(out);
            send_response(class, cid, CTAPHID_CBOR, &out[..len]).await
        }
        CMD_AUTHENTICATOR_MAKE_CREDENTIAL => {
            match wait_for_user_presence(class, cid).await {
                Ok(_) => {
                    let mut reader = Reader::new(&req[1..]);
                    let mut rp_id_hash = [0u8; 32];
                    let mut client_data_hash = [0u8; 32];
                    let mut found_rp = false;

                    if let Ok(Item::Map(pairs)) = reader.next() {
                        for _ in 0..pairs {
                            let k = reader.next().ok();
                            match k {
                                Some(Item::Uint(1)) => {
                                    if let Ok(Item::Bytes(cdh)) = reader.next() {
                                        if cdh.len() == 32 {
                                            client_data_hash.copy_from_slice(cdh);
                                        }
                                    }
                                }
                                Some(Item::Uint(2)) => {
                                    if let Ok(Item::Map(rp_pairs)) = reader.next() {
                                        for _ in 0..rp_pairs {
                                            if let Ok(Item::Text(id_key)) = reader.next() {
                                                if id_key == "id" {
                                                    if let Ok(Item::Text(id_val)) = reader.next() {
                                                        let mut h = Sha256::new();
                                                        h.update(id_val.as_bytes());
                                                        rp_id_hash.copy_from_slice(&h.finalize());
                                                        found_rp = true;
                                                    }
                                                } else {
                                                    let _ = reader.next();
                                                }
                                            }
                                        }
                                    }
                                }
                                _ => {
                                    let _ = reader.next();
                                }
                            }
                        }
                    }

                    if !found_rp {
                        rp_id_hash = [0x55; 32];
                    }

                    let cred_random = [0x42; 32];
                    let counter = persist.increment_counter();

                    let key_res = backend.derive_credential_key(&rp_id_hash, &cred_random, counter);
                    let tag_res = backend.sign_credential_id(&cred_random, &rp_id_hash);

                    match (key_res, tag_res) {
                        (Ok(signing_key), Ok(tag)) => {
                            let pubkey = signing_key.verifying_key();
                            let encoded_point = pubkey.to_encoded_point(false);
                            let x_bytes = encoded_point.x().unwrap();
                            let y_bytes = encoded_point.y().unwrap();

                            // Build authenticator data (37 bytes + 16 byte AAGUID + 2 byte len + 48 byte credId + COSE key)
                            let mut auth_data = [0u8; 300];
                            let mut ad_len = 0;
                            auth_data[ad_len..ad_len + 32].copy_from_slice(&rp_id_hash); ad_len += 32;
                            auth_data[ad_len] = 0x41; ad_len += 1; // UP=1, AT=1
                            auth_data[ad_len..ad_len + 4].copy_from_slice(&counter.to_be_bytes()); ad_len += 4;
                            auth_data[ad_len..ad_len + 16].fill(0); ad_len += 16; // AAGUID = 0
                            auth_data[ad_len..ad_len + 2].copy_from_slice(&48u16.to_be_bytes()); ad_len += 2;
                            auth_data[ad_len..ad_len + 32].copy_from_slice(&cred_random); ad_len += 32;
                            auth_data[ad_len..ad_len + 16].copy_from_slice(&tag); ad_len += 16;

                            // Append COSE Key: map(5)
                            auth_data[ad_len] = 0xA5; ad_len += 1;
                            auth_data[ad_len..ad_len + 2].copy_from_slice(&[0x01, 0x02]); ad_len += 2; // kty: 2 (EC2)
                            auth_data[ad_len..ad_len + 2].copy_from_slice(&[0x03, 0x26]); ad_len += 2; // alg: -7 (ES256)
                            auth_data[ad_len..ad_len + 2].copy_from_slice(&[0x20, 0x01]); ad_len += 2; // crv: 1 (P-256)
                            auth_data[ad_len..ad_len + 2].copy_from_slice(&[0x21, 0x58]); ad_len += 2;
                            auth_data[ad_len] = 32; ad_len += 1;
                            auth_data[ad_len..ad_len + 32].copy_from_slice(x_bytes); ad_len += 32;
                            auth_data[ad_len..ad_len + 2].copy_from_slice(&[0x22, 0x58]); ad_len += 2;
                            auth_data[ad_len] = 32; ad_len += 1;
                            auth_data[ad_len..ad_len + 32].copy_from_slice(y_bytes); ad_len += 32;

                            // Self-sign attestation: SHA256(authData || clientDataHash)
                            let mut sig_hasher = Sha256::new();
                            sig_hasher.update(&auth_data[..ad_len]);
                            sig_hasher.update(&client_data_hash);
                            let sig_digest: [u8; 32] = sig_hasher.finalize().into();

                            if let Ok(sig) = backend.sign(&signing_key, &sig_digest) {
                                let sig_der = sig.to_der();

                                // Encode response CBOR map(3): 0x01 (fmt), 0x02 (authData), 0x03 (attStmt)
                                let mut w = 0;
                                out[w] = CTAP2_OK; w += 1;
                                out[w] = 0xA3; w += 1;

                                // 0x01: "packed"
                                out[w] = 0x01; w += 1;
                                out[w] = 0x66; w += 1;
                                out[w..w + 6].copy_from_slice(b"packed"); w += 6;

                                // 0x02: authData bytes
                                out[w] = 0x02; w += 1;
                                out[w] = 0x58; w += 1;
                                out[w] = ad_len as u8; w += 1;
                                out[w..w + ad_len].copy_from_slice(&auth_data[..ad_len]); w += ad_len;

                                // 0x03: attStmt: map(2) { "alg": -7, "sig": bytes }
                                out[w] = 0x03; w += 1;
                                out[w] = 0xA2; w += 1;
                                out[w] = 0x63; w += 1;
                                out[w..w + 3].copy_from_slice(b"alg"); w += 3;
                                out[w] = 0x26; w += 1; // -7
                                out[w] = 0x63; w += 1;
                                out[w..w + 3].copy_from_slice(b"sig"); w += 3;
                                out[w] = 0x58; w += 1;
                                out[w] = sig_der.as_bytes().len() as u8; w += 1;
                                out[w..w + sig_der.as_bytes().len()].copy_from_slice(sig_der.as_bytes()); w += sig_der.as_bytes().len();

                                send_response(class, cid, CTAPHID_CBOR, &out[..w]).await
                            } else {
                                send_response(class, cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await
                            }
                        }
                        _ => send_response(class, cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await,
                    }
                }
                Err(err_code) => send_response(class, cid, CTAPHID_CBOR, &[err_code]).await,
            }
        }
        CMD_AUTHENTICATOR_GET_ASSERTION => {
            match wait_for_user_presence(class, cid).await {
                Ok(_) => {
                    let mut reader = Reader::new(&req[1..]);
                    let mut rp_id_hash = [0u8; 32];
                    let mut client_data_hash = [0u8; 32];
                    let mut cred_random = [0x42u8; 32];
                    let mut cred_tag = [0u8; 16];
                    let mut found_cred = false;

                    if let Ok(Item::Map(pairs)) = reader.next() {
                        for _ in 0..pairs {
                            let k = reader.next().ok();
                            match k {
                                Some(Item::Uint(1)) => {
                                    if let Ok(Item::Text(rp_id)) = reader.next() {
                                        let mut h = Sha256::new();
                                        h.update(rp_id.as_bytes());
                                        rp_id_hash.copy_from_slice(&h.finalize());
                                    }
                                }
                                Some(Item::Uint(2)) => {
                                    if let Ok(Item::Bytes(cdh)) = reader.next() {
                                        if cdh.len() == 32 {
                                            client_data_hash.copy_from_slice(cdh);
                                        }
                                    }
                                }
                                Some(Item::Uint(3)) => {
                                    if let Ok(Item::Array(items)) = reader.next() {
                                        for _ in 0..items {
                                            if let Ok(Item::Map(desc_pairs)) = reader.next() {
                                                for _ in 0..desc_pairs {
                                                    if let Ok(Item::Text(k_str)) = reader.next() {
                                                        if k_str == "id" {
                                                            if let Ok(Item::Bytes(id_bytes)) = reader.next() {
                                                                if id_bytes.len() == 48 {
                                                                    cred_random.copy_from_slice(&id_bytes[..32]);
                                                                    cred_tag.copy_from_slice(&id_bytes[32..48]);
                                                                    found_cred = true;
                                                                }
                                                            }
                                                        } else {
                                                            let _ = reader.next();
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                _ => {
                                    let _ = reader.next();
                                }
                            }
                        }
                    }

                    if !found_cred || !backend.verify_credential_id(&cred_random, &rp_id_hash, &cred_tag) {
                        return send_response(class, cid, CTAPHID_CBOR, &[CTAP2_ERR_NO_CREDENTIALS]).await;
                    }

                    let counter = persist.increment_counter();
                    if let Ok(signing_key) = backend.derive_credential_key(&rp_id_hash, &cred_random, counter) {
                        let mut auth_data = [0u8; 37];
                        auth_data[..32].copy_from_slice(&rp_id_hash);
                        auth_data[32] = 0x01; // UP=1
                        auth_data[33..37].copy_from_slice(&counter.to_be_bytes());

                        let mut sig_hasher = Sha256::new();
                        sig_hasher.update(&auth_data);
                        sig_hasher.update(&client_data_hash);
                        let digest: [u8; 32] = sig_hasher.finalize().into();

                        if let Ok(sig) = backend.sign(&signing_key, &digest) {
                            let sig_der = sig.to_der();
                            let mut w = 0;
                            out[w] = CTAP2_OK; w += 1;
                            out[w] = 0xA2; w += 1; // map(2)

                            // 0x02: authData
                            out[w] = 0x02; w += 1;
                            out[w] = 0x58; w += 1;
                            out[w] = 37; w += 1;
                            out[w..w + 37].copy_from_slice(&auth_data); w += 37;

                            // 0x03: signature
                            out[w] = 0x03; w += 1;
                            out[w] = 0x58; w += 1;
                            out[w] = sig_der.as_bytes().len() as u8; w += 1;
                            out[w..w + sig_der.as_bytes().len()].copy_from_slice(sig_der.as_bytes()); w += sig_der.as_bytes().len();

                            send_response(class, cid, CTAPHID_CBOR, &out[..w]).await
                        } else {
                            send_response(class, cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await
                        }
                    } else {
                        send_response(class, cid, CTAPHID_CBOR, &[CTAP2_ERR_OPERATION_DENIED]).await
                    }
                }
                Err(err_code) => send_response(class, cid, CTAPHID_CBOR, &[err_code]).await,
            }
        }
        _ => send_response(class, cid, CTAPHID_CBOR, &[CTAP2_ERR_INVALID_COMMAND]).await,
    }
}

async fn run_fido_authenticator<'a, D: Driver<'a>, K: KeyBackend, P: PersistStore>(
    class: &mut HidReaderWriter<'a, D, 64, 64>,
    mut backend: K,
    mut persist: P,
) {
    let chan = CHANNEL.init(ChannelState::new());
    let in_buf = IN_PACKET.init([0u8; PACKET]);

    log!("exp183: active contract backend: {}", backend.name());

    loop {
        if class.read(in_buf).await.is_err() {
            continue;
        }

        let cid = read_u32_be(&in_buf[0..4]);
        let is_init = (in_buf[4] & 0x80) != 0;

        if is_init {
            let cmd = in_buf[4] & 0x7F;
            let bcnt = ((in_buf[5] as usize) << 8) | (in_buf[6] as usize);

            if cmd == CTAPHID_CANCEL {
                if chan.state == StateKind::Accumulating && chan.cid == cid {
                    chan.reset();
                }
                PRESENCE_CANCELLED.store(1, Ordering::Relaxed);
                continue;
            }

            if cmd == CTAPHID_INIT {
                if bcnt != 8 {
                    send_error(class, cid, ERR_INVALID_LEN).await;
                    continue;
                }
                let nonce = &in_buf[INIT_HEADER..INIT_HEADER + 8];
                let allocated = if cid == CID_BROADCAST { alloc_cid() } else { cid };

                let mut resp = [0u8; 17];
                resp[..8].copy_from_slice(nonce);
                write_u32_be(&mut resp[8..12], allocated);
                resp[12] = 2; // CTAPHID protocol version 2
                resp[13] = 1; // Major version
                resp[14] = 0; // Minor version
                resp[15] = 0; // Build version
                resp[16] = 0x08; // Capabilities: CBOR

                chan.cid = allocated;
                chan.reset();
                send_response(class, cid, CTAPHID_INIT, &resp).await;
                continue;
            }

            if chan.state == StateKind::Accumulating {
                if chan.cid != cid {
                    send_error(class, cid, ERR_CHANNEL_BUSY).await;
                    continue;
                }
            }

            if bcnt > MAX_MESSAGE {
                send_error(class, cid, ERR_INVALID_LEN).await;
                continue;
            }

            chan.cid = cid;
            chan.cmd = cmd;
            chan.total_len = bcnt;
            chan.next_seq = 0;
            chan.deadline = Instant::now() + TRANSACTION_TIMEOUT;

            let first = bcnt.min(INIT_PAYLOAD);
            chan.buf[..first].copy_from_slice(&in_buf[INIT_HEADER..INIT_HEADER + first]);
            chan.received = first;

            if chan.received >= chan.total_len {
                chan.state = StateKind::Idle;
                let payload = &chan.buf[..chan.total_len];
                match chan.cmd {
                    CTAPHID_PING => {
                        send_response(class, cid, CTAPHID_PING, payload).await;
                    }
                    CTAPHID_CBOR => {
                        handle_cbor(class, cid, payload, &mut backend, &mut persist).await;
                    }
                    _ => {
                        send_error(class, cid, ERR_INVALID_CMD).await;
                    }
                }
            } else {
                chan.state = StateKind::Accumulating;
            }
        } else {
            // Continuation packet
            let seq = in_buf[4] & 0x7F;
            if chan.state != StateKind::Accumulating || chan.cid != cid {
                continue;
            }

            if seq != chan.next_seq {
                chan.reset();
                send_error(class, cid, ERR_INVALID_SEQ).await;
                continue;
            }

            chan.next_seq = (chan.next_seq + 1) & 0x7F;
            let needed = chan.total_len - chan.received;
            let chunk = needed.min(CONT_PAYLOAD);
            chan.buf[chan.received..chan.received + chunk]
                .copy_from_slice(&in_buf[CONT_HEADER..CONT_HEADER + chunk]);
            chan.received += chunk;

            if chan.received >= chan.total_len {
                chan.state = StateKind::Idle;
                let payload = &chan.buf[..chan.total_len];
                match chan.cmd {
                    CTAPHID_PING => {
                        send_response(class, cid, CTAPHID_PING, payload).await;
                    }
                    CTAPHID_CBOR => {
                        handle_cbor(class, cid, payload, &mut backend, &mut persist).await;
                    }
                    _ => {
                        send_error(class, cid, ERR_INVALID_CMD).await;
                    }
                }
            }
        }
    }
}

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, usb_reboot::UsbDriver>) -> ! {
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

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());

    let driver = RpDriver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("Raspberry Pi");
    config.product = Some("RP2350 FIDO2 Authenticator (exp183)");
    config.serial_number = Some("183");
    config.max_power = 100;
    config.max_packet_size_0 = 64;

    static CONFIG_DESC: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESC: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; 128]> = StaticCell::new();
    static CDC_STATE: StaticCell<State> = StaticCell::new();
    static HID_STATE: StaticCell<HidState> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESC.init([0; 256]),
        BOS_DESC.init([0; 256]),
        &mut [],
        CONTROL_BUF.init([0; 128]),
    );

    let class = CdcAcmClass::new(&mut builder, CDC_STATE.init(State::new()), PACKET as u16);
    let mut hid = HidReaderWriter::<_, 64, 64>::new(
        &mut builder,
        HID_STATE.init(HidState::new()),
        HidConfig {
            report_descriptor: FIDO_REPORT_DESCRIPTOR,
            request_handler: None,
            poll_ms: 5,
            max_packet_size: 64,
            hid_subclass: embassy_usb::class::hid::HidSubclass::No,
            hid_boot_protocol: embassy_usb::class::hid::HidBootProtocol::None,
        },
    );

    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(cdc_task(control, receiver).unwrap());

    static PERSIST: StaticCell<MemoryPersistStore> = StaticCell::new();
    let persist = PERSIST.init(MemoryPersistStore::new(1));

    match ACTIVE_BACKEND {
        "bank8" => {
            let mut b = Bank8SecureBackend::new();
            b.init(&backends::test_key::COMPILED_IN_TEST_KEY);
            run_fido_authenticator(&mut hid, b, persist).await;
        }
        "puf" => {
            let mut b = PufReconstructedBackend::new();
            b.set_reconstructed_key(backends::test_key::COMPILED_IN_TEST_KEY);
            run_fido_authenticator(&mut hid, b, persist).await;
        }
        "otp_sim" => {
            let mut b = OtpSimulatedBackend::new();
            b.set_otp_row_data([0x5Au8; 32], true);
            run_fido_authenticator(&mut hid, b, persist).await;
        }
        _ => {
            let b = TestKeyBackend::new();
            run_fido_authenticator(&mut hid, b, persist).await;
        }
    }
}
