// SPDX-License-Identifier: Apache-2.0
//! # exp166 — whose firmware will it accept
//!
//! The [signing road](../README.md#the-signing-road) opens with the sentence
//! that names it:
//!
//! > The update road answered **can an update brick this board**. It said at
//! > the outset that ***whose firmware will it accept*** was a separate group,
//! > and this is it.
//!
//! Eight experiments later, **no board in this repository has ever checked a
//! signature.** [exp159](../exp159-a-key-that-was-never-in-flash/) and
//! [exp160](../exp160-a-secret-too-big-to-hide/) both *produce* signatures and
//! send them to a host to be verified, which is the right control for an
//! experiment about signing. It leaves the road's own question untouched.
//!
//! This is that question, and it turns out not to need any of the machinery the
//! six experiments before it went looking for.
//!
//! ## Signing needs a secret. Verifying needs only integrity.
//!
//! | | signing (exp159–exp165 went here) | verifying (this) |
//! |---|---|---|
//! | needs | a **private** key hidden from the board's own code | a **public** key everyone may read |
//! | the attack | read the key out | **swap** the key |
//! | exp162's four-byte granularity | applies | does not apply |
//! | exp163's 63% rebuild cost | applies | does not apply |
//! | needs TrustZone | to hide, yes | **no** |
//!
//! So everything [exp162](../exp162-how-wide-can-a-wall-be/) and
//! [exp163](../exp163-how-long-is-a-secret-in-the-open/) found is background
//! here rather than an obstacle, and this experiment sits back at the update
//! road's difficulty rather than the Armv8-M step's.
//!
//! ## The ceiling, stated first
//!
//! **The public key this firmware trusts is a 64-byte constant in ordinary
//! flash, and anybody who can write flash can replace it.** exp159 measured
//! that `XIP_MAIN` defaults to fully open access; candidate 5 reads that
//! register again here and prints it, and `check.sh` finds the key inside the
//! `.uf2` by byte search and prints the offset it found it at.
//!
//! So **this signature check can be flashed over**, and closing that needs a
//! fuse this road does not burn. That is not a footnote — it is
//! [exp140](../exp140-a-checksum-that-passes/)'s lesson one layer up:
//!
//! > A CRC check on an update conflates reliability with authenticity, and the
//! > conflation is invisible until somebody hands you a file built to pass it.
//!
//! Here the conflation is between *checking a signature* and *being unable to
//! not check it*. The first is built below. The second is not.
//!
//! ## The bar this has to clear, and it is exp159's
//!
//! exp159's finding was that the board signed a challenge **it could not have
//! known at build time**. The mirror is the bar for a verifier: it must accept
//! a signature it could not have known at build time, over bytes chosen after
//! it was built.
//!
//! So the host picks a **random offset and length** into the board's own flash
//! each run, signs the bytes that live there, and sends the 64-byte signature
//! over CDC. The firmware carries the public key and nothing else: no digest,
//! no signature, no region.
//!
//! ## Framing, and the one thing this needs that `framing` says it lacks
//!
//! Messages arrive over CDC in 64-byte packets and a signature is 64 bytes on
//! its own, so a message never fits in one and the boundary has to come from
//! the bytes. The road already decided that:
//! [exp136](../exp136-joining-halfway/) measured that length-prefix
//! resynchronises by luck and **invents three frames** where COBS invents none,
//! and *"an invented frame carrying a signature is a signature-shaped thing
//! that fails to verify, and a reader will blame the cryptography for what the
//! framing did."*
//!
//! [`framing`](../../crates/framing/) implements it, and says of itself:
//!
//! > It has no checksum, no version byte, and no opinion about what a payload
//! > means — and a frame layer without a checksum cannot tell a corrupted
//! > payload from a real one.
//!
//! **Here it does not need one.** A corrupted payload is a signature that does
//! not verify, and that is the outcome this firmware exists to produce. It is
//! the only place on either road where that missing checksum costs nothing.
//!
//! ## What this does not do
//!
//! It does not install anything. `ACCEPT` is a verdict printed, not a slot
//! marked bootable — acting on the verdict is the ROM's `explicit_buy`
//! machinery that [exp143](../exp143-the-image-that-is-never-bought/) measured,
//! and joining the two is the next experiment rather than this one. **Nothing
//! here writes flash**, and `check.sh` fails if it can.

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
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use framing::{cobs, Deframer as _, Start as _};
use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};
use panic_halt as _;
use rp2350_linker as _;
use sha2::{Digest, Sha256};
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

