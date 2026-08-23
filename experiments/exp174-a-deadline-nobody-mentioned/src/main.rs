// SPDX-License-Identifier: Apache-2.0
//! # exp174 — a deadline nobody mentioned
//!
//! The seventh experiment on the
//! [authenticator road](../README.md#the-authenticator-road), and the first
//! whose client is a **browser**. Everything from
//! [exp168](../exp168-a-security-key-that-knows-nothing/) to
//! [exp173](../exp173-a-client-that-is-not-ours/) was driven by a command-line
//! tool that waits as long as it is told. Chrome does not.
//!
//! ## What it set out to measure, and what it found instead
//!
//! The plan was to see what a browser demands that `libfido2` does not. The
//! answer is **nothing**: exp173's firmware registered and logged in against
//! Chrome on the first attempt, on a page served from `http://localhost` and
//! on `webauthn.io`, with no firmware change at all.
//!
//! What the browser did do is **give up**, sometimes, on a device that was
//! working correctly. Chasing that produced two findings, and only the second
//! is about the protocol.
//!
//! ## One: this firmware was slow, and every check said it was fine
//!
//! Between the button press and the finished credential there were **eleven to
//! twenty-one seconds**, in every run since
//! [exp171](../exp171-a-credential-nobody-asked-for/). Deriving the key takes
//! 44 ms and signing takes 54 ms. The rest was one statement nobody had ever
//! timed: thirty-two bytes out of the TRNG.
//!
//! [exp109](../exp109-hardware-trng/) had already measured this and written it
//! down. `embassy-rp` defaults `sample_count` to **25**, which samples the ring
//! oscillator faster than it decorrelates; the health tests reject the work and
//! it is done again. exp109 saw 64 bits take 0.38 s, then 31.4 s, then 14.5 s
//! on that default, against 5–6 ms at 1000 — and wrote that *something which
//! always works but sometimes takes half a minute is harder to find than
//! something that breaks*.
//!
//! exp171, exp172, exp173 and this experiment's own first builds all used
//! `Config::default()`. **Every credential they made was correct and every
//! signature verified**, so no check here could see it. Measured on this board
//! before the fix: 15.4 s, 21.4 s, 6.9 s. After: 10.5 ms.
//!
//! **What found it was a browser giving up.**
//!
//! ## Two: silence has a price, and `CTAPHID_KEEPALIVE` is what pays it
//!
//! A device that is waiting for a finger sends nothing, and a host cannot tell
//! that apart from a device that has died. `CTAPHID_KEEPALIVE` is one status
//! byte whose only job is to say *still here*.
//!
//! With the TRNG fixed the two arms differ by that packet and nothing else,
//! and the board's own clock decides when the answer leaves:
//!
//! ```text
//!   silent,    answered at 25013 ms,   0 keepalives  ->  NotAllowedError
//!   keepalive, answered at 25005 ms, 249 keepalives  ->  the credential is accepted
//! ```
//!
//! Below the ceiling it makes no difference: nine seconds of pure silence was
//! accepted by the same browser. **It is not what makes this work; it is what
//! makes it keep working when a person is slow.**
//!
//! ## Three: the client says when it leaves, and exp173 was not listening
//!
//! A browser that has stopped waiting sends `CTAPHID_CANCEL`. exp173 answered
//! `ERR_INVALID_CMD` and went on deriving a key and signing for a caller who
//! had gone. This build reads while it waits, and a withdrawn request ends in
//! `CTAP2_ERR_KEEPALIVE_CANCEL` with no signature made.
//!
//! ## What the instrument had to learn
//!
//! Two attempts at the measurement asked a person to count to nine and a half,
//! and then to hold a button for half a minute. Both put the precision of the
//! measurement inside a human reflex, and neither is an instrument. The third
//! shape works: **the press is latched at any moment in the window, and the
//! answer leaves on the board's clock** — so the person only has to press, and
//! the log prints both numbers so the delay is never mistaken for the press.
//!
//! `EXP174_HOLD_MS` is that floor, `EXP174_TIMEOUT_MS` is the window, and
//! `EXP174_KEEPALIVE` is the arm. At `HOLD_MS=0, KEEPALIVE=off` this is exp173.

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
use embassy_rp::trng::{Config as TrngConfig, Trng};
use sha2::{Digest, Sha256};
use usb_log::log;

// UP_MODE and WAIT_FOR_USER, from build.rs and EXP173_UP.
include!(concat!(env!("OUT_DIR"), "/exp174_config.rs"));

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

