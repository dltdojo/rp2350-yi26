// SPDX-License-Identifier: Apache-2.0
//! # exp169 — what it says it can do
//!
//! One CTAP2 command, and it is the one where a device describes itself:
//! **`authenticatorGetInfo`**. Still no signing, still no credential, still no
//! secret — but for the first time a host parses a body rather than getting its
//! own bytes back, and for the first time this device has to make a **claim**.
//!
//! The second experiment on the
//! [authenticator road](../README.md#the-authenticator-road), built on
//! [exp168](../exp168-a-security-key-that-knows-nothing/)'s transport, which is
//! unchanged apart from one bit of the capability byte.
//!
//! ## The claim it has no honest way to make
//!
//! `getInfo`'s key `0x01` is `versions`: the CTAP versions this authenticator
//! supports. This one supports *part of* CTAP2 — `getInfo` and nothing else.
//! There is no string for that.
//!
//! exp168 found the opposite: the CTAPHID capability byte is fine-grained
//! enough to say **"no CBOR, no MSG"**, and `fido2-token` printed exactly that.
//! One layer up the vocabulary runs out, and the choice is between claiming
//! `FIDO_2_0` — which is not true — and claiming nothing, which may not be
//! legal or may not be useful.
//!
//! **So both are built and both are measured.** `EXP169_CLAIM=none` is the
//! default, because a plain `cargo build` should not ship the lie.
//!
//! ## Canonical CBOR is a property a host can check
//!
//! CTAP2 does not merely want CBOR; it wants the canonical form — shortest
//! integers, definite lengths, and map keys in ascending order. Two encoders
//! that disagree produce different bytes for the same data.
//!
//! [`crates/cbor`](../../crates/cbor/) is written for that and refuses to
//! produce anything else: a map key out of order is an error rather than a
//! response a host calls invalid. Its nine tests run on any machine with no
//! board — [`crates/fat12`](../../crates/fat12/)'s shape — and `verify.py`
//! decodes the response the board actually sent and re-checks canonicality from
//! the bytes.
//!

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicU32, Ordering};

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
use embassy_rp::trng::Trng;
use sha2::{Digest, Sha256};
use usb_log::log;

// UP_MODE and WAIT_FOR_USER, from build.rs and EXP173_UP.
include!(concat!(env!("OUT_DIR"), "/exp173_config.rs"));

/// **The whole of this device's identity, and it is a compiled-in test key.**
///
/// Every credential's private key is derived from it, so whoever has these
/// thirty-two bytes can produce every credential this board will ever make.
/// They are in flash, `XIP_MAIN` is fully open
/// ([exp159](../exp159-a-key-that-was-never-in-flash/)), and
/// [exp166](../exp166-whose-firmware-will-it-accept/) demonstrated finding such
/// a constant inside a `.uf2` with a byte search.
///
/// That is not a placeholder for something better later. It is the
/// [identity road](../README.md#the-identity-road)'s question arriving with a
/// name: **a device secret has to be the same across reboots and written
/// nowhere, and this part has no such thing yet** —
/// [`docs/can-this-chip-keep-a-secret.md`](../../docs/can-this-chip-keep-a-secret.md)
/// is eight experiments' worth of why.
const DEVICE_SECRET: [u8; 32] = [
    0x6e, 0x6f, 0x74, 0x20, 0x61, 0x20, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74, 0x2e, 0x20, 0x74, 0x68,
    0x69, 0x73, 0x20, 0x69, 0x73, 0x20, 0x61, 0x20, 0x74, 0x65, 0x73, 0x74, 0x20, 0x6b, 0x65, 0x79,
];

/// **Earned, at last.** exp169 built this device claiming `FIDO_2_0` and
/// measured what it cost: `libfido2` believed it and a tool that acted on the
/// claim returned `FIDO_ERR_INTERNAL`, because the device had `getInfo` and
/// nothing else. exp171 added `makeCredential` and exp172 added
/// `getAssertion`, which is what `FIDO_2_0` is for — so the string that was a
/// lie three experiments ago is now a description.
///
/// It is still not the whole of CTAP2: no `clientPIN`, no resident credentials,
/// no extensions. The specification does not require those of a `FIDO_2_0`
/// authenticator, and the ones it does require are here.
const VERSIONS: [&str; 1] = ["FIDO_2_0"];

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    TRNG_IRQ => embassy_rp::trng::InterruptHandler<TRNG>;
});