/// **The whole of this board's trust, and it is 65 bytes of `.rodata`.**
///
/// SEC1 uncompressed P-256 public key. The matching private key is a test key,
/// printed in this experiment's README, and is never on the board — the point
/// of a verifier is that it does not need one.
///
/// `check.sh` searches the built `.uf2` for these bytes and prints the offset
/// it finds them at, because "anybody who can write flash can change which
/// firmware this board accepts" is a claim that should be demonstrated rather
/// than asserted. See [exp140](../exp140-a-checksum-that-passes/).
const TRUSTED_KEY: [u8; 65] = [
    0x04, 0x61, 0x78, 0x88, 0x17, 0xa1, 0x41, 0x90, 0x3f, 0xb9, 0xac, 0x46, 0xab, 0x03, 0xfb, 0xde,
    0x47, 0x18, 0x12, 0x62, 0xad, 0x41, 0x0b, 0x69, 0x09, 0x88, 0xa0, 0xb9, 0xd1, 0x67, 0xce, 0xcd,
    0xee, 0xed, 0x2d, 0x1f, 0x96, 0xde, 0xfb, 0x9c, 0x84, 0x43, 0xfe, 0x1d, 0x56, 0x9e, 0xf5, 0x59,
    0xa6, 0xc4, 0xba, 0xcb, 0x8c, 0x35, 0x9a, 0x10, 0x57, 0x9b, 0x12, 0x0a, 0x63, 0xf0, 0x9a, 0xad,
    0xb0,
];

const XIP_BASE: u32 = 0x1000_0000;
/// A region has to end inside memory that is certainly backed by flash on any
/// RP2350 board. The firmware itself is well under 128 KB, so half a megabyte
/// is generous and still nowhere near the XIP window's 16 MB of aliases.
const MAX_END: u32 = 0x0008_0000;

/// `[cmd:1][offset:4 LE][len:4 LE][signature:64]`
const FRAME_LEN: usize = 73;
const CMD_VERIFY: u8 = 1;

const PACKET: usize = 64;
const PRODUCT: &str = "exp166 whose firmware will it accept";
const CONTROL_BUF_LEN: usize = 128;
const _: () = assert!(
    2 * PRODUCT.len() + 2 < CONTROL_BUF_LEN,
    "product string will overflow embassy-usb's control buffer and panic mid-enumeration"
);

static ASKED: AtomicU32 = AtomicU32::new(0);
static ACCEPTED: AtomicU32 = AtomicU32::new(0);
static REFUSED: AtomicU32 = AtomicU32::new(0);
static MALFORMED: AtomicU32 = AtomicU32::new(0);
static BUSY: AtomicBool = AtomicBool::new(false);

struct Hex<'a>(&'a [u8]);

impl core::fmt::Display for Hex<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        for b in self.0 {
            write!(f, "{:02x}", b)?;
        }
        Ok(())
    }
}

/// Why a frame was not accepted. Every one of these is a distinct printed
/// reason, because "REFUSED" on its own tells a reader nothing about whether
/// the cryptography or the plumbing said no — and on this road that confusion
/// has a name: exp136's invented frame carrying a signature.
#[derive(Copy, Clone)]
enum Refusal {
    ShortFrame(usize),
    UnknownCommand(u8),
    RegionOutOfRange,
    EmptyRegion,
    MalformedSignature,
    BadKey,
    SignatureDoesNotVerify,
}

