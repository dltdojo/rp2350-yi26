//! exp129 — numbered draws.
//!
//! A prize draw, on the board. The host sends a range — `2100-2567`, the
//! employee numbers on the raffle tickets — and the firmware returns one
//! number from it. This is the first experiment here with a use rather than a
//! demonstration, and the first where somebody in the room has a reason to
//! doubt the answer.
//!
//! # The subject is not randomness
//!
//! Nobody watching a draw can tell the difference between a number from this
//! chip's TRNG, a number from `Math.random()`, and a number a rigged firmware
//! chose in advance. exp112 settled the hardest of those: a build that quietly
//! stopped using the hardware RNG produced output that passed every
//! statistical test in this repository. Randomness is not what an audience can
//! check.
//!
//! So the question this firmware is built around is a different one: **what
//! can be checked?** Three things, and each is one mechanism:
//!
//! - **The mapping cannot be biased.** `crates/draw` rejects rather than
//!   folding, which makes every result equally likely by construction. Its
//!   tests count preimages over the whole 2³² space — a thing no draw on real
//!   hardware could ever establish.
//! - **A failing source cannot emit.** exp114's rule, applied: every bit that
//!   could reach a result goes through the SP 800-90B continuous tests first,
//!   and a failure stops the draw rather than annotating it.
//! - **A discarded draw is visible.** Every draw carries a sequence number. An
//!   operator who draws five times and announces the fifth cannot hide the
//!   first four, because the number beside the result says `#5`.
//!
//! That last one is the only defence here against the failure mode a real
//! prize draw actually has, and it is worth being precise about what it is: it
//! is not cryptography, it is **a counter somebody can read**. It does not
//! prevent a redraw. It makes one impossible to conceal from anybody looking
//! at the same screen or the same log.
//!
//! # Where the entropy is checked, and why in that order
//!
//! The TRNG is asynchronous and `draw::in_range` is not, so a draw fetches a
//! fixed block of random bytes first, pushes **every bit of it** through the
//! health tests, and only then runs the draw over those same bytes.
//!
//! The order is the point. Checking after fetching but before emitting means
//! the bytes behind a number are the bytes that were tested — not a sample
//! taken nearby, and not a check performed on entropy that was already spent.
//! If the tests fail, the number has still been computed; it is simply never
//! said out loud.
//!
//! # What this cannot do
//!
//! It cannot tell you the draw was fair. One board and a few thousand samples
//! cannot certify a source — exp111 drew that line and it has not moved. What
//! is claimed here is mechanism: unbiased by construction, gated by tests with
//! stated cutoffs, and accountable by counter. Whether the chip's TRNG is good
//! is a question for the chip's own documentation and for exp109 through
//! exp114, not for this experiment.

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::{TRNG, USB};
use embassy_rp::trng::{Config as TrngConfig, InterruptHandler as TrngInterruptHandler, Trng};
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Duration, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use entropy_health::Health;
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    TRNG_IRQ => TrngInterruptHandler<TRNG>;
});

/// One CDC packet, and exp128's rule: a message ends at the first packet
/// shorter than this.
const PACKET: usize = 64;

/// The longest command this firmware will assemble. A range is at most
/// twenty-one characters; the rest is room for somebody's mistake to arrive
/// intact so it can be quoted back to them.
const MESSAGE: usize = 128;

/// exp109's number, not the driver's default.
///
/// The `embassy-rp` default is wrong here by a factor of thousands, which is
/// the whole of exp109. Copying the value without copying the reason would be
/// exactly the kind of unexplained constant this repository tries not to
/// leave lying around.
const TRNG_SAMPLE_COUNT: u32 = 1000;

/// Bytes fetched per draw, and therefore bits pushed through the health tests
/// per draw.
///
/// Sixty-four is `draw::MAX_TRIES` four-byte values: enough that the draw can
/// never run out, bounded so that a draw's cost does not depend on luck.
const DRAW_BYTES: usize = 64;

/// Bits pushed before the first draw is allowed.
///
/// The adaptive proportion test has a 1024-sample window and says nothing
/// until one has closed. A draw made before then would be gated by a test that
/// had not yet had the chance to fail, which is not a gate. Two windows, so
/// the first is complete and the second is under way.
const WARMUP_BITS: u32 = 2 * entropy_health::APT_WINDOW;

const IDLE_REPORT: Duration = Duration::from_secs(5);