/// **The FIDO HID report descriptor, by hand.** Thirty-four bytes, fixed by the
/// CTAP specification, and the reason a host's FIDO tooling will look at this
/// device at all: `libfido2` finds authenticators by usage page `0xF1D0`, not by
/// vendor or product ID.
///
/// Two reports, both 64 bytes of raw data with no report ID: one IN and one OUT.
/// A security key's whole transport is those two.
#[rustfmt::skip]
const FIDO_REPORT_DESCRIPTOR: &[u8] = &[
    0x06, 0xD0, 0xF1, // Usage Page (vendor-defined 0xF1D0 — the FIDO Alliance's)
    0x09, 0x01,       // Usage (U2F HID Authenticator Device)
    0xA1, 0x01,       // Collection (Application)
    0x09, 0x20,       //   Usage (Input Report Data)
    0x15, 0x00,       //   Logical Minimum (0)
    0x26, 0xFF, 0x00, //   Logical Maximum (255) — two bytes, because 0xFF in one
                      //                           would be read as -1
    0x75, 0x08,       //   Report Size (8 bits)
    0x95, 0x40,       //   Report Count (64) — the packet size the protocol assumes
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
/// An initialisation packet: `CID(4) + CMD(1) + BCNTH(1) + BCNTL(1)`.
const INIT_HEADER: usize = 7;
/// A continuation packet: `CID(4) + SEQ(1)`.
const CONT_HEADER: usize = 5;
const INIT_PAYLOAD: usize = PACKET - INIT_HEADER; // 57
const CONT_PAYLOAD: usize = PACKET - CONT_HEADER; // 59

/// The largest message this device will assemble.
///
/// The specification allows 7609 bytes; nothing here needs them, and a buffer
/// is RAM whether it is used or not. What matters is that the limit produces
/// **`ERR_INVALID_LEN`** rather than a silent truncation or a wedged channel,
/// which is a case the host client asks for on purpose.
const MAX_MESSAGE: usize = 1024;

/// How long an incomplete transaction is held before the channel is freed.
/// The specification puts this between 500 ms and 3 s. A `BCNT` that promises
/// more than ever arrives must not hold a channel for ever, and the host client
/// checks that by promising and then not delivering.
const TRANSACTION_TIMEOUT: Duration = Duration::from_millis(750);

const CTAPHID_PING: u8 = 0x01;
const CTAPHID_MSG: u8 = 0x03;
const CTAPHID_INIT: u8 = 0x06;
const CTAPHID_CBOR: u8 = 0x10;
const CTAPHID_ERROR: u8 = 0x3F;

const ERR_INVALID_CMD: u8 = 0x01;
const ERR_INVALID_LEN: u8 = 0x03;
const ERR_INVALID_SEQ: u8 = 0x04;
const ERR_MSG_TIMEOUT: u8 = 0x05;
const ERR_CHANNEL_BUSY: u8 = 0x06;
const ERR_INVALID_CHANNEL: u8 = 0x0B;

/// Every channel identifier is compared as four bytes and never as a number.
/// The specification calls it opaque, this firmware is the only thing that
/// allocates one, and treating it as an integer would import a byte-order
/// question that does not exist.
type Cid = [u8; 4];
const BROADCAST: Cid = [0xff, 0xff, 0xff, 0xff];
/// Reserved by the specification, and therefore the one value an allocation
/// must never return.
const RESERVED: Cid = [0x00, 0x00, 0x00, 0x00];

/// `CAPABILITY_CBOR | CAPABILITY_NMSG`.
///
/// exp168 sent `0x08` — no CBOR, no MSG — and `fido2-token` printed
/// `nocbor, nomsg`. **One bit changes here**, and it is the entire difference
/// between a device a host will send a CTAP2 command to and one it will not.
/// `CAPABILITY_NMSG` stays set because CTAP1/U2F really is not implemented.
const CAPABILITIES: u8 = 0x04 | 0x08;

/// CTAP2 status codes. `0x00` is success and everything else is a refusal with
/// a name, which is the half of CTAP2 this device implements in full.
const CTAP2_OK: u8 = 0x00;
const CTAP1_ERR_INVALID_COMMAND: u8 = 0x01;
const CTAP1_ERR_INVALID_LENGTH: u8 = 0x03;
/// The CBOR was not something this device would read. **Distinct from
/// `INVALID_COMMAND` on purpose**: exp169 said "I do not know this command",
/// and this says "I know it and your bytes are wrong".
const CTAP2_ERR_INVALID_CBOR: u8 = 0x12;
/// A parameter `makeCredential` requires was not there.
const CTAP2_ERR_MISSING_PARAMETER: u8 = 0x14;
/// None of the algorithms offered is one this device would use.
const CTAP2_ERR_UNSUPPORTED_ALGORITHM: u8 = 0x26;
/// **The status this experiment exists to send.** The request was read, every
/// field understood, and the answer is still no. exp169 refused
/// `makeCredential` with `INVALID_COMMAND` because it could not read it; this
/// one can, and says so with a different number.
const CTAP2_ERR_OPERATION_DENIED: u8 = 0x27;
/// Nothing in the allow list is a credential this device made for this relying
/// party — **or the allow list was empty**, which on a device with no resident
/// credentials is the same answer.
const CTAP2_ERR_NO_CREDENTIALS: u8 = 0x2E;

/// COSE's identifier for ECDSA with SHA-256, which is the algorithm every FIDO2
/// client offers first and the only one this road will implement.
const COSE_ES256: i64 = -7;

/// How long the `button` build waits for a finger. A person who is not there
/// has to become an answer rather than a hang, and the host is holding a
/// transaction open the whole time — which is the thing this experiment
/// measures rather than fixes.
const USER_PRESENCE_TIMEOUT: Duration = Duration::from_secs(10);

/// `authenticatorGetInfo`. The only CTAP2 command here, and the only one that
/// asks a device to describe itself rather than to do something.
const AUTHENTICATOR_GET_INFO: u8 = 0x04;
const AUTHENTICATOR_MAKE_CREDENTIAL: u8 = 0x01;
const AUTHENTICATOR_GET_ASSERTION: u8 = 0x02;

/// All zero, and that is a statement rather than a placeholder. The AAGUID
/// identifies an authenticator **model** to a relying party; a device with no
/// attestation identity reports zeros, and inventing one would be claiming to
/// be a product that exists.
const AAGUID: [u8; 16] = [0; 16];

const PRODUCT: &str = "exp173 a client that is not ours";
const CONTROL_BUF_LEN: usize = 128;
const _: () = assert!(
    2 * PRODUCT.len() + 2 < CONTROL_BUF_LEN,
    "product string will overflow embassy-usb's control buffer and panic mid-enumeration"
);

/// Milliseconds between log lines. `usb-log` queues sixteen and drops the rest;
/// four experiments on the signing road paid for that queue before this number
/// was written down.
const PACE: Duration = Duration::from_millis(60);

static PACKETS_IN: AtomicU32 = AtomicU32::new(0);
static MESSAGES: AtomicU32 = AtomicU32::new(0);
static ERRORS: AtomicU32 = AtomicU32::new(0);
/// The last allocated channel, as a number, purely so the next allocation
/// differs from the last. Starts at 1 so the first channel is never [`RESERVED`].
static NEXT_CID: AtomicU32 = AtomicU32::new(1);

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
        _ => "?",
    }
}