/// `CTAPHID_CANCEL`. A client that has stopped waiting sends this, and
/// [exp173](../exp173-a-client-that-is-not-ours/) did not know it: a browser
/// that had already given up sent `bcnt 0` on the live channel and got
/// `ERR_INVALID_CMD` back, while the board went on building a credential
/// nobody was there to receive. **The reply is not the point — stopping is.**
const CTAPHID_CANCEL: u8 = 0x11;

/// `CTAPHID_KEEPALIVE`. Not a request and not an answer: one byte of status,
/// sent by the device, whose only job is to say the transaction is still alive.
/// A host that hears it restarts its own clock.
///
/// **`0x3B`, not `0xBB`.** Every command here is stored without the packet's
/// initialisation bit and [`send`] adds it. This one was first written as
/// `0xBB` — the byte as it appears on the wire — and produced exactly the
/// right packets anyway, because `0x80 | 0xBB` and `0x80 | 0x3B` are the same
/// byte. What it broke was reading: `cmd_name` masks the bit off before
/// matching, so a keepalive arriving *here* would have printed as `?`. A
/// constant can be wrong in a way that only shows up in the direction nobody
/// tested.
const CTAPHID_KEEPALIVE: u8 = 0x3B;

/// The two status bytes a keepalive can carry. Only the second is ever sent
/// here, because the only thing this device is ever slow for is a person.
/// Named and unused on purpose: it is the status for a device that is busy
/// with its own work, and this one never is. Every slow moment here belongs to
/// a person, so every keepalive it sends carries the other byte.
#[allow(dead_code)]
const STATUS_PROCESSING: u8 = 0x01;
const STATUS_UPNEEDED: u8 = 0x02;

/// How often to say it. The specification says at least every 100 ms, which is
/// far more often than a person's finger needs and is the point: the interval
/// is set by the host's patience, not by the device's work.
const KEEPALIVE_INTERVAL: Duration = Duration::from_millis(100);

/// How often the button is read while waiting. exp173's figure, kept, because
/// changing the button's granularity in the same experiment that changes the
/// transport would make the two indistinguishable.
const PRESENCE_POLL: Duration = Duration::from_millis(20);

const _: () = assert!(
    HOLD_MS < USER_PRESENCE_TIMEOUT.as_millis(),
    "EXP174_HOLD_MS must be under the presence timeout, or no press can ever land"
);

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

/// `CTAP2_ERR_KEEPALIVE_CANCEL`. The answer to a request the client withdrew.
/// It is a refusal like any other on the wire, and unlike every other refusal
/// here **the device is not the one that decided**.
const CTAP2_ERR_KEEPALIVE_CANCEL: u8 = 0x2D;

/// COSE's identifier for ECDSA with SHA-256, which is the algorithm every FIDO2
/// client offers first and the only one this road will implement.
const COSE_ES256: i64 = -7;

/// How long the `button` build waits for a finger. A person who is not there
/// has to become an answer rather than a hang, and the host is holding a
/// transaction open the whole time — which is the thing this experiment
/// measures rather than fixes.
const USER_PRESENCE_TIMEOUT: Duration = Duration::from_millis(TIMEOUT_MS);

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

/// exp109's number, not the driver's default. See the comment where the TRNG
/// is built: at the default this device is correct and sometimes twenty
/// seconds slow, which is the shape of fault that outlives every check.
const TRNG_SAMPLE_COUNT: u32 = 1000;

const PRODUCT: &str = "exp174 a deadline nobody mentioned";
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
        CTAPHID_CANCEL => "CANCEL",
        CTAPHID_KEEPALIVE => "KEEPALIVE",
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

/// What ended a wait for a person.
enum Presence {
    /// Somebody pressed BOOTSEL.
    Pressed,
    /// Nobody did, for [`USER_PRESENCE_TIMEOUT`].
    TimedOut,
    /// The client withdrew the request while the device was still waiting.
    /// **This is the only outcome here the device did not decide**, and the
    /// reason it exists at all: a client that has stopped listening and cannot
    /// say so leaves a board doing work for nobody.
    Cancelled,
}

/// How the wait went, in the numbers the log prints.
struct Waited {
    outcome: Presence,
    /// When the answer left.
    ms: u64,
    /// When a finger actually touched the button, if one did. Separate from
    /// `ms` because [`HOLD_MS`] can put a gap between them, and a record that
    /// blurred the two would be a record of the instrument, not the subject.
    pressed_at: Option<u64>,
    keepalives: u32,
}

