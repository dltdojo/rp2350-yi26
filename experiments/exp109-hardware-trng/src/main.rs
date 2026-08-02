//! exp109 — the hardware random number generator.
//!
//! exp108 read a sensor: hardware that measures something real and hands you a
//! number. This one reads hardware that manufactures a number no measurement
//! could predict — the RP2350's TRNG, which samples a free-running ring
//! oscillator and turns the jitter into bits.
//!
//! Calling it is one line. Getting it to work is the experiment.
//!
//! A real entropy source does not simply hand over what it collected. It runs
//! **health tests** on the samples first, and throws away anything that looks
//! too regular to be noise. The RP2350's TRNG has three, all on by default,
//! and every rejection means starting the block over. So the time to produce
//! a fixed number of bits is *variable, and has no upper bound worth relying
//! on* — which is the honest difference between this and a PRNG, and it is
//! visible in every line this firmware prints.
//!
//! Whether that variability is a mild annoyance or a firmware that hangs
//! depends entirely on one configuration constant. Read `TRNG_SAMPLE_COUNT`.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::{TRNG, USB};
use embassy_rp::trng::{Config as TrngConfig, InterruptHandler as TrngInterruptHandler, Trng};
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
    TRNG_IRQ => TrngInterruptHandler<TRNG>;
});

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

/// Clock cycles the TRNG waits between two consecutive ring-oscillator
/// samples. **This constant is the experiment.**
///
/// `embassy-rp`'s default is 25, and on this board that is too fast. Samples
/// taken that close together are still correlated with each other, the health
/// tests notice, and the block is discarded and restarted — over and over.
///
/// Measured on a real Pico 2, asking for 64 bits:
///
/// | `sample_count` | time to produce 64 bits                       |
/// |----------------|-----------------------------------------------|
/// | 25 (default)   | 0.38 s, then 31.4 s, then 14.5 s — three consecutive fills |
/// | 1000 (here)    | 5.0 ms to 6.3 ms, every time                  |
///
/// Build with `--features upstream-default` to watch the first row happen.
/// It is worth being precise about what that row is: not a hang, and not a
/// crash. The firmware is fine, the heartbeat never misses, and every request
/// is eventually answered — a thousand times later than the one below it.
/// Something that always works and sometimes takes half a minute is harder to
/// diagnose than something that breaks.
///
/// Sampling more slowly does **not** make the entropy better, and it is worth
/// not confusing the two claims. It makes consecutive samples independent
/// enough that the health tests stop rejecting them. The bits were always
/// going to be as good as the ring oscillator; what changes is how much work
/// is wasted getting them out.
#[cfg(not(feature = "upstream-default"))]
const TRNG_SAMPLE_COUNT: u32 = 1000;
#[cfg(feature = "upstream-default")]
const TRNG_SAMPLE_COUNT: u32 = 25;

/// Bytes per round. Small on purpose — the point is the cost of asking, and a
/// large request would hide it behind an average.
const BYTES_PER_ROUND: usize = 8;

/// Asks for eight random bytes a second, and reports what the asking cost.
///
/// The timing is not decoration. It is the only way to see the health tests
/// working, because a rejected sample produces no output at all — just a
/// longer wait before the next one.
#[embassy_executor::task]
async fn entropy_task(mut trng: Trng<'static, TRNG>) -> ! {
    let mut worst_us: u64 = 0;
    let mut best_us: u64 = u64::MAX;
    let mut round: u32 = 0;

    loop {
        round += 1;

        let mut bytes = [0u8; BYTES_PER_ROUND];

        // `fill_bytes`, not `blocking_fill_bytes`. The wait is the same
        // either way; what differs is whether the rest of the firmware waits
        // with it. exp110 is that difference, on its own, with the evidence.
        let t0 = Instant::now();
        trng.fill_bytes(&mut bytes).await;
        let us = (Instant::now() - t0).as_micros();

        if us > worst_us {
            worst_us = us;
        }
        if us < best_us {
            best_us = us;
        }

        log!(
            "trng: {:02x} {:02x} {:02x} {:02x} {:02x} {:02x} {:02x} {:02x}",
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7]
        );
        log!(
            "cost: {} us this time, {} best, {} worst over {} rounds",
            us,
            best_us,
            worst_us,
            round
        );

        Timer::after(Duration::from_secs(1)).await;
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let mut led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp109 hardware trng");
    config.serial_number = Some("109");
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

    log!("exp109 up. sample_count = {}.", TRNG_SAMPLE_COUNT);

    let mut trng_config = TrngConfig::default();
    trng_config.sample_count = TRNG_SAMPLE_COUNT;
    let trng = Trng::new(p.TRNG, Irqs, trng_config);
    spawner.spawn(entropy_task(trng).unwrap());

    // The heartbeat matters more here than it looks. When the TRNG goes quiet
    // for thirty seconds — which it does, at the upstream default — this is
    // what tells you the firmware is alive and one task is waiting, rather
    // than the whole thing having died. Those two look identical without it,
    // and they need completely different debugging.
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