/// A message being assembled from packets. There is exactly one, because
/// CTAPHID is a single-transaction protocol: a second channel that interrupts
/// one gets `ERR_CHANNEL_BUSY`, which is the specification's answer to
/// [exp136](../exp136-joining-halfway/)'s question and the reason this
/// experiment can grade it.
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

/// What a packet made this device decide. Returned rather than acted on, so the
/// decision and the reply are in different places and the log can print the
/// first without depending on the second.
enum Action {
    /// Nothing to send. A spurious continuation packet is *ignored* by the
    /// specification rather than answered, which is the one place CTAPHID
    /// chooses silence — and the reason this variant exists instead of an
    /// error.
    Ignore(&'static str),
    Error(Cid, u8),
    /// A complete message, ready for whatever the command means.
    Complete,
    /// More packets are expected. Nothing goes back until they arrive.
    More,
}

/// Feed one 64-byte report into the state machine.
fn feed(t: &mut Transaction, pkt: &[u8]) -> Action {
    if pkt.len() < PACKET {
        return Action::Ignore("a report shorter than 64 bytes");
    }
    let cid: Cid = [pkt[0], pkt[1], pkt[2], pkt[3]];
    let is_init = pkt[4] & 0x80 != 0;

    // Time first. A transaction that has run out is gone before this packet is
    // judged against it, so a slow host is told its message expired rather than
    // being told the channel is busy with its own dead attempt.
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

        // The broadcast channel exists for exactly one command.
        if cid == BROADCAST && cmd != CTAPHID_INIT {
            return Action::Error(cid, ERR_INVALID_CHANNEL);
        }
        if cid == RESERVED {
            return Action::Error(cid, ERR_INVALID_CHANNEL);
        }

        // INIT on an allocated channel is not a new transaction: the
        // specification makes it the way a host **resynchronises** one it has
        // lost track of. So it clears whatever was in flight rather than being
        // refused as busy — which is the opposite of what every other command
        // gets, and is why this test is above the busy test.
        if cmd == CTAPHID_INIT {
            t.clear();
        } else if t.busy() && t.cid != cid {
            return Action::Error(cid, ERR_CHANNEL_BUSY);
        }

        if want > MAX_MESSAGE {
            return Action::Error(cid, ERR_INVALID_LEN);
        }
        if cmd == CTAPHID_INIT && want != 8 {
            // An INIT request is a nonce and nothing else.
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
        // A continuation packet for a transaction nobody started is not an
        // error to report; it is a packet from a conversation this device is
        // not having.
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

/// Allocate a channel. Never [`RESERVED`], never [`BROADCAST`], and different
/// from the last one — which is all the specification asks, and all a host uses
/// it for.
fn allocate_cid() -> Cid {
    let mut n = NEXT_CID.fetch_add(1, Ordering::Relaxed);
    if n == 0 || n == u32::from_be_bytes(BROADCAST) {
        n = NEXT_CID.fetch_add(1, Ordering::Relaxed) | 1;
    }
    n.to_be_bytes()
}

/// Send a message as an initialisation packet followed by however many
/// continuation packets it needs. The mirror of [`feed`], and the half a host
/// tests by asking for more than 57 bytes back.
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

/// A credential ID: a random nonce, and a tag that says this device made it.
///
/// ```text
///   nonce (32)  ||  HMAC-SHA256(secret, "id" || nonce || rpIdHash)[..16]
/// ```
///
/// The nonce is what makes each credential different; the tag is what stops
/// anybody else's forty-eight bytes being accepted later. **A credential ID
/// without a tag is one an attacker can invent**, and a device that derived a
/// key for any bytes it was handed would sign for relying parties it had never
/// registered with. Nothing in *this* experiment reads a credential ID back —
/// that is `getAssertion`'s job — and building it unauthenticated now would be
/// leaving a hole for a later experiment to fall into.
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

/// Derive this credential's private key.
///
/// **The key is never stored.** It is recomputed from the device secret, the
/// nonce in the credential ID and the relying party — so it exists only while
/// it is being used, which is [exp163](../exp163-how-long-is-a-secret-in-the-open/)'s
/// subject and its limit applies here unchanged. Binding the derivation to
/// `rpIdHash` is free and means a credential made for one relying party
/// produces a different key for another.
///
/// A hash output is not automatically a valid P-256 scalar — it has to be in
/// `[1, n-1]` — so the counter is incremented until one is. Rejection rather
/// than reduction, because reducing a uniform 256-bit value modulo `n` is
/// biased, and a biased ECDSA nonce is a famous way to lose a key. This is a
/// long-term key rather than a nonce, so the bias would be smaller and the
/// habit is worth keeping either way.
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

/// Flags, from the WebAuthn authenticator data. Only three matter here.
const FLAG_UP: u8 = 0x01; // a person was present
/// A person was *verified* — a PIN or a fingerprint, not just a press. Named
/// here and never set anywhere, so a reader can see that the absence is a
/// decision: this device has no way to verify anybody, and a flag it cannot
/// earn is one it must not raise.
#[allow(dead_code)]
const FLAG_UV: u8 = 0x04;
const FLAG_AT: u8 = 0x40; // attested credential data follows

/// Build the authenticator data and the attestation, and sign them.
///
/// Returns the whole `makeCredential` response as canonical CBOR:
/// `{1: "packed", 2: authData, 3: {"alg": -7, "sig": ...}}`.
///
/// **This is self attestation**, which means the signature is made with the
/// credential's own private key and there is no certificate. It is what an
/// authenticator with no attestation identity is supposed to do, and it is why
/// the AAGUID is sixteen zeros — the specification requires that pairing, and a
/// device that shipped a non-zero AAGUID with self attestation would be
/// claiming a model it cannot prove.
/// How the response came out, so the log can say what it cost and a host can
/// check what it got.
struct Built {
    response: usize,
    auth_len: usize,
    cose_len: usize,
    derive_us: u64,
    sign_us: u64,
}

/// Build the authenticator data, sign it, and write the whole `makeCredential`
/// response as canonical CBOR: `{1: "packed", 2: authData, 3: {"alg": -7,
/// "sig": ...}}`.
///
/// **This is self attestation**: the signature is made with the credential's
/// own private key and there is no certificate. It is what an authenticator
/// with no attestation identity is supposed to do, and it is why the AAGUID is
/// sixteen zeros — the specification pairs those two, and a device that shipped
/// a non-zero AAGUID with self attestation would be claiming a model it cannot
/// prove.
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

    // ---- the COSE public key --------------------------------------------
    let cose_len = {
        let mut w = cbor::Writer::new(&mut scratch[..]);
        w.map(5);
        w.key(1); // kty
        w.uint(2); // EC2
        w.key(3); // alg
        w.nint(COSE_ES256);
        w.key_nint(-1); // crv
        w.uint(1); // P-256
        w.key_nint(-2); // x
        w.bytes(x);
        w.key_nint(-3); // y
        w.bytes(y);
        w.end();
        w.finish().map_err(|_| ())?.len()
    };

    // ---- the authenticator data -----------------------------------------
    let mut n = 0usize;
    auth[..32].copy_from_slice(&rp_id_hash);
    n += 32;
    auth[n] = FLAG_AT | if user_present { FLAG_UP } else { 0 };
    n += 1;
    // The signature counter. Zero, always, and that is a decision: a counter
    // that survives a reset is a counter that is stored, and this device stores
    // nothing. A relying party that enforces monotonicity will notice, which is
    // a limit rather than a bug and is written down as one.
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

    // ---- the signature ---------------------------------------------------
    //
    // Over the authenticator data followed by the client data hash, in that
    // order and with nothing between them. Getting that concatenation wrong
    // produces a signature that verifies against nothing and looks exactly like
    // a broken key, which is why the host half checks it rather than the board
    // asserting it.
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

    // ---- the response ----------------------------------------------------
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

/// Compare two tags without telling anybody how far they matched.
///
/// The obvious loop returns as soon as two bytes differ, and how long it took
/// is a measurement of how many bytes were right. Forging sixteen bytes that
/// way is sixteen times 256 guesses instead of 2^128, and the only thing
/// standing between those two numbers is whether this function is allowed to
/// return early.
///
/// On this part a whole assertion costs about 100 ms, so the difference this
/// leaks would be buried in noise and an attacker would need a great many
/// tries. That is an argument for the attack being hard, not for the code being
/// right, and the fix costs one `|=`.
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

/// Is this a credential **this device** made, **for this relying party**?
///
/// The tag in the credential ID is `HMAC(secret, "id" ‖ nonce ‖ rpIdHash)`, so
/// recomputing it with the `rpIdHash` from *this* request answers both
/// questions at once. A device without the tag would happily derive a key for
/// any forty-eight bytes it was handed; a device whose tag did not cover the
/// relying party would sign for a site it had never registered with, using a
/// credential somebody collected somewhere else.
fn credential_is_ours(cred_id: &[u8], rp_id_hash: &[u8; 32]) -> bool {
    if cred_id.len() != CRED_ID_LEN {
        return false;
    }
    let (nonce, tag) = cred_id.split_at(32);
    let mut want = [0u8; TAG_LEN];
    mac(b"id", nonce, rp_id_hash, &mut want);
    tags_equal(&want, tag)
}

/// What a `getAssertion` request asked for.
struct GetAssertion<'a> {
    rp_id: &'a str,
    client_data_hash: &'a [u8],
    /// The credential IDs offered, in the order offered. This device has no
    /// resident credentials, so an empty list is not "pick one" — it is
    /// `CTAP2_ERR_NO_CREDENTIALS`, and saying so is the difference between a
    /// device that has nothing and one that will not say.
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
        // No allow list at all means "use a resident credential", and this
        // device has none. Refusing by name beats refusing by silence.
        return Err(CTAP2_ERR_NO_CREDENTIALS);
    }

    Ok(GetAssertion { rp_id, client_data_hash, allow, n_allow, allow_truncated })
}

/// Build a `getAssertion` response: `{1: {"id": ..., "type": "public-key"},
/// 2: authData, 3: signature}`.
///
/// **The authenticator data here has no attested credential data**, so the `AT`
/// flag is clear and the structure is 37 bytes rather than 180. A device that
/// copied its registration path would set `AT` and attach a public key nobody
/// asked for, which is a different message than the one the specification
/// describes.
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

/// What a `makeCredential` request asked for, as much of it as this device
/// reads. Borrowed from the message buffer: nothing is copied, because a
/// parser that copies every field an attacker sends is a parser an attacker
/// sizes.
struct MakeCredential<'a> {
    client_data_hash: &'a [u8],
    rp_id: &'a str,
    user_id: &'a [u8],
    /// The algorithms offered, in the order offered, up to what fits.
    algs: [i64; MAX_ALGS],
    n_algs: usize,
    /// True if `pubKeyCredParams` held more entries than [`MAX_ALGS`]. Recorded
    /// rather than ignored: a device that silently drops the caller's fifth
    /// choice and then refuses is a device whose refusal is about the wrong
    /// thing.
    algs_truncated: bool,
}

