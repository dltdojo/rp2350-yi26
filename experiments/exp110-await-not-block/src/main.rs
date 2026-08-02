//! exp110 — awaiting is not the same as waiting.
//!
//! exp109 was careful about one line without dwelling on it: it called
//! `fill_bytes(..).await` and not `blocking_fill_bytes(..)`. Both wait exactly
//! as long, because the hardware takes as long as it takes. This experiment is
//! about what else happens during that wait, and it measures the difference
//! instead of asserting it.
//!
//! Same source, two builds:
//!
//! ```sh
//! cargo build --release                      # awaits
//! cargo build --release --features blocking  # blocks
//! ```
//!
//! To make the wait long enough to see, the request is deliberately large —
//! `REQUEST_BYTES` at a time instead of exp109's eight. Nothing else changes.
//!
//! The evidence is a third task that does nothing but wake up on a schedule
//! and report how late it was. It is exp107's scheduler probe, pointed at a
//! specific suspect. With `await` its lateness stays in the microseconds; with
//! `blocking` it jumps to most of a second, because there is nothing the
//! executor can do about a task that has stopped yielding.

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

/// The value exp109 measured. Not the subject here — it is held fixed so that
/// the only variable is `await` versus `blocking`.
const TRNG_SAMPLE_COUNT: u32 = 1000;

/// Bytes per request.
///
/// exp109 asked for 8 and the hardware took about 5 ms. The TRNG produces 192
/// bits — 24 bytes — per internal block, so the cost scales with how many
/// blocks a request needs. This asks for enough to make the wait most of a
/// second, because a 5 ms stall is real but invisible next to a heartbeat that
/// ticks once a second.
///
/// Deliberately not larger. A request long enough to starve the executor
/// completely would also starve the 1200-baud watcher, and a firmware that
/// cannot be replaced over USB is a firmware that needs a human holding
/// BOOTSEL. That failure is worth *understanding*, which the README does, and
/// not worth shipping to a reader who may be a long way from their board.
const REQUEST_BYTES: usize = 4096;

/// How often the probe wakes up to check whether the world moved without it.
const PROBE_TICK: Duration = Duration::from_millis(100);

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

/// The suspect: a task that asks slow hardware for a lot of data.
///
/// The two bodies below differ in one call. Everything around them — the
/// buffer, the timing, the log line — is identical, so that the measurement
/// downstream cannot be blamed on anything else.
#[embassy_executor::task]
async fn entropy_task(mut trng: Trng<'static, TRNG>) -> ! {
    let mut buf = [0u8; REQUEST_BYTES];

    loop {
        let t0 = Instant::now();

        #[cfg(not(feature = "blocking"))]
        trng.fill_bytes(&mut buf).await;

        #[cfg(feature = "blocking")]
        trng.blocking_fill_bytes(&mut buf);

        let ms = (Instant::now() - t0).as_millis();
        log!(
            "entropy: {} bytes in {} ms (first byte {:02x})",
            REQUEST_BYTES,
            ms,
            buf[0]
        );

        Timer::after(Duration::from_secs(1)).await;
    }
}

/// The evidence.
///
/// This task wants to wake up every 100 ms. It cannot make that happen — only
/// the executor can — so the gap between when it asked to wake and when it
/// actually did is a direct measurement of whether anything else is hogging
/// the CPU.
///
/// Absolute deadlines, not `after_millis`, for the reason exp107 gives:
/// sleeping "100 ms from now" folds each wakeup's lateness into the next
/// deadline, which would measure this loop's own drift instead of the
/// executor's.
#[embassy_executor::task]
async fn lateness_probe() -> ! {
    const REPORT_EVERY: u32 = 20;

    let mut next = Instant::now();
    let mut ticks: u32 = 0;
    let mut worst_us: u64 = 0;

    loop {
        next += PROBE_TICK;
        Timer::at(next).await;

        let late_us = (Instant::now() - next).as_micros();
        if late_us > worst_us {
            worst_us = late_us;
        }

        ticks += 1;
        if ticks % REPORT_EVERY == 0 {
            log!(
                "probe: {} wakeups, worst lateness {} us ({} ms)",
                ticks,
                worst_us,
                worst_us / 1000
            );
            // Reset each report so the number describes the last two seconds
            // rather than the whole run. A single early spike that never
            // recurred would otherwise sit at the top of the log forever and
            // make a healthy firmware look sick.
            worst_us = 0;
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
    config.product = Some("exp110 await not block");
    config.serial_number = Some("110");
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

    #[cfg(not(feature = "blocking"))]
    log!("exp110 up, built to AWAIT. Watch the probe's worst lateness.");
    #[cfg(feature = "blocking")]
    log!("exp110 up, built to BLOCK. Watch the probe's worst lateness.");

    let mut trng_config = TrngConfig::default();
    trng_config.sample_count = TRNG_SAMPLE_COUNT;
    let trng = Trng::new(p.TRNG, Irqs, trng_config);
    spawner.spawn(entropy_task(trng).unwrap());
    spawner.spawn(lateness_probe().unwrap());

    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
