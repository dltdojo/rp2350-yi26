//! exp111 — two sources that both look random.
//!
//! exp108 read a temperature sensor and exp109 read an entropy source. Print
//! the raw bits from either one and they look the same: no pattern, no
//! structure, nothing a person could pick out. One of them is random and the
//! other is a thermometer being misused, and **you cannot tell by looking**.
//!
//! So this firmware stops looking and starts counting. It harvests the same
//! number of bits from both sources every round and runs two very cheap tests
//! on each:
//!
//! - **ones** — what fraction of the bits are 1. A fair coin gives 50%.
//! - **changes** — how often a bit differs from the one before it. Also 50%.
//!
//! Two tests, because one test that passes proves much less than two tests
//! that disagree. Read the numbers in the log before the README's conclusion.
//!
//! And read the README's last section too, because both tests together are
//! still nowhere near enough to certify a random number generator, and knowing
//! *why* is more useful than either result.

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
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    ADC_IRQ_FIFO => AdcInterruptHandler;
    TRNG_IRQ => TrngInterruptHandler<TRNG>;
});

/// exp109's measured value. Held fixed here; it is not the subject.
const TRNG_SAMPLE_COUNT: u32 = 1000;

/// Bits taken from each source per round.
///
/// Equal on purpose. Comparing two counts is only meaningful against the same
/// denominator, and making the reader divide by two different totals in their
/// head is how a comparison stops being read at all.
const BITS_PER_ROUND: u32 = 64;

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

/// Counts the set bits in a slice. The whole of the "monobit" test.
fn count_ones(bytes: &[u8]) -> u32 {
    bytes.iter().map(|b| b.count_ones()).sum()
}

/// Counts how often a bit differs from the one before it.
///
/// The second test, and the reason there are two. A fair coin changes its mind
/// about half the time, so this should also land near 50%. A source that is
/// stuck, or drifting slowly between two neighbouring values, produces long
/// runs of the same bit and scores far below — *while sailing through the
/// monobit test*, because long runs of ones and long runs of zeroes still
/// average out to half.
///
/// Bits are walked in the order they were packed, least-significant first, and
/// `prev` carries the last bit across both byte and round boundaries so runs
/// are not silently cut every 64 bits.
fn count_transitions(bytes: &[u8], prev: &mut Option<bool>) -> u32 {
    let mut changes = 0;
    for byte in bytes {
        for i in 0..8 {
            let bit = (byte >> i) & 1 == 1;
            if let Some(p) = *prev {
                if p != bit {
                    changes += 1;
                }
            }
            *prev = Some(bit);
        }
    }
    changes
}

/// Harvests both sources and scores them.
#[embassy_executor::task]
async fn compare_task(
    mut adc: Adc<'static, Async>,
    mut channel: Channel<'static>,
    mut trng: Trng<'static, TRNG>,
) -> ! {
    // Cumulative, not per-round. Sixty-four bits is far too few to say
    // anything at all, and watching the percentages settle as the totals grow
    // is itself the lesson about how much data a statistical claim needs.
    let mut trng_ones: u32 = 0;
    let mut adc_ones: u32 = 0;
    let mut trng_changes: u32 = 0;
    let mut adc_changes: u32 = 0;
    let mut trng_prev: Option<bool> = None;
    let mut adc_prev: Option<bool> = None;
    let mut bits_total: u32 = 0;
    let mut round: u32 = 0;

    loop {
        round += 1;

        // The sensor, read for its noise instead of its meaning.
        //
        // One bit per conversion: the bottom bit, the one that wobbles.
        // Taken back to back rather than a second apart, because the question
        // is what the sensor's own noise looks like and not what the room did.
        //
        // This is the thing people reach for when they want free entropy and
        // have no TRNG. It is worth finding out what it is actually worth.
        let mut adc_bits = [0u8; BYTES_PER_ROUND];
        let mut harvest_failed = false;
        for i in 0..BITS_PER_ROUND {
            // Not `unwrap_or(0)`.
            //
            // Substituting a constant when a source fails is how an entropy
            // path goes wrong silently: the zeroes flow into the statistics
            // and look like data. This is a miniature of the failure class
            // the README describes, so it does not get to live here — a
            // failed read abandons the round and says so.
            match adc.read(&mut channel).await {
                Ok(sample) => {
                    if sample & 1 == 1 {
                        adc_bits[(i / 8) as usize] |= 1 << (i % 8);
                    }
                }
                Err(_) => {
                    harvest_failed = true;
                    break;
                }
            }
        }
        if harvest_failed {
            log!("adc: read failed — round abandoned, no bits counted");
            Timer::after(Duration::from_secs(1)).await;
            continue;
        }

        let mut trng_bytes = [0u8; BYTES_PER_ROUND];
        trng.fill_bytes(&mut trng_bytes).await;

        trng_ones += count_ones(&trng_bytes);
        adc_ones += count_ones(&adc_bits);
        trng_changes += count_transitions(&trng_bytes, &mut trng_prev);
        adc_changes += count_transitions(&adc_bits, &mut adc_prev);
        bits_total += BITS_PER_ROUND;

        if round == 1 {
            log!("Both of these look random. One of them is not.");
            log!("trng: {:02x} {:02x} {:02x} {:02x}  adc-lsb: {:02x} {:02x} {:02x} {:02x}",
                trng_bytes[0], trng_bytes[1], trng_bytes[2], trng_bytes[3],
                adc_bits[0], adc_bits[1], adc_bits[2], adc_bits[3]);
        }

        // Percent with one decimal, without a float formatter: multiply by
        // 1000 and split. `usb-log` writes into a fixed buffer with no
        // allocator behind it, and integer maths keeps each line one line.
        let pct = |n: u32, d: u32| {
            let pm = n * 1000 / d;
            (pm / 10, pm % 10)
        };
        let (to1, to2) = pct(trng_ones, bits_total);
        let (ao1, ao2) = pct(adc_ones, bits_total);
        let (tc1, tc2) = pct(trng_changes, bits_total);
        let (ac1, ac2) = pct(adc_changes, bits_total);

        log!(
            "ones     after {} bits: trng {}.{}%  adc-lsb {}.{}%  (fair coin 50.0%)",
            bits_total, to1, to2, ao1, ao2
        );
        log!(
            "changes  after {} bits: trng {}.{}%  adc-lsb {}.{}%  (fair coin 50.0%)",
            bits_total, tc1, tc2, ac1, ac2
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
    config.product = Some("exp111 measuring randomness");
    config.serial_number = Some("111");
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

    log!("exp111 up. Scoring two sources against a fair coin.");

    let adc = Adc::new(p.ADC, Irqs, AdcConfig::default());
    let channel = Channel::new_temp_sensor(p.ADC_TEMP_SENSOR);
    let mut trng_config = TrngConfig::default();
    trng_config.sample_count = TRNG_SAMPLE_COUNT;
    let trng = Trng::new(p.TRNG, Irqs, trng_config);
    spawner.spawn(compare_task(adc, channel, trng).unwrap());

    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
