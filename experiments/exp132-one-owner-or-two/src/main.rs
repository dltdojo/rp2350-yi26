//! exp132 — one owner or two.
//!
//! exp129's prize draw, built twice from one source. The host sends a range —
//! `2100-2567`, the employee numbers on the raffle tickets — and the firmware
//! returns one number from it. What moves here is *where the host sends it*:
//! the default build reads commands on the CDC OUT endpoint, and
//! `--features two-channels` adds a vendor interface and reads them there,
//! leaving CDC carrying nothing but the log.
//!
//! That is the whole experiment. An interface has exactly one owner, so on one
//! channel the program watching the log and the program driving the draw have
//! to be the same program; on two they need not be, and two tabs on a phone
//! both keep what they claimed. The draw itself is unchanged from exp129, and
//! the sections below are its account of it.
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
use embassy_rp::usb::{Driver, Endpoint, In, InterruptHandler, Out};
use embassy_time::{Duration, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
#[cfg(feature = "two-channels")]
use embassy_usb::driver::{Endpoint as _, EndpointIn, EndpointOut};
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

/// The second build's interface class. 0xFF means "no promises", which is why
/// no operating system driver claims it — exp122 works through what that buys.
#[cfg(feature = "two-channels")]
const CLASS_VENDOR: u8 = 0xFF;
#[cfg(feature = "two-channels")]
const SUBCLASS_NONE: u8 = 0x00;
#[cfg(feature = "two-channels")]
const PROTOCOL_NONE: u8 = 0x00;

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

/// Pushes bits through the health tests until a window has closed.
///
/// Shared by both builds, because a gate that has not yet had the chance to
/// fail is not a gate whichever interface the command arrived on.
async fn warm_up(trng: &mut Trng<'static, TRNG>, health: &mut Health) {
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
}

/// A line built on the stack, for the channel that has to answer as well as log.
#[cfg(feature = "two-channels")]
struct Reply {
    buf: [u8; PACKET],
    len: usize,
}

#[cfg(feature = "two-channels")]
impl Reply {
    fn new() -> Self {
        Self { buf: [0; PACKET], len: 0 }
    }
    fn as_bytes(&self) -> &[u8] {
        &self.buf[..self.len]
    }
}

#[cfg(feature = "two-channels")]
impl core::fmt::Write for Reply {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        let b = s.as_bytes();
        let room = PACKET - self.len;
        let n = if b.len() < room { b.len() } else { room };
        self.buf[self.len..self.len + n].copy_from_slice(&b[..n]);
        self.len += n;
        Ok(())
    }
}

/// One command, one answer — and the answer goes to the log either way.
///
/// The only difference between the builds is which endpoint the bytes came
/// from; what a range means is written once so the two cannot drift apart.
#[cfg(feature = "two-channels")]
async fn handle(
    msg: &[u8],
    trng: &mut Trng<'static, TRNG>,
    health: &mut Health,
    reply: &mut Reply,
) {
    use core::fmt::Write as _;
    let Some((lo, hi)) = parse_range(msg) else {
        REFUSED.fetch_add(1, Ordering::Relaxed);
        log!("not a range: \"{}\"", Printable(&msg[..msg.len().min(32)]));
        let _ = write!(reply, "not a range\n");
        return;
    };
    if hi < lo {
        REFUSED.fetch_add(1, Ordering::Relaxed);
        log!("{}-{} is empty — lo must not be above hi", lo, hi);
        let _ = write!(reply, "{}-{} is empty\n", lo, hi);
        return;
    }
    match draw_one(trng, health, lo, hi).await {
        None => {
            REFUSED.fetch_add(1, Ordering::Relaxed);
            log!("refused: the health tests have failed — no number");
            let _ = write!(reply, "refused: health tests failed\n");
        }
        Some(Err(e)) => {
            REFUSED.fetch_add(1, Ordering::Relaxed);
            log!("refused: the draw could not complete ({:?})", e);
            let _ = write!(reply, "refused: draw incomplete\n");
        }
        Some(Ok(value)) => {
            let seq = DRAWS.fetch_add(1, Ordering::Relaxed) + 1;
            let span = hi - lo + 1;
            log!("draw #{}: {}  in {}-{} ({} values)", seq, value, lo, hi, span);
            let _ = write!(reply, "draw #{}: {}  in {}-{} ({} values)\n", seq, value, lo, hi, span);
        }
    }
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

/// The default build: one interface, one owner.
///
/// Commands and log share the CDC pair, which means whoever holds it can see
/// both — and nobody else can see either. A page that wants to show the log
/// beside the number it drew has to be the same page that drew it.
#[cfg(not(feature = "two-channels"))]
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
    warm_up(&mut trng, &mut health).await;

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

/// The second build: the CDC pair carries the log and nothing else.
///
/// It still has to watch for the 1200-baud touch, because that is how the
/// board gets reflashed. What it no longer does is read commands.
#[cfg(feature = "two-channels")]
#[embassy_executor::task]
async fn console_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut buf = [0u8; PACKET];
    loop {
        match select(control.control_changed(), receiver.read_packet(&mut buf)).await {
            Either::First(()) => {
                usb_reboot::reboot_if_requested(receiver.line_coding().data_rate()).await;
            }
            // Bytes still arrive here if somebody writes to the serial port,
            // and they are no longer commands. Saying so is better than
            // silence: a reader who sends a range to the wrong channel needs
            // to be told which one, not ignored.
            Either::Second(Ok(n)) if n > 0 => {
                log!("{} bytes on the log channel — commands go to the vendor", n);
                log!("  interface in this build: try  yi26 echo 2100-2567");
            }
            Either::Second(_) => {}
        }
    }
}

