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
use usb_log::log;

// CLAIM and VERSIONS, from build.rs and EXP169_CLAIM.
include!(concat!(env!("OUT_DIR"), "/exp169_config.rs"));

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
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

const PRODUCT: &str = "exp169 what it says it can do";
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
    w.map(3);
    w.key(0x01);
    w.array(VERSIONS.len() as u32);
    for v in VERSIONS {
        w.text(v);
    }
    w.end();
    w.key(0x03);
    w.bytes(&AAGUID);
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
                            // **The overclaim, caught immediately.** With
                            // `EXP169_CLAIM=fido2` this device tells a host it
                            // speaks FIDO_2_0, and these two are what FIDO_2_0
                            // is actually for. Refusing them by name is the
                            // only apology the protocol has room for.
                            AUTHENTICATOR_MAKE_CREDENTIAL | AUTHENTICATOR_GET_ASSERTION => {
                                ERRORS.fetch_add(1, Ordering::Relaxed);
                                log!("  CTAP2 {:#04x} is not implemented: this is not a security key", ctap);
                                Timer::after(PACE).await;
                                send(&mut writer, cid, CTAPHID_CBOR, &[CTAP1_ERR_INVALID_COMMAND])
                                    .await;
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
    config.serial_number = Some("169");
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
    spawner.spawn(ctaphid_task(hid, TRANSACTION.init(Transaction::none())).unwrap());

    Timer::after(Duration::from_secs(3)).await;

    log!("exp169 what it says it can do");
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
    log!("  CTAP2: getInfo only. makeCredential and getAssertion are refused.");
    Timer::after(PACE).await;
    {
        let mut probe = [0u8; 256];
        match get_info(&mut probe) {
            Ok(b) => {
                log!("  versions claim = {:?} ({} entries)", CLAIM, VERSIONS.len());
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