static DRAWS: AtomicU32 = AtomicU32::new(0);
static REFUSED: AtomicU32 = AtomicU32::new(0);
static HEALTH_FAILED: AtomicBool = AtomicBool::new(false);
static BITS_TESTED: AtomicU32 = AtomicU32::new(0);

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

/// Parses `lo-hi` out of whatever arrived.
///
/// Deliberately strict. A prize draw is a bad place for a parser that guesses:
/// `2100 - 2567` with spaces, or a trailing newline somebody's terminal added,
/// are refused and quoted back rather than interpreted. The cost of being
/// wrong here is a number nobody can account for.
fn parse_range(msg: &[u8]) -> Option<(u32, u32)> {
    let dash = msg.iter().position(|&b| b == b'-')?;
    let lo = parse_u32(&msg[..dash])?;
    let hi = parse_u32(&msg[dash + 1..])?;
    Some((lo, hi))
}

fn parse_u32(s: &[u8]) -> Option<u32> {
    if s.is_empty() || s.len() > 10 {
        return None;
    }
    let mut n: u32 = 0;
    for &b in s {
        let d = b.checked_sub(b'0')?;
        if d > 9 {
            return None;
        }
        n = n.checked_mul(10)?.checked_add(d as u32)?;
    }
    Some(n)
}

/// Renders bytes as text, one dot per byte that is not printable ASCII, so a
/// refused command can be quoted without the log doing the guessing the parser
/// refused to do.
struct Printable<'a>(&'a [u8]);

impl core::fmt::Display for Printable<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        for &b in self.0 {
            f.write_str(if (0x20..0x7f).contains(&b) {
                // One char at a time, without allocating.
                core::str::from_utf8(core::slice::from_ref(&b)).unwrap_or(".")
            } else {
                "."
            })?;
        }
        Ok(())
    }
}

/// Fetches entropy, tests it, and draws from it — in that order.
///
/// Returns `None` when the health tests have failed, which is permanent: a
/// source that failed is not consulted again. That is exp114's rule and the
/// reason this returns an Option rather than a number with a warning attached.
async fn draw_one(
    trng: &mut Trng<'static, TRNG>,
    health: &mut Health,
    lo: u32,
    hi: u32,
) -> Option<Result<u32, draw::Error>> {
    if HEALTH_FAILED.load(Ordering::Relaxed) {
        return None;
    }

    let mut bytes = [0u8; DRAW_BYTES];
    trng.fill_bytes(&mut bytes).await;

    for &byte in bytes.iter() {
        for i in 0..8 {
            if health.push((byte >> i) & 1 == 1).is_some() {
                HEALTH_FAILED.store(true, Ordering::Relaxed);
            }
        }
    }
    BITS_TESTED.store(health.total(), Ordering::Relaxed);

    // Checked after pushing and before using: the bytes behind the number are
    // the bytes that were tested.
    if HEALTH_FAILED.load(Ordering::Relaxed) {
        return None;
    }

    let mut i = 0usize;
    Some(draw::in_range(lo, hi, || {
        let w = u32::from_le_bytes([bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]]);
        i += 4;
        w
    }))
}