/// The second build's command channel: a vendor interface nobody claims.
///
/// The whole difference between the two builds is here. The log is on CDC and
/// this is not, so a program holding one does not exclude a program holding
/// the other — which is exp122's finding with a job attached to it.
#[cfg(feature = "two-channels")]
#[embassy_executor::task]
async fn vendor_task(
    mut read_ep: Endpoint<'static, USB, Out>,
    mut write_ep: Endpoint<'static, USB, In>,
    mut trng: Trng<'static, TRNG>,
) -> ! {
    let mut health = Health::new();
    warm_up(&mut trng, &mut health).await;

    let mut buf = [0u8; PACKET];
    loop {
        read_ep.wait_enabled().await;
        loop {
            let n = match read_ep.read(&mut buf).await {
                Ok(n) => n,
                Err(_) => break,
            };
            if n == 0 {
                continue;
            }
            let mut reply = Reply::new();
            handle(&buf[..n], &mut trng, &mut health, &mut reply).await;
            // The same sentence goes out on both channels: back to whoever
            // sent the command, and into the log for whoever is watching it.
            // That they can be different people is the point of this build.
            let _ = write_ep.write(reply.as_bytes()).await;
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
            #[cfg(not(feature = "two-channels"))]
            log!("idle: no draws yet — try  yi26 send '2100-2567'");
            #[cfg(feature = "two-channels")]
            log!("idle: no draws yet — try  yi26 echo 2100-2567");
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
    #[cfg(not(feature = "two-channels"))]
    let product = "exp132 one owner";
    #[cfg(feature = "two-channels")]
    let product = "exp132 two owners";
    config.product = Some(product);
    config.serial_number = Some("132");
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

    let mut trng_config = TrngConfig::default();
    trng_config.sample_count = TRNG_SAMPLE_COUNT;
    let trng = Trng::new(p.TRNG, Irqs, trng_config);

    // The one structural difference between the builds, and it is here rather
    // than hidden behind a helper so that a reader can see both shapes at once.
    #[cfg(feature = "two-channels")]
    let (vendor_out, vendor_in) = {
        let mut function = builder.function(CLASS_VENDOR, SUBCLASS_NONE, PROTOCOL_NONE);
        let mut interface = function.interface();
        let mut alt = interface.alt_setting(CLASS_VENDOR, SUBCLASS_NONE, PROTOCOL_NONE, None);
        let out = alt.endpoint_bulk_out(None, PACKET as u16);
        let in_ = alt.endpoint_bulk_in(None, PACKET as u16);
        (out, in_)
    };

    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    #[cfg(not(feature = "two-channels"))]
    spawner.spawn(console_task(control, receiver, trng).unwrap());
    #[cfg(feature = "two-channels")]
    {
        spawner.spawn(console_task(control, receiver).unwrap());
        spawner.spawn(vendor_task(vendor_out, vendor_in, trng).unwrap());
    }
    spawner.spawn(idle_task().unwrap());

    #[cfg(not(feature = "two-channels"))]
    log!("exp132 up, one channel. Send a range, like  2100-2567");
    #[cfg(feature = "two-channels")]
    log!("exp132 up, two channels. Commands on the vendor interface.");

    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