const MAX_ALGS: usize = 8;

/// Find a text key inside a CBOR map and leave the reader on its value.
///
/// Returns `false` if the key is not there, with the reader positioned after
/// the map either way — so a caller can keep going rather than having to know
/// how much to skip.
fn find_text_key(r: &mut Reader, pairs: u64, want: &str) -> Result<bool, ReadError> {
    for _ in 0..pairs {
        let is_it = match r.next()? {
            Item::Text(k) => k == want,
            // Integer keys are legal in a CBOR map and are not what the WebAuthn
            // dictionaries use. Skipping the value keeps the cursor honest.
            Item::Uint(_) | Item::Nint(_) => false,
            _ => return Err(ReadError::NotCanonical),
        };
        if is_it {
            // The value is left unread: the caller reads it next, from where
            // this leaves the cursor.
            return Ok(true);
        }
        r.skip()?;
    }
    Ok(false)
}

/// Read a `makeCredential` request.
///
/// **Every length in here came from whoever sent the message.**
/// [`cbor::Reader`] bounds-checks each one against the buffer it was given, so
/// the worst a hostile length can do is end this function early with
/// [`ReadError::Truncated`]. That is the whole reason the reader exists and the
/// reason this experiment comes before the one that signs anything.
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
            // The top-level map's keys are the numbered parameters. Anything
            // else is a message built by something other than a CTAP2 client.
            _ => return Err(CTAP2_ERR_INVALID_CBOR),
        };
        match key {
            0x01 => match r.next().map_err(status_for)? {
                Item::Bytes(b) => client_data_hash = Some(b),
                _ => return Err(CTAP2_ERR_INVALID_CBOR),
            },
            0x02 => {
                // rp is a map with text keys; only `id` matters here.
                let n = match r.next().map_err(status_for)? {
                    Item::Map(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                let mut rest = n;
                let mut it = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it, n, "id").map_err(status_for)? {
                    match it.next().map_err(status_for)? {
                        Item::Text(v) => rp_id = Some(v),
                        _ => return Err(CTAP2_ERR_INVALID_CBOR),
                    }
                }
                // Whatever was read above, the outer cursor still has to step
                // over the whole map, and it does that by its own arithmetic
                // rather than by trusting the inner reader's position.
                let _ = &mut rest;
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
            // Everything else — excludeList, extensions, options, pinUvAuth —
            // is stepped over. Skipping is not ignoring: `skip` still checks
            // the bytes it walks past, so a lie inside a field this device does
            // not use is still a lie it refuses.
            _ => r.skip().map_err(status_for)?,
        }
    }

    if !r.is_empty() {
        // Trailing bytes after a complete map. Two implementations disagree
        // about that message, and this one says so instead of picking a side.
        return Err(CTAP2_ERR_INVALID_CBOR);
    }

    let client_data_hash = client_data_hash.ok_or(CTAP2_ERR_MISSING_PARAMETER)?;
    let rp_id = rp_id.ok_or(CTAP2_ERR_MISSING_PARAMETER)?;
    let user_id = user_id.ok_or(CTAP2_ERR_MISSING_PARAMETER)?;
    if !have_params {
        return Err(CTAP2_ERR_MISSING_PARAMETER);
    }
    if client_data_hash.len() != 32 {
        // A SHA-256 hash is 32 bytes. A client that sends another length is
        // not sending a client data hash.
        return Err(CTAP2_ERR_INVALID_CBOR);
    }

    Ok(MakeCredential { client_data_hash, rp_id, user_id, algs, n_algs, algs_truncated })
}

