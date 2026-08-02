//! exp113 — a seed you can count to.
//!
//! exp112 ended with a fix that looks reasonable: the software generator was
//! deterministic because its seed was a constant, so seed it from something
//! device-specific instead. Every board then produces its own sequence, the
//! reboot tell disappears, and every statistical test still passes.
//!
//! This experiment asks what that fix is actually worth, and answers by
//! **cracking it on the same chip that produced it**.
//!
//! The seed here is built the way weak seeds usually are: a value that is not
//! secret, mixed with a value that is not very variable. The firmware prints
//! the public half and eight bytes of output, then searches the space of the
//! other half until it finds the one that reproduces those bytes — reporting
//! how many candidates it tried and how long it took.
//!
//! Nothing here is a key and nothing here should be used as one. That is the
//! point: the number is small enough to enumerate, so it was never a secret.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::otp;
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Duration, Instant, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

/// How much of the unknown half the search covers: 2^24, about 16.7 million.
///
/// Chosen so the board finishes in seconds rather than minutes, and so the
/// README can do the arithmetic outwards from a measured number instead of a
/// guessed one.
const SEARCH_BITS: u32 = 24;
const SEARCH_SPACE: u32 = 1 << SEARCH_BITS;

/// How often the search hands the CPU back.
///
/// exp110 measured what happens without this: a task that does not yield is
/// not interrupted, and the executor cannot run the heartbeat, the logger, or
/// the 1200-baud watcher while it runs. A brute-force loop is exactly the
/// shape of code that forgets.
///
/// The number matters as much as the yielding does. This was 2^16 during
/// development, which is about 17 ms of work between yields — enough to lose
/// USB enumeration and leave a board that could only be recovered by holding
/// BOOTSEL. "Yields sometimes" and "stays responsive" are different claims.
const YIELD_EVERY: u32 = 1 << 10;

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn reboot_task(
    control: ControlChanged<'static>,
    receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    usb_reboot::watch(control, receiver).await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

/// The same xorshift32 exp112 used, so the two experiments are comparable.
fn stream_from(seed: u32, out: &mut [u8]) {
    let mut x = if seed == 0 { 1 } else { seed };
    for chunk in out.chunks_mut(4) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        let v = x.to_ne_bytes();
        chunk.copy_from_slice(&v[..chunk.len()]);
    }
}

/// Reads 32 bits of whatever the chip's OTP has to identify itself.
///
/// Printed rather than trusted. Which OTP rows carry a usable identity, and
/// whether they are programmed at all on a given part, is a question for the
/// datasheet and the board in front of you — so this logs what it read and
/// the README records what came back here.
fn chip_identity() -> u32 {
    let mut acc: u32 = 0;
    for row in 0..4usize {
        let w = otp::read_ecc_word(row).unwrap_or(0);
        acc = acc.rotate_left(8) ^ (w as u32);
    }
    acc
}

