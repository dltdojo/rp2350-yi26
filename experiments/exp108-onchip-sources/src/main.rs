//! exp108 — two sources of numbers your program did not compute.
//!
//! Everything logged so far was something the firmware worked out: a counter,
//! a timestamp, how late a wakeup was. This experiment reads two peripherals
//! that manufacture numbers on their own:
//!
//! - the **on-chip temperature sensor**, an analogue voltage on ADC channel 4
//!   that the datasheet says how to turn into degrees, and
//! - the **TRNG**, a hardware entropy source that samples a ring oscillator.
//!
//! Both hand you bits. Only one of them is random, and the interesting part of
//! this experiment is that **you cannot tell which by looking**. So it also
//! runs the cheapest statistical test there is — counting ones — on both, and
//! prints the result. Read the numbers in the log before reading the takeaway
//! in the README; the point lands harder that way.
//!
//! Nothing here can be blinked. The temperature is a number, the entropy is a
//! number, and the test result is a number: this is exp107's log doing the job
//! it was built for.

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
use embassy_time::{Duration, Instant, Timer};
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

/// How many bits are harvested from each source per round.
///
/// Equal on purpose: comparing a count of ones is only meaningful against the
/// same denominator, and making the reader divide two different totals in
/// their head is how a comparison stops being read at all.
const BITS_PER_ROUND: u32 = 64;

/// One ADC reading yields one bit, so a round needs this many conversions.
/// They are taken back to back rather than a second apart, because the
/// question is what the sensor's own noise looks like, not what the room did.
const ADC_SAMPLES_PER_ROUND: u32 = BITS_PER_ROUND;

/// The TRNG hands out whole bytes, so a round asks for this many.
const TRNG_BYTES_PER_ROUND: usize = (BITS_PER_ROUND / 8) as usize;

/// Clock cycles between two consecutive ring-oscillator samples.
///
/// `embassy-rp`'s default is 25, and on this board that is too fast: samples
/// taken that close together are correlated enough to fail the TRNG's own
/// health tests repeatedly. Measured with the default, a single 64-bit fill
/// took anywhere from 20 ms to 3.8 seconds, and the driver's own log says
/// "increase sample count to reduce likelihood" every time a test trips.
///
/// This number was chosen by measuring, not by taste — the README shows both
/// sets of timings. Sampling more slowly does not make the entropy better; it
/// makes consecutive samples independent enough that the health tests stop
/// rejecting them, which is a different thing and worth not confusing.
const TRNG_SAMPLE_COUNT: u32 = 1000;

/// Turns a raw 12-bit conversion into degrees Celsius.
///
/// Straight out of the RP2350 datasheet: the sensor is a diode whose forward
/// voltage falls about 1.721 mV per degree, and reads 0.706 V at 27 °C. The
/// ADC's full scale is 3.3 V across 12 bits.
///
/// Worth knowing before trusting a number this produces: those constants are
/// typical values, not per-chip calibration. The datasheet is explicit that
/// the absolute accuracy is poor without calibrating each board; what *is*
/// trustworthy is the shape of the change — warm the chip with a finger and
/// the number moves the right way by roughly the right amount.
fn raw_to_celsius(raw: u16) -> f32 {
    const CONVERSION: f32 = 3.3 / 4096.0;
    let volts = raw as f32 * CONVERSION;
    27.0 - (volts - 0.706) / 0.001_721
}

/// Counts the set bits in a slice.
///
/// This is the whole of the "monobit" test: a sequence of random bits should
/// be about half ones. It is the cheapest test of randomness that exists, and
/// the README is careful about what passing it does and does not mean.
fn count_ones(bytes: &[u8]) -> u32 {
    bytes.iter().map(|b| b.count_ones()).sum()
}

/// Counts how often a bit differs from the one before it.
///
/// The second test, and the reason there are two. A fair coin changes its
/// mind about half the time, so this should also land near 50%. A source that
/// is stuck, or that drifts slowly between two neighbouring values, produces
/// long runs of the same bit and scores far below — *while sailing through the
/// monobit test above*, because long runs of ones and long runs of zeroes
/// still average out to half.
///
/// Two tests that disagree are worth more than one test that passes. Bits are
/// walked in the order they were packed, least-significant first, and `prev`
/// carries the last bit across both byte and round boundaries so the runs are
/// not silently cut every 64 bits.
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

