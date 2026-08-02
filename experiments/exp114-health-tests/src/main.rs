//! exp114 — health tests that refuse.
//!
//! exp111 counted ones, counted changes, printed two percentages, and said
//! plainly that this was monitoring rather than certification. It also
//! pointed at NIST SP 800-90B and noted that it is a document, not a function
//! call.
//!
//! This is the part of that document that *is* a function call: the two
//! continuous health tests in section 4.4, with cutoffs derived from a stated
//! false-positive rate rather than chosen by taste.
//!
//! One behaviour separates this experiment from every test so far. When a
//! source fails, **it stops being used**. Not flagged, not printed in red —
//! stopped. A test that reports and carries on is a report; a health test
//! gates the thing it watches. The difference is one `if`, and it is the
//! reason the module exists.
//!
//! Three sources are watched:
//!
//! - the **TRNG** from exp109, which should pass,
//! - the **ADC bottom bit** from exp111, which may or may not — exp111 found
//!   its behaviour wanders, and this reports whatever happens rather than
//!   promising a result,
//! - a **deliberately broken source**, because a health test you have never
//!   seen fire is a health test you do not know works.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_rp::adc::{
    Adc, Async, Channel, Config as AdcConfig, InterruptHandler as AdcInterruptHandler,
};
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::{TRNG, USB};
use embassy_rp::trng::{Config as TrngConfig, InterruptHandler as TrngInterruptHandler, Trng};
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Duration, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use entropy_health as health;
use entropy_health::{Failure, Health};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    ADC_IRQ_FIFO => AdcInterruptHandler;
    TRNG_IRQ => TrngInterruptHandler<TRNG>;
});

const TRNG_SAMPLE_COUNT: u32 = 1000;

/// Bits taken from each source per round.
const BITS_PER_ROUND: u32 = 256;
const BYTES_PER_ROUND: usize = (BITS_PER_ROUND / 8) as usize;

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

/// A source that is broken on purpose.
///
/// Not a joke entry. Health tests are code, code has bugs, and a check that
/// has never been observed to fire is indistinguishable from a check that
/// cannot. Shipping a known-bad input alongside the real ones is how you find
/// out that the test still works after somebody refactors it.
///
/// This one is biased rather than stuck — nine ones then a zero. That fails
/// the adaptive proportion test while sailing past the repetition count,
/// which is exactly the failure mode the second test was added to catch.
struct BrokenSource {
    n: u32,
}

impl BrokenSource {
    const fn new() -> Self {
        Self { n: 0 }
    }
    fn next_bit(&mut self) -> bool {
        self.n = self.n.wrapping_add(1);
        self.n % 10 != 0
    }
}

fn describe(f: Failure) -> (&'static str, u32) {
    match f {
        Failure::Repetition { run } => ("repetition count", run),
        Failure::Proportion { count } => ("adaptive proportion", count),
    }
}

/// Reports a source's state, and whether it is still allowed to emit.
fn report(name: &str, h: &Health) {
    match h.failed() {
        None => {
            let (seen, matches) = h.window_progress();
            log!(
                "{}: HEALTHY after {} bits (window {}/{}, {} match ref)",
                name,
                h.total(),
                seen,
                health::APT_WINDOW,
                matches
            );
        }
        Some(f) => {
            let (which, value) = describe(f);
            log!(
                "{}: FAILED {} at {} after {} bits — OUTPUT WITHHELD",
                name,
                which,
                value,
                h.total()
            );
        }
    }
}

#[embassy_executor::task]
async fn monitor_task(
    mut adc: Adc<'static, Async>,
    mut channel: Channel<'static>,
    mut trng: Trng<'static, TRNG>,
) -> ! {
    // exp113's lesson: nothing CPU-bound until USB has finished enumerating.
    Timer::after(Duration::from_secs(2)).await;

    log!(
        "SP 800-90B 4.4 continuous tests, alpha = 2^-20, assumed H = {} bit/sample",
        health::ASSUMED_H as u32
    );
    log!(
        "  repetition count cutoff C = {}   adaptive proportion W = {}, C = {}",
        health::RCT_CUTOFF,
        health::APT_WINDOW,
        health::APT_CUTOFF
    );

    let mut trng_health = Health::new();
    let mut adc_health = Health::new();
    let mut broken_health = Health::new();
    let mut broken = BrokenSource::new();
    let mut round: u32 = 0;

    loop {
        round += 1;

        // -- the TRNG --------------------------------------------------------
        //
        // Note the order: the health tests run on the bits *before* anything
        // downstream is allowed to see them. A source that has failed produces
        // nothing at all — which is what "withheld" means, and why this is not
        // simply a louder version of exp111.
        if trng_health.failed().is_none() {
            let mut bytes = [0u8; BYTES_PER_ROUND];
            trng.fill_bytes(&mut bytes).await;
            for byte in bytes {
                for i in 0..8 {
                    trng_health.push((byte >> i) & 1 == 1);
                }
            }
        }

        // -- the ADC's bottom bit ---------------------------------------------
        if adc_health.failed().is_none() {
            let mut abandoned = false;
            for _ in 0..BITS_PER_ROUND {
                match adc.read(&mut channel).await {
                    Ok(s) => {
                        adc_health.push(s & 1 == 1);
                    }
                    Err(_) => {
                        abandoned = true;
                        break;
                    }
                }
            }
            if abandoned {
                log!("adc: read failed — round abandoned, no bits counted");
            }
        }

        // -- the source that is supposed to fail -------------------------------
        if broken_health.failed().is_none() {
            for _ in 0..BITS_PER_ROUND {
                broken_health.push(broken.next_bit());
            }
        }

        report("trng  ", &trng_health);
        report("adc   ", &adc_health);
        report("broken", &broken_health);

        // The verdict that matters, restated every round so a terminal
        // attached at any moment can read it. exp112 and exp113 both shipped
        // a fact that printed once and was therefore mostly invisible.
        if round % 5 == 0 {
            let sources: [&Health; 2] = [&trng_health, &adc_health];
            let healthy = sources.iter().filter(|h| h.failed().is_none()).count();
            log!(
                "-> {} of 2 real sources still permitted to emit; broken source {}",
                healthy,
                if broken_health.failed().is_some() {
                    "correctly rejected"
                } else {
                    "NOT YET rejected (the tests have not caught it)"
                }
            );
        }

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
    config.product = Some("exp114 health tests");
    config.serial_number = Some("114");
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

    log!("exp114 up. Watching three sources, and refusing the ones that fail.");

    let adc = Adc::new(p.ADC, Irqs, AdcConfig::default());
    let channel = Channel::new_temp_sensor(p.ADC_TEMP_SENSOR);
    let mut trng_config = TrngConfig::default();
    trng_config.sample_count = TRNG_SAMPLE_COUNT;
    let trng = Trng::new(p.TRNG, Irqs, trng_config);
    spawner.spawn(monitor_task(adc, channel, trng).unwrap());

    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