/// Step the reader over `pairs` key/value pairs of a map whose header has
/// already been read.
fn skip_map_pairs(r: &mut Reader, pairs: u64) -> Result<(), ReadError> {
    for _ in 0..pairs {
        r.skip()?; // key
        r.skip()?; // value
    }
    Ok(())
}

/// Which CTAP2 status a read error becomes. Every one of them is
/// `INVALID_CBOR`, and naming them separately in the log while sending one
/// number is deliberate: the host is told what the protocol has words for, and
/// the log says what actually happened.
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

/// Build an `authenticatorGetInfo` response: a status byte, then a canonical
/// CBOR map.
///
/// Three keys, and each one is a decision:
///
/// - **`0x01` versions** — the claim this experiment is about. `EXP169_CLAIM`
///   decides whether it is `["FIDO_2_0"]` or empty, and the run says what each
///   costs.
/// - **`0x03` aaguid** — sixteen zero bytes. See [`AAGUID`].
/// - **`0x05` maxMsgSize** — the same [`MAX_MESSAGE`] the transport enforces,
///   so a host that believes it and a host that tries it get the same answer.
///   A device whose declared limit and real limit differ is one whose refusals
///   look arbitrary.
///
/// Keys ascend — 1, 3, 5 — because canonical CBOR requires it, and
/// [`cbor::Writer::key`] refuses rather than allows if they do not.
fn get_info(buf: &mut [u8]) -> Result<&[u8], cbor::Error> {
    let mut w = cbor::Writer::new(buf);
    w.map(4);
    w.key(0x01);
    w.array(VERSIONS.len() as u32);
    for v in VERSIONS {
        w.text(v);
    }
    w.end();
    w.key(0x03);
    w.bytes(&AAGUID);
    // **Options**, key 0x04, and both entries are measurements of this build
    // rather than aspirations. `rk` is resident credentials, which a device
    // that stores nothing cannot have. `up` says whether this authenticator can
    // ask a person at all — true in the `button` build and false in the one
    // that asks nobody, because a capability a build does not have is one it
    // must not announce.
    //
    // Text keys, so canonical order is by length then bytes: "rk" before "up".
    w.key(0x04);
    w.map(2);
    w.key_text("rk");
    w.bool(false);
    w.key_text("up");
    w.bool(WAIT_FOR_USER);
    w.end();
    w.key(0x05);
    w.uint(MAX_MESSAGE as u64);
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

/// The CDC half: the 1200-baud reflash watcher, so the next flash needs no
/// button. Nothing on this experiment's CDC interface is a command — the FIDO
/// interface is where things are asked, and this one only ever reports.
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
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}