/// The reason carries the number that caused it wherever there is one. "The
/// frame is not 73 bytes" sends a reader back to the sender; "the frame is 41
/// bytes, not 73" tells them which end truncated it.
impl core::fmt::Display for Refusal {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Refusal::ShortFrame(n) => write!(f, "the frame is {} bytes, not {}", n, FRAME_LEN),
            Refusal::UnknownCommand(c) => write!(f, "unknown command byte {:#04x}", c),
            Refusal::RegionOutOfRange => {
                write!(f, "the region leaves the window this board will read")
            }
            Refusal::EmptyRegion => write!(f, "the region is empty"),
            Refusal::MalformedSignature => {
                write!(f, "the 64 signature bytes are not a P-256 signature")
            }
            Refusal::BadKey => write!(f, "the compiled-in public key does not parse"),
            Refusal::SignatureDoesNotVerify => {
                write!(f, "the signature is not this key's, over these bytes")
            }
        }
    }
}

impl Refusal {
    /// Plumbing or cryptography. A reader who cannot tell them apart will
    /// blame the wrong layer, which is the failure exp136 is about.
    fn layer(self) -> &'static str {
        match self {
            Refusal::SignatureDoesNotVerify | Refusal::MalformedSignature | Refusal::BadKey => {
                "cryptography"
            }
            _ => "plumbing",
        }
    }
}

/// The region named by a frame, as a slice of execute-in-place flash.
///
/// # Safety of the read
///
/// The bounds are checked before the slice exists: `end` must be inside
/// [`MAX_END`] and the length must not be zero. Nothing is written, nothing is
/// executed, and a region that fails the check produces a refusal rather than a
/// clamp — a silently narrowed region would be a signature checked over bytes
/// nobody named.
fn region(offset: u32, len: u32) -> Result<&'static [u8], Refusal> {
    if len == 0 {
        return Err(Refusal::EmptyRegion);
    }
    let end = offset.checked_add(len).ok_or(Refusal::RegionOutOfRange)?;
    if end > MAX_END {
        return Err(Refusal::RegionOutOfRange);
    }
    Ok(unsafe { core::slice::from_raw_parts((XIP_BASE + offset) as *const u8, len as usize) })
}

/// The verdict, and the two numbers a reader needs to believe it.
struct Verdict {
    digest: [u8; 32],
    hash_us: u64,
    verify_us: u64,
    outcome: Result<(), Refusal>,
}

fn check(frame: &[u8]) -> Result<Verdict, Refusal> {
    if frame.len() != FRAME_LEN {
        return Err(Refusal::ShortFrame(frame.len()));
    }
    if frame[0] != CMD_VERIFY {
        return Err(Refusal::UnknownCommand(frame[0]));
    }
    let offset = u32::from_le_bytes([frame[1], frame[2], frame[3], frame[4]]);
    let len = u32::from_le_bytes([frame[5], frame[6], frame[7], frame[8]]);
    let bytes = region(offset, len)?;

    // The digest is computed and printed even when the signature will be
    // refused, because it is what lets a host prove the board hashed the same
    // bytes it did. A verifier that only reports pass/fail cannot be checked;
    // it can only be trusted.
    let t0 = Instant::now();
    let mut h = Sha256::new();
    h.update(bytes);
    let digest: [u8; 32] = h.finalize().into();
    let hash_us = t0.elapsed().as_micros();

    let t1 = Instant::now();
    let outcome = (|| {
        let vk = VerifyingKey::from_sec1_bytes(&TRUSTED_KEY).map_err(|_| Refusal::BadKey)?;
        let sig = Signature::from_slice(&frame[9..]).map_err(|_| Refusal::MalformedSignature)?;
        vk.verify(bytes, &sig).map_err(|_| Refusal::SignatureDoesNotVerify)
    })();
    let verify_us = t1.elapsed().as_micros();

    Ok(Verdict { digest, hash_us, verify_us, outcome })
}

static STOPPED: AtomicBool = AtomicBool::new(false);