/// The experiment. Owns both peripherals, reports both, and compares them.
///
/// Everything it needs arrives as an argument and nothing is shared, so there
/// is no lock in this program — the same ownership argument exp107 made about
/// the USB sender, applied to hardware that measures.
#[embassy_executor::task]
async fn sources_task(
    mut adc: Adc<'static, Async>,
    mut temp_channel: Channel<'static>,
    mut trng: Trng<'static, TRNG>,
) -> ! {

    // Running totals. Deliberately cumulative rather than per-round: a single
    // round of 64 bits is far too few to say anything, and watching the
    // percentages settle as the totals grow is itself the lesson about how
    // much data a statistical claim needs.
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

        // -- the temperature, as a temperature ------------------------------
        let raw = adc.read(&mut temp_channel).await.unwrap_or(0);
        let celsius = raw_to_celsius(raw);
        log!(
            "temp: raw {} of 4095 -> {}.{:02} C",
            raw,
            celsius as i32,
            ((celsius - celsius as i32 as f32) * 100.0) as i32
        );

        // -- the same sensor, read for its noise instead ---------------------
        //
        // The bottom bit of each conversion. If the sensor were a perfect
        // voltmeter attached to a perfectly steady diode, this would be a
        // constant and every bit here would be identical. It is not, and that
        // wobble is exactly what makes people reach for an ADC as an entropy
        // source in the first place.
        let mut adc_bits: [u8; TRNG_BYTES_PER_ROUND] = [0; TRNG_BYTES_PER_ROUND];
        for i in 0..ADC_SAMPLES_PER_ROUND {
            let sample = adc.read(&mut temp_channel).await.unwrap_or(0);
            if sample & 1 == 1 {
                adc_bits[(i / 8) as usize] |= 1 << (i % 8);
            }
        }

        // -- the hardware entropy source -------------------------------------
        //
        // `fill_bytes`, not `blocking_fill_bytes`, and the difference is the
        // whole reason this line is worth a comment.
        //
        // A real entropy source runs health tests on what it collects — the
        // RP2350's TRNG has an autocorrelation test, a CRNGT test and a Von
        // Neumann balancer, all on by default. A sample that fails is thrown
        // away and the block starts over, so the time to produce 192 bits is
        // variable and has no upper bound worth relying on. Measured on this
        // board it ranges from about 20 ms to nearly four seconds.
        //
        // The blocking version would spend that time inside this task with the
        // executor unable to run anything else — including the 1200-baud
        // watcher that lets the next flash happen without touching the board.
        // Awaiting hands the CPU back for the duration. The timing printed
        // below is the same wait either way; what changes is whether the rest
        // of the firmware waits with it.
        let mut trng_bytes: [u8; TRNG_BYTES_PER_ROUND] = [0; TRNG_BYTES_PER_ROUND];
        let t0 = Instant::now();
        trng.fill_bytes(&mut trng_bytes).await;
        let fill_us = (Instant::now() - t0).as_micros();

        log!(
            "trng: {:02x} {:02x} {:02x} {:02x} {:02x} {:02x} {:02x} {:02x}  ({} us awaited)",
            trng_bytes[0],
            trng_bytes[1],
            trng_bytes[2],
            trng_bytes[3],
            trng_bytes[4],
            trng_bytes[5],
            trng_bytes[6],
            trng_bytes[7],
            fill_us
        );

        // -- the comparison ---------------------------------------------------
        trng_ones += count_ones(&trng_bytes);
        adc_ones += count_ones(&adc_bits);
        trng_changes += count_transitions(&trng_bytes, &mut trng_prev);
        adc_changes += count_transitions(&adc_bits, &mut adc_prev);
        bits_total += BITS_PER_ROUND;

        // Percent with one decimal, without dragging in a float formatter:
        // multiply by 1000 and split. Integer maths, and each log line stays
        // one line.
        let pct = |n: u32, d: u32| {
            let pm = n * 1000 / d;
            (pm / 10, pm % 10)
        };
        let (t1, t2) = pct(trng_ones, bits_total);
        let (a1, a2) = pct(adc_ones, bits_total);
        log!(
            "ones     after {} bits: trng {}.{}%  adc-lsb {}.{}%  (fair coin 50.0%)",
            bits_total,
            t1,
            t2,
            a1,
            a2
        );
        let (t3, t4) = pct(trng_changes, bits_total);
        let (a3, a4) = pct(adc_changes, bits_total);
        log!(
            "changes  after {} bits: trng {}.{}%  adc-lsb {}.{}%  (fair coin 50.0%)",
            bits_total,
            t3,
            t4,
            a3,
            a4
        );

        if round == 1 {
            log!("Two tests, two sources. Read all four numbers before the README.");
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
    config.product = Some("exp108 onchip sources");
    config.serial_number = Some("108");
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

    log!("exp108 up. Two sources, one question: which of them is random?");

    let adc = Adc::new(p.ADC, Irqs, AdcConfig::default());
    let temp_channel = Channel::new_temp_sensor(p.ADC_TEMP_SENSOR);
    let mut trng_config = TrngConfig::default();
    trng_config.sample_count = TRNG_SAMPLE_COUNT;
    let trng = Trng::new(p.TRNG, Irqs, trng_config);
    spawner.spawn(sources_task(adc, temp_channel, trng).unwrap());

    // The heartbeat, and it earns its place twice over.
    //
    // For anyone looking at the board rather than the log, it is the only sign
    // of life: everything this experiment produces is a number. And in the log
    // it is the evidence for the claim made beside the `fill_bytes` call above
    // — when the TRNG makes the sources task wait four seconds, four heartbeats
    // go by in the meantime. If they ever stop, something blocked.
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