#[embassy_executor::task]
async fn crack_task() -> ! {
    // The timer is read **now**, at boot, because that is when a real
    // firmware would seed itself — a device wants its key material before it
    // does anything, not several seconds in. Reading it after the delay below
    // would make the seed look far better than it is: the number an attacker
    // has to guess would be dominated by a pause this experiment invented.
    let hidden = Instant::now().as_micros() as u32;

    // Only now, with the seed already taken, let the USB stack finish
    // enumerating before doing anything CPU-bound.
    //
    // Not defensive padding — a lesson paid for. Enumeration is a burst of
    // control transfers in the first moments after boot, and it is the one
    // window where the executor being busy is unrecoverable: a firmware that
    // never enumerates cannot be reflashed over USB, only through BOOTSEL.
    // Heavy work at boot is the worst place to put heavy work.
    //
    // It also guarantees a responsive window on every single boot, which is
    // what makes a firmware that misbehaves later still recoverable.
    Timer::after(Duration::from_secs(3)).await;

    // -- the "seed" ---------------------------------------------------------
    //
    // Two ingredients, and the weakness is in both.
    //
    // `public` is device-specific and not secret: anyone holding the board can
    // read it. It makes each board's sequence different, which is what made
    // the exp112 fix look like a fix.
    //
    // `hidden` was the timer at boot. It is the only part an attacker does not
    // simply know — and a board boots in about the same time every time, so
    // "does not know" is not the same as "cannot guess".
    let public = chip_identity();
    let seed = public ^ hidden;

    let mut published = [0u8; 8];
    stream_from(seed, &mut published);

    log!("otp identity (public, printed on purpose): {:08x}", public);
    log!(
        "output from the seed: {:02x} {:02x} {:02x} {:02x} {:02x} {:02x} {:02x} {:02x}",
        published[0], published[1], published[2], published[3],
        published[4], published[5], published[6], published[7]
    );
    log!("Those bytes pass every test in exp111. Now watch them stop being a secret.");

    // -- the search ---------------------------------------------------------
    //
    // An attacker in this position knows `public` and the eight bytes, and
    // wants `hidden`. So: try every candidate.
    let t0 = Instant::now();
    let mut tried: u32 = 0;
    let mut found: Option<u32> = None;

    for candidate in 0..SEARCH_SPACE {
        let mut probe = [0u8; 8];
        stream_from(public ^ candidate, &mut probe);
        tried += 1;
        if probe == published {
            found = Some(candidate);
            break;
        }
        if tried % YIELD_EVERY == 0 {
            // Hand the CPU back. See exp110 — and note that yielding is what
            // keeps this honest, because the heartbeat below is the proof
            // that the board stayed alive throughout.
            Timer::after(Duration::from_ticks(1)).await;
        }
    }

    let elapsed_ms = (Instant::now() - t0).as_millis();

    match found {
        Some(c) => {
            log!(
                "CRACKED: hidden value was {} us. {} candidates in {} ms.",
                c, tried, elapsed_ms
            );
            log!(
                "The board that made this seed found it again in {} ms. It was never a secret.",
                elapsed_ms
            );

            // The number above is the *lucky* one, and saying so matters.
            //
            // A linear search from zero finds a boot timer almost at once,
            // because a board boots in about the same time every time. That
            // is not the size of the space — it is the size of the part an
            // attacker bothers with. So the worst case is worth a number too.
            //
            // It is measured as a **rate**, not by sweeping the whole space.
            // Sweeping 2^24 here bricked this board's USB during development:
            // the loop yielded, but only every 65536 candidates, and 17 ms
            // between yields is long enough to lose USB enumeration — which
            // happens in the first moments after boot, exactly when this task
            // starts. The firmware kept running and could no longer be
            // reflashed without a physical BOOTSEL press.
            //
            // Timing a small batch and multiplying is also simply what you
            // would do in practice. It costs a thousandth of the work and
            // answers the same question, and the answer is labelled as
            // extrapolated because it is.
            const BATCH: u32 = 1 << 14;
            let t1 = Instant::now();
            for candidate in 0..BATCH {
                let mut probe = [0u8; 8];
                stream_from(public ^ candidate, &mut probe);
                core::hint::black_box(&probe);
            }
            let batch_us = (Instant::now() - t1).as_micros().max(1);

            // Integer arithmetic only: no float formatter in `usb-log`, and
            // these numbers are large enough that the order of operations
            // matters. Candidates per millisecond, then milliseconds for the
            // whole space.
            // `batch_us` is microseconds, so scaling by 1000 gives candidates
            // per millisecond. `full_ms` then divides the space by that rate
            // directly — scaling a second time here produced 19,262,016 ms
            // instead of 19,262 during development, an answer off by a factor
            // of a thousand that still looked like a plausible number of
            // milliseconds. Units are worth writing down when the only reader
            // is a log line.
            let per_ms = (BATCH as u64 * 1000) / batch_us;
            let full_ms = SEARCH_SPACE as u64 / per_ms.max(1);
            log!(
                "rate: {} candidates in {} us -> about {} per ms",
                BATCH, batch_us, per_ms
            );
            log!(
                "so a full 2^{} sweep would take about {} ms (extrapolated, not swept)",
                SEARCH_BITS, full_ms
            );
            log!("Effective difficulty was {} of those. Entropy is not space.", tried);
        }
        None => {
            log!(
                "not found in 2^{} candidates ({} tried, {} ms) — the boot timer was larger",
                SEARCH_BITS, tried, elapsed_ms
            );
            log!("Widen SEARCH_BITS and try again; the arithmetic in the README still holds.");
        }
    }

    // The result is one fact, produced once, three seconds after boot — and a
    // fact printed once is a fact most readers never see. Anyone who attaches
    // a terminal after that point would find nothing but heartbeats and have
    // no way to tell a working experiment from a stuck one.
    //
    // So it repeats, compactly, forever. Slowly enough not to bury itself.
    let summary = found;
    loop {
        Timer::after(Duration::from_secs(10)).await;
        match summary {
            Some(c) => log!(
                "result: seed = otp {:08x} ^ boot {} us, recovered in {} ms after {} tries",
                public, c, elapsed_ms, tried
            ),
            None => log!(
                "result: not recovered within 2^{} candidates ({} ms)",
                SEARCH_BITS, elapsed_ms
            ),
        }
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let mut led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp113 enumerable seed");
    config.serial_number = Some("113");
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

    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), 64);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(reboot_task(control, receiver).unwrap());
    spawner.spawn(log_task(sender).unwrap());

    log!("exp113 up. Building a seed the lazy way, then breaking it.");
    spawner.spawn(crack_task().unwrap());

    // The heartbeat is the evidence that the search yielded. If it stops for
    // the duration of the crack, the search is hogging the executor and
    // exp110 explains what that costs.
    let mut beat: u32 = 0;
    loop {
        beat += 1;
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        log!("heartbeat #{}", beat);
        Timer::after(Duration::from_millis(950)).await;
    }
}