#[embassy_executor::task]
async fn heartbeat(mut led: Output<'static>) -> ! {
    loop {
        let (on, off) = if BUSY.load(Ordering::Relaxed) {
            (60, 60)
        } else if STOPPED.load(Ordering::Relaxed) {
            (100, 100)
        } else {
            (50, 950)
        };
        led.set_high();
        Timer::after(Duration::from_millis(on)).await;
        led.set_low();
        Timer::after(Duration::from_millis(off)).await;
    }
}

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

/// The task this experiment turns on: it owns the `Receiver`, so it does both
/// jobs the `Receiver` makes possible — [exp118](../exp118-one-receiver-two-jobs/)'s
/// shape, unchanged. Losing the 1200-baud reflash touch to a verifier that
/// hogged the endpoint would cost a hand on BOOTSEL for every round.
#[embassy_executor::task]
async fn verify_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut buf = [0u8; PACKET];
    // **`joined`, not `fresh`, and the difference is the finding of
    // [exp136](../exp136-joining-halfway/).** This board can never know it is
    // reading a host's stream from its first byte: the port may have been
    // opened and closed, a previous run may have left half a frame in flight,
    // and the firmware outlives every one of those. A `joined` COBS decoder
    // refuses to emit whatever it assembled before the first delimiter, so a
    // fragment cannot become a 73-byte frame by accident. Senders therefore
    // lead with a delimiter, which costs one byte.
    let mut frames = cobs::Deframer::joined();

    loop {
        match select(control.control_changed(), receiver.read_packet(&mut buf)).await {
            Either::First(()) => {
                let rate = receiver.line_coding().data_rate();
                usb_reboot::reboot_if_requested(rate).await;
            }

            // exp118 measured one of these at about 37 ms, before the host had
            // asserted DTR. It is the endpoint completing empty as it is
            // enabled, not somebody sending nothing.
            Either::Second(Ok(0)) => {}

            Either::Second(Ok(n)) => {
                for &byte in &buf[..n] {
                    let Some(len) = frames.feed(byte) else { continue };

                    // **A zero-length frame is not a message**, and counting
                    // one costs more than it looks. Senders lead with a
                    // delimiter because this decoder is `joined`; once it is
                    // synchronised, that same delimiter closes an empty frame
                    // behind the previous one. Every request would then arrive
                    // as two, the numbering would drift, and "11 asked" would
                    // describe five.
                    //
                    // exp118 wrote this rule down one layer lower, about a
                    // zero-length USB packet it measured at 37 ms. The same
                    // sentence is true of the frame layer and had to be
                    // learned again here, from a log that counted to eleven
                    // for five requests.
                    if len == 0 {
                        continue;
                    }

                    let frame = &frames.payload()[..len];
                    BUSY.store(true, Ordering::Relaxed);
                    let asked = ASKED.fetch_add(1, Ordering::Relaxed) + 1;

                    let offset_len = if len >= 9 {
                        Some((
                            u32::from_le_bytes([frame[1], frame[2], frame[3], frame[4]]),
                            u32::from_le_bytes([frame[5], frame[6], frame[7], frame[8]]),
                        ))
                    } else {
                        None
                    };

                    log!("--- request #{}: {} byte frame, {} discarded", asked, len, frames.discarded());
                    Timer::after(Duration::from_millis(40)).await;
                    if let Some((off, l)) = offset_len {
                        log!("  region: offset={:#x} len={} ({:#x}..{:#x})", off, l, XIP_BASE + off, XIP_BASE + off + l);
                        Timer::after(Duration::from_millis(40)).await;
                    }

                    match check(frame) {
                        Err(r) => {
                            MALFORMED.fetch_add(1, Ordering::Relaxed);
                            log!("  REFUSED ({}): {}", r.layer(), r);
                        }
                        Ok(v) => {
                            log!("  sha256 = {}", Hex(&v.digest));
                            Timer::after(Duration::from_millis(40)).await;
                            log!("  hashed in {} us, verified in {} us", v.hash_us, v.verify_us);
                            Timer::after(Duration::from_millis(40)).await;
                            match v.outcome {
                                Ok(()) => {
                                    ACCEPTED.fetch_add(1, Ordering::Relaxed);
                                    log!("  ACCEPTED: signed by the key this board trusts");
                                }
                                Err(r) => {
                                    REFUSED.fetch_add(1, Ordering::Relaxed);
                                    log!("  REFUSED ({}): {}", r.layer(), r);
                                }
                            }
                        }
                    }
                    Timer::after(Duration::from_millis(40)).await;
                    log!(
                        "  totals: {} asked, {} accepted, {} refused, {} malformed",
                        ASKED.load(Ordering::Relaxed),
                        ACCEPTED.load(Ordering::Relaxed),
                        REFUSED.load(Ordering::Relaxed),
                        MALFORMED.load(Ordering::Relaxed)
                    );
                    Timer::after(Duration::from_millis(40)).await;
                    BUSY.store(false, Ordering::Relaxed);
                }
            }

            Either::Second(Err(_)) => {
                receiver.wait_connection().await;
            }
        }
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());

    spawner.spawn(heartbeat(Output::new(p.PIN_25, Level::Low)).unwrap());

    let driver = Driver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(PRODUCT);
    config.serial_number = Some("166");
    config.device_class = 0xef;
    config.device_sub_class = 0x02;
    config.device_protocol = 0x01;
    config.composite_with_iads = true;

    static CONFIG_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; CONTROL_BUF_LEN]> = StaticCell::new();
    static ACM_STATE: StaticCell<State> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESCRIPTOR.init([0; 256]),
        BOS_DESCRIPTOR.init([0; 256]),
        &mut [],
        CONTROL_BUF.init([0; CONTROL_BUF_LEN]),
    );
    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), 64);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());
    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(verify_task(control, receiver).unwrap());
    spawner.spawn(log_task(sender).unwrap());

    Timer::after(Duration::from_secs(3)).await;

    log!("exp166 whose firmware will it accept");
    Timer::after(Duration::from_millis(40)).await;
    log!("  send COBS frames: [cmd=1][offset:4 LE][len:4 LE][sig:64] = 73 bytes");
    Timer::after(Duration::from_millis(40)).await;

    // **Candidate 5, and it runs before anything is asked of the board.** The
    // trusted key's address is printed because it is the answer to "what would
    // somebody have to change" — and the register that could stop them is read
    // rather than described. exp159 measured XIP_MAIN as fully open; this
    // reads it again, because a value quoted from another experiment's README
    // is not a measurement of the board in front of you.
    let key_addr = TRUSTED_KEY.as_ptr() as u32;
    log!("  trusted key lives at {:#010x}, {} bytes", key_addr, TRUSTED_KEY.len());
    Timer::after(Duration::from_millis(40)).await;
    log!("  key = {}", Hex(&TRUSTED_KEY[..32]));
    Timer::after(Duration::from_millis(40)).await;
    log!("        {}", Hex(&TRUSTED_KEY[32..]));
    Timer::after(Duration::from_millis(40)).await;

    let xip = embassy_rp::pac::ACCESSCTRL.xip_main().read().0;
    log!("  ACCESSCTRL.XIP_MAIN = {:#010x}", xip);
    Timer::after(Duration::from_millis(40)).await;
    log!(
        "  the key is in flash that register leaves {} - anybody who can",
        if xip & 0xff == 0xff { "open to every master" } else { "partly gated" }
    );
    Timer::after(Duration::from_millis(40)).await;
    log!("  write flash can choose whose firmware this board accepts.");
    Timer::after(Duration::from_millis(40)).await;
    log!("  This check can be flashed over. Closing that needs a fuse.");
    Timer::after(Duration::from_millis(40)).await;
    log!("listening.");

    loop {
        Timer::after(Duration::from_secs(20)).await;
        log!(
            "listening: {} asked, {} accepted, {} refused, {} malformed",
            ASKED.load(Ordering::Relaxed),
            ACCEPTED.load(Ordering::Relaxed),
            REFUSED.load(Ordering::Relaxed),
            MALFORMED.load(Ordering::Relaxed)
        );
    }
}