static TRANSACTION: StaticCell<Transaction> = StaticCell::new();

/// The experiment. Reads 64-byte reports, assembles messages, and answers the
/// two commands it has: `INIT` and `PING`. Everything else is an error with a
/// number, because a device that quietly ignores what it does not implement is
/// a device whose silence a host has to guess about.
#[embassy_executor::task]
async fn ctaphid_task(
    hid: HidReaderWriter<'static, usb_reboot::UsbDriver, PACKET, PACKET>,
    t: &'static mut Transaction,
    mut trng: Trng<'static, TRNG>,
) -> ! {
    let (mut reader, mut writer) = hid.split();
    let mut pkt = [0u8; PACKET];

    loop {
        // A read with a deadline, so a transaction that was promised and never
        // finished expires even if the host never sends another byte. Without
        // this the channel is held until something arrives, which is a device
        // that one truncated message takes out of service.
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

        // **Only initialisation packets are logged, and that is not tidiness.**
        // The first version printed a paced line for every packet, and a
        // 1024-byte PING is eighteen of them: at 60 ms a line the device spent
        // 1.08 s reassembling a message its own 750 ms deadline then expired.
        // A legal message failed because the instrument was slower than the
        // subject. Continuation packets are counted and reported once, when the
        // message is whole.
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
                        // nonce(8) + new channel(4) + protocol(1) + version(3)
                        // + capabilities(1). The nonce is echoed so a host can
                        // tell its own INIT response from somebody else's.
                        let new = allocate_cid();
                        let mut r = [0u8; 17];
                        r[..8].copy_from_slice(&t.buf[..8]);
                        r[8..12].copy_from_slice(&new);
                        r[12] = 2; // CTAPHID protocol version
                        r[13] = 0; // device major
                        r[14] = 1; // device minor
                        r[15] = 0; // device build
                        r[16] = CAPABILITIES;
                        t.clear();
                        log!("  INIT: nonce {} -> cid {}", Hex(&r[..8]), Hex(&new));
                        Timer::after(PACE).await;
                        send(&mut writer, cid, CTAPHID_INIT, &r).await;
                    }
                    CTAPHID_PING => {
                        // The whole of PING: send back exactly what arrived.
                        // Which makes it the only command whose correctness is
                        // entirely about the reassembly above and the
                        // fragmentation below.
                        let n = len;
                        t.clear();
                        let packets = send(&mut writer, cid, CTAPHID_PING, &t.buf[..n]).await;
                        log!("  PING: echoed {} bytes in {} packets", n, packets);
                        Timer::after(PACE).await;
                    }
                    CTAPHID_CBOR => {
                        // A CBOR message is a CTAP2 command byte followed by
                        // that command's parameters. A reply is a **status
                        // byte** followed by the response, and a refusal is a
                        // status byte on its own — so every path below produces
                        // something a host can read, including the refusals.
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
                                        log!("  getInfo: {} bytes of canonical CBOR", body.len());
                                        Timer::after(PACE).await;
                                        send(&mut writer, cid, CTAPHID_CBOR, &out[..n]).await;
                                    }
                                    Err(_) => {
                                        // The encoder refused. That is a bug in
                                        // this firmware, and saying so is
                                        // better than sending bytes it already
                                        // knows are wrong.
                                        ERRORS.fetch_add(1, Ordering::Relaxed);
                                        log!("  getInfo: the encoder refused; sending nothing but a status");
                                        Timer::after(PACE).await;
                                        send(&mut writer, cid, CTAPHID_CBOR, &[0x7f]).await;
                                    }
                                }
                            }
                            // **The command this experiment is about.** It is
                            // read in full and then refused, and the two halves
                            // are separate: a request this device cannot parse
                            // and a request it will not act on are different
                            // answers, and exp169 could only give the first.
                            AUTHENTICATOR_MAKE_CREDENTIAL => {
                                let body = &t.buf[1..len];
                                // The reader is run twice on a failure: once to
                                // get the status a host is told, and once to
                                // name in the log what was actually wrong. The
                                // protocol has one number for five different
                                // mistakes, and a reader debugging this needs
                                // the other four.
                                match parse_make_credential(body) {
                                    Ok(req) => {
                                        log!("  makeCredential, and it parsed:");
                                        Timer::after(PACE).await;
                                        log!("    rp.id      = {:?}", req.rp_id);
                                        Timer::after(PACE).await;
                                        log!("    user.id    = {} bytes", req.user_id.len());
                                        Timer::after(PACE).await;
                                        log!(
                                            "    clientData = {} ({} bytes)",
                                            Hex(&req.client_data_hash[..8]),
                                            req.client_data_hash.len()
                                        );
                                        Timer::after(PACE).await;
                                        let mut es256 = false;
                                        for a in &req.algs[..req.n_algs] {
                                            log!(
                                                "    alg        = {}{}",
                                                a,
                                                if *a == COSE_ES256 { "  (ES256)" } else { "" }
                                            );
                                            Timer::after(PACE).await;
                                            if *a == COSE_ES256 {
                                                es256 = true;
                                            }
                                        }
                                        if req.algs_truncated {
                                            log!("    (more algorithms were offered than this device records)");
                                            Timer::after(PACE).await;
                                        }
                                        if !es256 {
                                            ERRORS.fetch_add(1, Ordering::Relaxed);
                                            log!("  ES256 was not offered; nothing here could be used.");
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

                                        // **User presence.** The bit in the
                                        // authenticator data says whether a
                                        // person was there, and this build
                                        // either waits for one or says no. It
                                        // never says yes without asking.
                                        let present = if WAIT_FOR_USER {
                                            log!("  waiting for BOOTSEL. Nothing is sent while this runs.");
                                            Timer::after(PACE).await;
                                            let start = Instant::now();
                                            let mut got = false;
                                            while start.elapsed() < USER_PRESENCE_TIMEOUT {
                                                if bootsel::is_pressed() {
                                                    got = true;
                                                    break;
                                                }
                                                Timer::after(Duration::from_millis(20)).await;
                                            }
                                            log!(
                                                "  {} after {} ms",
                                                if got { "pressed" } else { "nobody pressed anything" },
                                                start.elapsed().as_millis()
                                            );
                                            Timer::after(PACE).await;
                                            got
                                        } else {
                                            log!("  nobody is asked in this build: the UP bit will be 0.");
                                            Timer::after(PACE).await;
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
                                                    "  credential made: authData {} B (COSE key {} B), response {} B",
                                                    b.auth_len,
                                                    b.cose_len,
                                                    b.response
                                                );
                                                Timer::after(PACE).await;
                                                log!(
                                                    "  derive {} us, sign {} us, UP bit {}",
                                                    b.derive_us,
                                                    b.sign_us,
                                                    present as u8
                                                );
                                                Timer::after(PACE).await;
                                                log!("  the private key is not stored; it was derived and is gone.");
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
                                                log!("  building the credential failed inside this firmware.");
                                                Timer::after(PACE).await;
                                                send(&mut writer, cid, CTAPHID_CBOR, &[0x7f]).await;
                                            }
                                        }
                                    }
                                    Err(status) => {
                                        ERRORS.fetch_add(1, Ordering::Relaxed);
                                        // Name it, for the log only.
                                        let why = {
                                            let mut probe = Reader::new(body);
                                            match probe.skip() {
                                                Err(e) => read_error_name(e),
                                                Ok(()) if !probe.is_empty() => {
                                                    "trailing bytes after the map"
                                                }
                                                Ok(()) => "a field this command requires was missing",
                                            }
                                        };
                                        log!("  makeCredential refused: {}", why);
                                        Timer::after(PACE).await;
                                        log!("  status {:#04x}, and nothing was read past the buffer.", status);
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
                                        log!("  getAssertion refused before anything was derived: {:#04x}", status);
                                        Timer::after(PACE).await;
                                        send(&mut writer, cid, CTAPHID_CBOR, &[status]).await;
                                    }
                                    Ok(req) => {
                                        log!("  getAssertion for {:?}, {} credential(s) offered", req.rp_id, req.n_allow);
                                        Timer::after(PACE).await;
                                        if req.allow_truncated {
                                            log!("    (more were offered than this device looks at)");
                                            Timer::after(PACE).await;
                                        }
                                        let rp_id_hash: [u8; 32] =
                                            Sha256::digest(req.rp_id.as_bytes()).into();

                                        // **The check this experiment is
                                        // about.** Each candidate is asked one
                                        // question — did *this* device make you
                                        // for *this* relying party — and the
                                        // answer comes from a tag rather than
                                        // from a list nobody is keeping.
                                        let mut chosen: Option<&[u8]> = None;
                                        for c in &req.allow[..req.n_allow] {
                                            let ours = credential_is_ours(c, &rp_id_hash);
                                            log!(
                                                "    credential {} bytes: {}",
                                                c.len(),
                                                if ours { "ours, for this relying party" } else { "not ours" }
                                            );
                                            Timer::after(PACE).await;
                                            if ours && chosen.is_none() {
                                                chosen = Some(c);
                                            }
                                        }
                                        let Some(cred_id) = chosen else {
                                            ERRORS.fetch_add(1, Ordering::Relaxed);
                                            log!("  nothing offered was ours: no key is derived at all.");
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
                                            log!("  waiting for BOOTSEL. Nothing is sent while this runs.");
                                            Timer::after(PACE).await;
                                            let start = Instant::now();
                                            let mut got = false;
                                            while start.elapsed() < USER_PRESENCE_TIMEOUT {
                                                if bootsel::is_pressed() {
                                                    got = true;
                                                    break;
                                                }
                                                Timer::after(Duration::from_millis(20)).await;
                                            }
                                            log!(
                                                "  {} after {} ms",
                                                if got { "pressed" } else { "nobody pressed anything" },
                                                start.elapsed().as_millis()
                                            );
                                            Timer::after(PACE).await;
                                            got
                                        } else {
                                            log!("  nobody is asked in this build: the UP bit will be 0.");
                                            Timer::after(PACE).await;
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
                                            Ok((n, derive_us, sign_us)) => {
                                                resp[0] = CTAP2_OK;
                                                log!(
                                                    "  assertion: authData 37 B (no attested data), response {} B",
                                                    n
                                                );
                                                Timer::after(PACE).await;
                                                log!(
                                                    "  derive {} us, sign {} us, UP bit {}",
                                                    derive_us,
                                                    sign_us,
                                                    present as u8
                                                );
                                                Timer::after(PACE).await;
                                                log!("  the same key as at registration, and it was never kept.");
                                                Timer::after(PACE).await;
                                                send(&mut writer, cid, CTAPHID_CBOR, &resp[..1 + n])
                                                    .await;
                                            }
                                            Err(()) => {
                                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                                log!("  building the assertion failed inside this firmware.");
                                                Timer::after(PACE).await;
                                                send(&mut writer, cid, CTAPHID_CBOR, &[0x7f]).await;
                                            }
                                        }
                                    }
                                }
                            }
                            other => {
                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                log!("  CTAP2 command {:#04x} is unknown here", other);
                                Timer::after(PACE).await;
                                send(&mut writer, cid, CTAPHID_CBOR, &[CTAP1_ERR_INVALID_COMMAND])
                                    .await;
                            }
                        }
                    }
                    other => {
                        t.clear();
                        ERRORS.fetch_add(1, Ordering::Relaxed);
                        log!("  {} is not implemented here: ERR_INVALID_CMD", cmd_name(other));
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
    config.serial_number = Some("173");
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
            // 5 ms. A security key is polled while somebody is waiting with a
            // finger on a button, and exp121's keyboard used the same number
            // for the same reason.
            poll_ms: 5,
            max_packet_size: PACKET as u16,
            // No boot protocol. exp121 claimed one because a keyboard has a
            // fixed eight-byte layout a BIOS understands; nothing understands
            // CTAPHID before it has read this descriptor.
            hid_subclass: embassy_usb::class::hid::HidSubclass::No,
            hid_boot_protocol: embassy_usb::class::hid::HidBootProtocol::None,
        },
    );

    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());
    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(cdc_task(control, receiver).unwrap());
    let trng = Trng::new(p.TRNG, Irqs, embassy_rp::trng::Config::default());
    spawner.spawn(ctaphid_task(hid, TRANSACTION.init(Transaction::none()), trng).unwrap());

    Timer::after(Duration::from_secs(3)).await;

    log!("exp173 a client that is not ours");
    Timer::after(PACE).await;
    log!("  NOT a security key: no cryptography, no credential, no secret.");
    Timer::after(PACE).await;
    log!(
        "  FIDO report descriptor: {} bytes, hand-written, usage page 0xF1D0",
        FIDO_REPORT_DESCRIPTOR.len()
    );
    Timer::after(PACE).await;
    log!("  {}", Hex(&FIDO_REPORT_DESCRIPTOR[..17]));
    Timer::after(PACE).await;
    log!("  {}", Hex(&FIDO_REPORT_DESCRIPTOR[17..]));
    Timer::after(PACE).await;
    log!(
        "  init packet carries {} payload bytes, cont carries {}",
        INIT_PAYLOAD,
        CONT_PAYLOAD
    );
    Timer::after(PACE).await;
    log!("  commands: INIT, PING, CBOR. Everything else -> ERR_INVALID_CMD.");
    Timer::after(PACE).await;
    log!("  CTAP2: getInfo, makeCredential, getAssertion. ES256, self-attested.");
    Timer::after(PACE).await;
    log!("  user presence: {} (UP bit is never set without asking)", UP_MODE);
    Timer::after(PACE).await;
    log!("  device secret is a compiled-in TEST key, {} bytes at {:#010x}", DEVICE_SECRET.len(), DEVICE_SECRET.as_ptr() as u32);
    Timer::after(PACE).await;
    {
        let mut probe = [0u8; 256];
        match get_info(&mut probe) {
            Ok(b) => {
                log!("  versions: none claimed ({} entries)", VERSIONS.len());
                Timer::after(PACE).await;
                log!("  getInfo body is {} bytes: {}", b.len(), Hex(b));
            }
            Err(_) => log!("  getInfo does not encode; this build is broken"),
        }
    }
    Timer::after(PACE).await;
    log!("  max message {} bytes; longer -> ERR_INVALID_LEN.", MAX_MESSAGE);
    Timer::after(PACE).await;
    log!("  a transaction expires after {} ms.", TRANSACTION_TIMEOUT.as_millis());
    Timer::after(PACE).await;
    log!("listening on the FIDO interface.");

    loop {
        Timer::after(Duration::from_secs(20)).await;
        log!(
            "idle: {} packets in, {} messages, {} errors",
            PACKETS_IN.load(Ordering::Relaxed),
            MESSAGES.load(Ordering::Relaxed),
            ERRORS.load(Ordering::Relaxed)
        );
    }
}