/// Wait for a finger, and stay audible while doing it.
///
/// exp173 waited in a loop that read nothing and sent nothing. That is what a
/// specification-shaped reading of "wait for user presence" produces, and
/// against a browser it fails twice over:
///
/// - **The host has a deadline nobody announced.** Measured against exp173,
///   presses at 1.1, 2.3, 3.6 and 4.5 seconds were accepted and a press at 9.9
///   seconds was not — the board built the credential, and the client had
///   already gone. `CTAPHID_KEEPALIVE` is the packet that restarts that clock,
///   and [`KEEPALIVE`] is whether this build sends it.
/// - **The client says when it leaves, and exp173 did not listen.** A browser
///   that had given up sent `CTAPHID_CANCEL` on the live channel; the reply was
///   `ERR_INVALID_CMD` and the board kept signing. So this wait reads as well as
///   writes.
///
/// It deliberately does **not** feed the reassembler: a packet arriving here is
/// either the cancel this wait is listening for, or another channel wanting a
/// turn, and neither is a continuation of the message already being answered.
async fn wait_for_presence(
    reader: &mut embassy_usb::class::hid::HidReader<'static, usb_reboot::UsbDriver, PACKET>,
    writer: &mut embassy_usb::class::hid::HidWriter<'static, usb_reboot::UsbDriver, PACKET>,
    cid: Cid,
) -> Waited {
    let start = Instant::now();
    let mut pkt = [0u8; PACKET];
    let mut keepalives = 0u32;
    let mut pressed_at: Option<u64> = None;
    let mut next = start + KEEPALIVE_INTERVAL;

    loop {
        // **The press is latched, and the answer is a clock's.**
        //
        // The first two attempts at this measurement asked a person to count
        // to nine and a half, and then to hold a button for half a minute.
        // Both put the instrument's precision inside a human reflex, and both
        // were the wrong shape: what is being measured is *how long a host
        // will wait*, which is a number the board should own end to end.
        //
        // So a press at any moment in the window counts, and the answer leaves
        // at `HOLD_MS`. A person did physically press the button during the
        // request — the UP bit stays true — and the log prints both numbers so
        // the delay is never mistaken for the press. With `HOLD_MS` at zero
        // this is exp173's condition exactly.
        if bootsel::is_pressed() && pressed_at.is_none() {
            pressed_at = Some(start.elapsed().as_millis());
        }
        if pressed_at.is_some() && start.elapsed().as_millis() >= HOLD_MS {
            return Waited {
                outcome: Presence::Pressed,
                ms: start.elapsed().as_millis(),
                pressed_at,
                keepalives,
            };
        }
        if start.elapsed() >= USER_PRESENCE_TIMEOUT {
            return Waited {
                outcome: Presence::TimedOut,
                ms: start.elapsed().as_millis(),
                pressed_at,
                keepalives,
            };
        }

        // The button's granularity and the transport's are different clocks,
        // and this is the only place they meet. The read is raced against the
        // shorter of the two so neither one waits on the other.
        if let Either::First(Ok(n)) = select(reader.read(&mut pkt), Timer::after(PRESENCE_POLL)).await {
            if n >= 5 && pkt[4] & 0x80 != 0 {
                let from: Cid = [pkt[0], pkt[1], pkt[2], pkt[3]];
                let cmd = pkt[4] & 0x7f;
                if from == cid && cmd == CTAPHID_CANCEL {
                    return Waited {
                        outcome: Presence::Cancelled,
                        ms: start.elapsed().as_millis(),
                        pressed_at,
                        keepalives,
                    };
                }
                if from != cid && from != RESERVED {
                    // Another channel while this one holds the device. Silence
                    // would leave it waiting for a reply this transaction is
                    // not going to leave room for.
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
    }
}


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
                                            log!(
                                                "  waiting for BOOTSEL. {}",
                                                if KEEPALIVE {
                                                    "KEEPALIVE every 100 ms while this runs."
                                                } else {
                                                    "Nothing is sent while this runs."
                                                }
                                            );
                                            Timer::after(PACE).await;
                                            let w =
                                                wait_for_presence(&mut reader, &mut writer, cid).await;
                                            // Three sentences rather than one
                                            // with a hole in it: only a press
                                            // has a moment of its own, and
                                            // printing `at 0 ms` for a wait
                                            // nobody answered read as though
                                            // somebody had pressed instantly.
                                            match w.outcome {
                                                Presence::Pressed => log!(
                                                    "  pressed at {} ms, answered at {} ms, {} keepalives sent",
                                                    w.pressed_at.unwrap_or(0),
                                                    w.ms,
                                                    w.keepalives
                                                ),
                                                Presence::TimedOut => log!(
                                                    "  nobody pressed anything; the window closed at {} ms, {} keepalives sent",
                                                    w.ms,
                                                    w.keepalives
                                                ),
                                                Presence::Cancelled => log!(
                                                    "  the client cancelled at {} ms, {} keepalives sent",
                                                    w.ms,
                                                    w.keepalives
                                                ),
                                            }
                                            Timer::after(PACE).await;
                                            // A withdrawn request is not a
                                            // refused one. It gets its own
                                            // status, and no signature is made
                                            // for a caller that is not there.
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

                                        // **Timed, because nothing ever timed
                                        // it.** From exp171 onward every run
                                        // showed eleven to sixteen seconds
                                        // between the press and the finished
                                        // credential, and derive plus sign
                                        // account for a tenth of a second of
                                        // it. This is the only other statement
                                        // in between.
                                        let mut nonce = [0u8; 32];
                                        let t_rng = Instant::now();
                                        trng.blocking_fill_bytes(&mut nonce);
                                        let rng_us = t_rng.elapsed().as_micros();
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
                                                log!("  32 bytes of TRNG took {} us", rng_us);
                                                Timer::after(PACE).await;
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
                                            log!(
                                                "  waiting for BOOTSEL. {}",
                                                if KEEPALIVE {
                                                    "KEEPALIVE every 100 ms while this runs."
                                                } else {
                                                    "Nothing is sent while this runs."
                                                }
                                            );
                                            Timer::after(PACE).await;
                                            let w =
                                                wait_for_presence(&mut reader, &mut writer, cid).await;
                                            // Three sentences rather than one
                                            // with a hole in it: only a press
                                            // has a moment of its own, and
                                            // printing `at 0 ms` for a wait
                                            // nobody answered read as though
                                            // somebody had pressed instantly.
                                            match w.outcome {
                                                Presence::Pressed => log!(
                                                    "  pressed at {} ms, answered at {} ms, {} keepalives sent",
                                                    w.pressed_at.unwrap_or(0),
                                                    w.ms,
                                                    w.keepalives
                                                ),
                                                Presence::TimedOut => log!(
                                                    "  nobody pressed anything; the window closed at {} ms, {} keepalives sent",
                                                    w.ms,
                                                    w.keepalives
                                                ),
                                                Presence::Cancelled => log!(
                                                    "  the client cancelled at {} ms, {} keepalives sent",
                                                    w.ms,
                                                    w.keepalives
                                                ),
                                            }
                                            Timer::after(PACE).await;
                                            // A withdrawn request is not a
                                            // refused one. It gets its own
                                            // status, and no signature is made
                                            // for a caller that is not there.
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
    // Its own number. This said "173" until exp177 needed to tell two boards
    // apart and found it could not: the string was carried over with the source
    // when exp174 was derived from exp173, and nothing was looking. The USB
    // serial is how `yi26 port` and `lib.sh`'s `exp_running` answer "which
    // experiment is on this board", so a duplicate makes two firmwares
    // indistinguishable to every script here. docs-check.sh now asserts it.
    config.serial_number = Some("174");
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
    // **exp109's number, and this experiment is why it has to be said again.**
    // `embassy-rp` defaults `sample_count` to 25, which samples the ring
    // oscillator faster than it decorrelates: the health tests reject the work
    // and it is done again. exp109 measured 64 bits at 0.38 s, then 31.4 s,
    // then 14.5 s on that default, against 5–6 ms at 1000, and wrote down that
    // something which always works but sometimes takes half a minute is harder
    // to find than something that breaks.
    //
    // exp171, exp172, exp173 and the first builds of this one all used the
    // default, and none of their checks could see it: every credential was
    // correct and every signature verified. **What found it was a browser
    // giving up** — and the 32-byte nonce here measured 15.4 s, 21.4 s and
    // 6.9 s before this line existed.
    let mut trng_config = TrngConfig::default();
    trng_config.sample_count = TRNG_SAMPLE_COUNT;
    let trng = Trng::new(p.TRNG, Irqs, trng_config);
    spawner.spawn(ctaphid_task(hid, TRANSACTION.init(Transaction::none()), trng).unwrap());

    Timer::after(Duration::from_secs(3)).await;

    log!("exp174 a deadline nobody mentioned");
    Timer::after(PACE).await;
    log!("  a security key with one test secret, and it says so on every line.");
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
    log!(
        "  while waiting for a person: {}, and CANCEL is heard",
        if KEEPALIVE { "KEEPALIVE every 100 ms" } else { "silence (exp173's behaviour)" }
    );
    Timer::after(PACE).await;
    log!(
        "  a held button is not answered before {} ms, and the window is {} ms",
        HOLD_MS,
        TIMEOUT_MS
    );
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