#[embassy_executor::task]
async fn console_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
    mut trng: Trng<'static, TRNG>,
) -> ! {
    let mut packet = [0u8; PACKET];
    let mut message = [0u8; MESSAGE];
    let mut held = 0usize;
    let mut health = Health::new();

    // Warm up before anything can be drawn. Until a window has closed the
    // adaptive test cannot fail, and a gate that cannot fail is not a gate.
    let mut warm = [0u8; 128];
    while health.total() < WARMUP_BITS {
        trng.fill_bytes(&mut warm).await;
        for &byte in warm.iter() {
            for i in 0..8 {
                if health.push((byte >> i) & 1 == 1).is_some() {
                    HEALTH_FAILED.store(true, Ordering::Relaxed);
                }
            }
        }
    }
    BITS_TESTED.store(health.total(), Ordering::Relaxed);
    if HEALTH_FAILED.load(Ordering::Relaxed) {
        log!("health tests failed during warmup — this board will not draw");
    } else {
        log!("warmed up: {} bits through the health tests", health.total());
    }

    loop {
        match select(control.control_changed(), receiver.read_packet(&mut packet)).await {
            Either::First(()) => {
                let rate = receiver.line_coding().data_rate();
                log!(
                    "control: {} baud, DTR {}",
                    rate,
                    if receiver.dtr() { "on" } else { "off" }
                );
                usb_reboot::reboot_if_requested(rate).await;
            }

            Either::Second(Ok(n)) => {
                if n == 0 && held == 0 {
                    continue;
                }

                // exp128's reassembly, unchanged: a message ends at the first
                // packet shorter than 64.
                let room = MESSAGE - held;
                let take = if n < room { n } else { room };
                message[held..held + take].copy_from_slice(&packet[..take]);
                held += take;

                if n >= PACKET && held < MESSAGE {
                    continue;
                }

                let msg = &message[..held];
                held = 0;

                let Some((lo, hi)) = parse_range(msg) else {
                    REFUSED.fetch_add(1, Ordering::Relaxed);
                    log!("not a range: \"{}\"", Printable(&msg[..msg.len().min(32)]));
                    log!("  send lo-hi, digits and one dash: 2100-2567");
                    continue;
                };

                if hi < lo {
                    REFUSED.fetch_add(1, Ordering::Relaxed);
                    log!("{}-{} is empty — lo must not be above hi", lo, hi);
                    continue;
                }

                match draw_one(&mut trng, &mut health, lo, hi).await {
                    None => {
                        REFUSED.fetch_add(1, Ordering::Relaxed);
                        log!("refused: the health tests have failed — no number");
                        log!("  a source that failed is not consulted again (exp114)");
                    }
                    Some(Err(e)) => {
                        REFUSED.fetch_add(1, Ordering::Relaxed);
                        log!("refused: the draw could not complete ({:?})", e);
                    }
                    Some(Ok(value)) => {
                        let seq = DRAWS.fetch_add(1, Ordering::Relaxed) + 1;
                        let span = hi - lo + 1;
                        log!("draw #{}: {}  in {}-{} ({} values)", seq, value, lo, hi, span);
                        log!(
                            "  {} of 2^32 rejected to keep it unbiased",
                            draw::rejected_values(lo, hi)
                        );
                    }
                }
            }

            Either::Second(Err(_)) => {
                receiver.wait_connection().await;
                held = 0;
                log!("interface enabled again — listening");
            }
        }
    }
}

/// Says what has happened so far, on a loop.
///
/// The draw count is here and not only beside each result, because the number
/// that matters to somebody arriving late is *how many draws there have been*,
/// not what the last one was.
#[embassy_executor::task]
async fn idle_task() -> ! {
    loop {
        Timer::after(IDLE_REPORT).await;

        if HEALTH_FAILED.load(Ordering::Relaxed) {
            log!("idle: health tests FAILED — this board will not draw");
            continue;
        }

        let draws = DRAWS.load(Ordering::Relaxed);
        if draws == 0 {
            log!("idle: no draws yet — try  yi26 send '2100-2567'");
        } else {
            log!(
                "idle: {} draw{}, {} refused, {} bits tested",
                draws,
                if draws == 1 { "" } else { "s" },
                REFUSED.load(Ordering::Relaxed),
                BITS_TESTED.load(Ordering::Relaxed)
            );
        }
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());

    // Board-specific: the LED's GPIO. A heartbeat, nothing more — exp127's
    // question of who owns it is a different experiment.
    let mut led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp129 numbered draws");
    config.serial_number = Some("129");
    config.device_class = 0xef;
    config.device_sub_class = 0x02;
    config.device_protocol = 0x01;
    config.composite_with_iads = true;

    static CONFIG_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; 64]> = StaticCell::new();
    static ACM_STATE: StaticCell<State> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESCRIPTOR.init([0; 256]),
        BOS_DESCRIPTOR.init([0; 256]),
        &mut [],
        CONTROL_BUF.init([0; 64]),
    );

    // Still exp115's descriptors. A board that draws prize numbers looks
    // exactly like a board that prints a log, which is worth noticing: nothing
    // about the USB layer knows or cares what the bytes mean.
    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), PACKET as u16);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let mut trng_config = TrngConfig::default();
    trng_config.sample_count = TRNG_SAMPLE_COUNT;
    let trng = Trng::new(p.TRNG, Irqs, trng_config);

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(console_task(control, receiver, trng).unwrap());
    spawner.spawn(idle_task().unwrap());

    log!("exp129 up. Send a range, like  2100-2567");

    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
