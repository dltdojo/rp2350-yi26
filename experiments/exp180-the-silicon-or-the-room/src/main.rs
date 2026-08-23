// SPDX-License-Identifier: Apache-2.0
//! exp180 — the silicon or the room.
//!
//! A ring-oscillator PUF claims that a chip's own oscillator runs at a speed
//! nobody else's does. Earlier work on this chip measured three boards and found
//! a **13.34% spread** in the ROSC base frequency — 10.828, 11.928 and 10.524
//! MHz — and read that as device uniqueness.
//!
//! **Ring oscillators also drift with temperature.** Three boards measured once
//! each cannot separate one cause from the other, and this experiment is the
//! comparison that can: **one board, cold, against the same board warm**, with
//! the chip heating itself and [exp108](../exp108-adc-temperature/)'s sensor
//! saying by how much. If a board's own frequency moves a meaningful part of
//! 13.34% over its own working temperature range, then "device uniqueness"
//! measured at an unrecorded temperature is measuring the room.
//!
//! # What the earlier table already says
//!
//! It measured two kinds of number, and they behave differently:
//!
//! | | Device 1 | Device 2 | Device 3 | spread |
//! | --- | --- | --- | --- | --- |
//! | ROSC base frequency | 10.828 MHz | 11.928 MHz | 10.524 MHz | **13.34%** |
//! | Config 1 **ratio** | 1.027 | 1.032 | 1.033 | **0.6%** |
//!
//! A **ratio** is two measurements of the same oscillator, moments apart, at the
//! same temperature — most of the drift divides out. A **base frequency** is a
//! single absolute number, and drift is all of it. The uniqueness in that table
//! lives almost entirely in the quantity that temperature moves, and almost none
//! of it in the quantity that temperature does not. Two of the three boards
//! produced the same 7-bit signature.
//!
//! # And one number in it cannot mean what it says
//!
//! The same work reported the low-power oscillator at **28.00, 32.00 and 28.00
//! kHz** — a "14.28% spread". Its frequency counter ran with `FC0_INTERVAL = 8`,
//! and the RP2350's counter measures over about `0.98 µs × 2^interval` — call it
//! **251 µs**. A 32 kHz clock fits about **eight periods** in that window, so the
//! counter's resolution there is about **4 kHz**. 28.00 and 32.00 are *one count
//! apart*. This experiment measures LPOSC at that interval and at `interval =
//! 15` — about 32 ms, a thousand periods — and prints both, so the step is
//! visible rather than asserted.
//!
//! # What this cannot do
//!
//! It has **one board**. The inter-device half needs the second one, which lives
//! with a phone and is never on this bench, and even then n = 2 against the
//! earlier work's three. What one board can settle is the *other* half of the
//! question, and it is the half that decides whether the first one means
//! anything.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_rp::adc::{Adc, Channel as AdcChannel, Config as AdcConfig, InterruptHandler as AdcIrq};
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::pac;
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, InterruptHandler};
use core::sync::atomic::{AtomicU8, Ordering};

use embassy_time::{Duration, Instant, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use static_cell::StaticCell;
use usb_log::log;

use panic_halt as _;

const PRODUCT: &str = "exp180 the silicon or the room";

/// `FC0_SRC` values, from `rp-pac`'s `Fc0src` for the **RP2350**. The RP2040
/// numbers them differently, which is a good reason to name them here rather
/// than write `3` at the call site.
const SRC_ROSC: u32 = 0x03;
const SRC_XOSC: u32 = 0x05;
const SRC_LPOSC: u32 = 0x0e;

/// The earlier work's interval, kept so its reading can be reproduced.
///
/// The window is about `0.98 µs × 2^interval` — 251 µs here — so the counter's
/// resolution is about 4 kHz whatever it is pointed at. **This experiment's
/// first run measured its own resolution and called it drift**: every ROSC
/// reading was a multiple of 4 kHz, and the ±0.058% that looked like
/// temperature was one count at 6.8 MHz. The same trap as the LPOSC number
/// above, one step further down, and it is why nothing but the deliberate
/// reproduction uses this interval now.
const INTERVAL_SHORT: u8 = 8;
/// About 32 ms: 31 Hz of resolution, which is 0.0005% at ROSC's frequency and a
/// thousand periods at LPOSC's.
const INTERVAL_LONG: u8 = 15;

/// The password `FREQA`/`FREQB` refuse a write without.
const ROSC_PASSWD: u32 = 0x9696 << 16;

/// The shape of the run, in seconds.
/// The board's own warm-up **is** the temperature sweep.
///
/// A Pico 2 sitting plugged in idles some way above the room, and everything
/// this experiment tried before was working inside the last degree of that. A
/// finger is worse than useless: skin is around 33 °C and the die is at 41 °C,
/// so pressing one on the chip **cools it**, which is what the transcript in
/// `capture-finger.txt` shows it doing — 0.7 °C the wrong way. What is free, and
/// twenty times larger, is the climb from room temperature to equilibrium after
/// the board has been unplugged long enough to forget it was ever on.
const SAMPLE_EVERY: u64 = 15;

/// What the LED is saying.
///
/// **The LED is the instrument here, not decoration.** The measurement needs a
/// person to warm the chip for a known interval, and exp171 is where this
/// repository learned that asking somebody to count seconds puts their reflex
/// inside the measurement. So the board says when to start and when to stop, and
/// all the person has to do is watch one light.
const LED_WAIT: u8 = 0;
const LED_HOLD: u8 = 1;
const LED_RELEASE: u8 = 2;
static LED_MODE: AtomicU8 = AtomicU8::new(LED_WAIT);

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    ADC_IRQ_FIFO => AdcIrq;
});

/// One frequency measurement, in units of 1/32 kHz — which is exactly what the
/// hardware returns, `khz` in the top 25 bits and a five-bit fraction below.
/// Kept unscaled so nothing is rounded before it is compared.
fn measure(src: u32, interval: u8) -> Option<u32> {
    let c = pac::CLOCKS;
    c.fc0_ref_khz().write(|w| w.set_fc0_ref_khz(12_000));
    c.fc0_interval().write(|w| w.set_fc0_interval(interval));
    c.fc0_delay().write(|w| w.set_fc0_delay(3));
    c.fc0_min_khz().write(|w| w.set_fc0_min_khz(0));
    c.fc0_max_khz().write(|w| w.set_fc0_max_khz(0x01ff_ffff));
    // Writing SRC starts it. Everything above has to be in place first.
    c.fc0_src().write(|w| w.set_fc0_src(unsafe { core::mem::transmute(src as u8) }));

    // The window is up to ~32 ms at the long interval, so the wait has to allow
    // for it. A fixed spin count would be a timeout that depends on the compiler.
    let deadline = Instant::now() + Duration::from_millis(200);
    while Instant::now() < deadline {
        if c.fc0_status().read().done() {
            let r = c.fc0_result().read();
            return Some((r.khz() << 5) | r.frac() as u32);
        }
    }
    None
}

/// Sets the ring oscillator's stage-0 drive strength and returns what it does to
/// the frequency. Restoring the original is the caller's job.
fn rosc_at_drive(ds0: u8, interval: u8) -> Option<u32> {
    let r = pac::ROSC;
    r.freqa().write(|w| {
        w.0 = ROSC_PASSWD | (ds0 as u32 & 0x07);
    });
    r.freqb().write(|w| {
        w.0 = ROSC_PASSWD;
    });
    // Let it settle before asking. The oscillator is analogue.
    cortex_m::asm::delay(10_000);
    measure(SRC_ROSC, interval)
}

fn rosc_restore(original_freqa: u32, original_freqb: u32) {
    let r = pac::ROSC;
    r.freqa().write(|w| w.0 = ROSC_PASSWD | (original_freqa & 0xffff));
    r.freqb().write(|w| w.0 = ROSC_PASSWD | (original_freqb & 0xffff));
}

/// exp108's arithmetic, unchanged. Its caveat applies here and matters more:
/// the constants are typical rather than a calibration of this chip, so the
/// **absolute** temperature is not to be trusted to a degree. What this
/// experiment uses is the **change**, which is the part that holds.
fn raw_to_centi_celsius_x64(sum_of_64: u32) -> i32 {
    // 3.3 V over 4096 steps, in microvolts, times 64 readings.
    let microvolts = (sum_of_64 as i64 * 3_300_000) / (4096 * 64);
    // 27 °C at 706000 µV, falling 1721 µV per degree.
    (2700 - ((microvolts - 706_000) * 100) / 1721) as i32
}

/// Sixty-four conversions averaged.
///
/// One conversion quantises to about 0.47 °C — 12 bits over 3.3 V against a
/// slope of 1.721 mV per degree — which is most of the range this board can heat
/// itself through. Averaging over the sensor's own noise recovers some of that;
/// it does not improve the absolute accuracy, which exp108 says not to trust
/// anyway, and this experiment only uses the change.
async fn read_temperature(
    adc: &mut Adc<'static, embassy_rp::adc::Async>,
    ch: &mut AdcChannel<'static>,
) -> i32 {
    let mut sum: u32 = 0;
    for _ in 0..64 {
        sum += adc.read(ch).await.unwrap_or(0) as u32;
    }
    // The average in sixty-fourths of a count, converted once at the end.
    raw_to_centi_celsius_x64(sum)
}

/// Thousandths of a percent, so a drift of 0.02% is still a number.
fn per_mille_of_a_percent(now: u32, base: u32) -> i32 {
    if base == 0 {
        return 0;
    }
    ((now as i64 - base as i64) * 100_000 / base as i64) as i32
}

fn khz_whole(units: u32) -> u32 {
    units / 32
}
fn khz_frac(units: u32) -> u32 {
    (units % 32) * 100 / 32
}

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

/// Slow blink: not yet. Solid: hold a finger on the chip. Fast blink: let go.
#[embassy_executor::task]
async fn led_task(mut led: Output<'static>) -> ! {
    loop {
        match LED_MODE.load(Ordering::Relaxed) {
            LED_HOLD => {
                led.set_high();
                Timer::after(Duration::from_millis(50)).await;
            }
            LED_RELEASE => {
                led.toggle();
                Timer::after(Duration::from_millis(100)).await;
            }
            _ => {
                led.toggle();
                Timer::after(Duration::from_millis(500)).await;
            }
        }
    }
}

/// What the ring oscillator's *configuration* does to the number a PUF would
/// call a fingerprint.
///
/// `FREQ_RANGE` is four settings in a register, written by firmware. If moving
/// it moves the base frequency by more than the spread the earlier work called
/// device uniqueness, then that spread is not a property of the silicon alone.
fn range_table(interval: u8) {
    let r = pac::ROSC;
    let stock = r.ctrl().read();
    let stock_range = stock.freq_range().to_bits();
    let freqa = r.freqa().read().0 & 0xffff;
    let freqb = r.freqb().read().0 & 0xffff;
    log!(
        "  ROSC as this firmware found it: range 0x{:03x}, freqa 0x{:04x}, freqb 0x{:04x}",
        stock_range, freqa, freqb
    );
    for (name, bits) in [("LOW", 0x0fa4u16), ("MEDIUM", 0x0fa5), ("HIGH", 0x0fa7)] {
        r.ctrl().modify(|w| w.set_freq_range(pac::rosc::vals::FreqRange::from_bits(bits)));
        cortex_m::asm::delay(100_000);
        if let Some(f) = measure(SRC_ROSC, interval) {
            log!("    range {}: {}.{:02} kHz", name, khz_whole(f), khz_frac(f));
        }
    }
    r.ctrl().modify(|w| w.set_freq_range(pac::rosc::vals::FreqRange::from_bits(stock_range)));
    cortex_m::asm::delay(100_000);
}

/// The eight drive-strength settings, cold and again warm.
fn drive_table(label: &str, interval: u8) {
    let r = pac::ROSC;
    let orig_a = r.freqa().read().0;
    let orig_b = r.freqb().read().0;
    let base = rosc_at_drive(0, interval).unwrap_or(0);
    log!("  {} drive table, base {}.{:02} kHz:", label, khz_whole(base), khz_frac(base));
    for ds in 1..8u8 {
        if let Some(f) = rosc_at_drive(ds, interval) {
            // Ratio to base, in ten-thousandths, so 1.0273 prints as 10273.
            let ratio = if base > 0 { (f as u64 * 10_000 / base as u64) as u32 } else { 0 };
            log!("    ds0={} {}.{:02} kHz  ratio {}.{:04}", ds, khz_whole(f), khz_frac(f), ratio / 10_000, ratio % 10_000);
        } else {
            log!("    ds0={} no answer from the counter", ds);
        }
    }
    rosc_restore(orig_a, orig_b);
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    spawner.spawn(led_task(Output::new(p.PIN_25, Level::Low)).unwrap());

    let mut adc = Adc::new(p.ADC, Irqs, AdcConfig::default());
    let mut temp_channel = AdcChannel::new_temp_sensor(p.ADC_TEMP_SENSOR);

    // **First**, before the USB stack is built and before the 2.5 s it takes a
    // host to attach. On a board that has been unplugged long enough this is the
    // only moment it is at room temperature, and every earlier version of this
    // experiment spent that moment setting up a serial port.
    let t_boot = read_temperature(&mut adc, &mut temp_channel).await;
    let rosc_boot = measure(SRC_ROSC, INTERVAL_LONG).unwrap_or(0);

    let driver = Driver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(PRODUCT);
    config.serial_number = Some("180");
    config.max_power = 100;
    config.max_packet_size_0 = 64;

    static CONFIG_DESC: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESC: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; 128]> = StaticCell::new();
    static ACM_STATE: StaticCell<State> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESC.init([0; 256]),
        BOS_DESC.init([0; 256]),
        &mut [],
        CONTROL_BUF.init([0; 128]),
    );
    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), 64);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());
    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(reboot_task(control, receiver).unwrap());
    spawner.spawn(log_task(sender).unwrap());

    Timer::after(Duration::from_millis(2500)).await;
    log!("{}", PRODUCT);
    log!("  one board, heating itself. The earlier work's spread across three boards was 13.34%.");

    // The counter, checked against the one clock that should not move.
    let xosc_cold = measure(SRC_XOSC, INTERVAL_LONG).unwrap_or(0);
    log!("  crystal (the control): {}.{:02} kHz", khz_whole(xosc_cold), khz_frac(xosc_cold));

    // The LPOSC reading, at the earlier interval and at one that fits the clock.
    let lp_short = measure(SRC_LPOSC, INTERVAL_SHORT).unwrap_or(0);
    let lp_long = measure(SRC_LPOSC, INTERVAL_LONG).unwrap_or(0);
    log!(
        "  LPOSC at interval 8: {}.{:02} kHz — the window holds about eight of its periods",
        khz_whole(lp_short), khz_frac(lp_short)
    );
    log!(
        "  LPOSC at interval 15: {}.{:02} kHz — about a thousand",
        khz_whole(lp_long), khz_frac(lp_long)
    );

    let rosc_short = measure(SRC_ROSC, INTERVAL_SHORT).unwrap_or(0);
    log!(
        "  ROSC at interval 8: {}.{:02} kHz — every reading a multiple of 4 kHz, which is one count",
        khz_whole(rosc_short), khz_frac(rosc_short)
    );

    range_table(INTERVAL_LONG);

    // Shed whatever the previous run left in the package. Without this the
    // "cold" reading is whatever the last thing to run happened to leave, and
    // the second run of this experiment measured a board that started at
    // 42 C and had nowhere to go.
    log!(
        "at boot: {}.{:02} C, ROSC {}.{:02} kHz — taken before USB came up",
        t_boot / 100, (t_boot % 100).abs(), khz_whole(rosc_boot), khz_frac(rosc_boot)
    );
    log!("now watching it warm itself to equilibrium, and saying so forever");
    drive_table("at boot", INTERVAL_LONG);

    // **Never stop reporting.** exp157's README says it plainly — a fact printed
    // once is a fact most readers never see — and the first cold-start run of
    // this experiment proved it by scrolling its whole result past an unattached
    // host: eighty lines lost, and the boot reading that cost somebody a
    // ten-minute wait with it. So there is no "phase" here that ends. Every
    // sample prints the comparison in full, and whenever anybody attaches, the
    // answer is the next line rather than something they had to be present for.
    let started = Instant::now();
    let mut peak_dt: i32 = 0;
    let mut drift_at_peak: i32 = 0;
    loop {
        Timer::after(Duration::from_secs(SAMPLE_EVERY)).await;
        let t = read_temperature(&mut adc, &mut temp_channel).await;
        let f = measure(SRC_ROSC, INTERVAL_LONG).unwrap_or(0);
        let dt = t - t_boot;
        let drift = per_mille_of_a_percent(f, rosc_boot);
        if dt.abs() > peak_dt.abs() {
            peak_dt = dt;
            drift_at_peak = drift;
        }
        log!(
            "  +{}s  {}.{:02} C (boot {}.{:02})  ROSC {}.{:02} kHz  {}{}.{:03}%",
            started.elapsed().as_secs(),
            t / 100, (t % 100).abs(), t_boot / 100, (t_boot % 100).abs(),
            khz_whole(f), khz_frac(f),
            if drift < 0 { "-" } else { "+" }, drift.abs() / 1000, drift.abs() % 1000
        );
        if peak_dt.abs() >= 100 {
            let per_degree = drift_at_peak * 100 / peak_dt;
            let over_twenty = per_degree * 20 / 1000;
            log!(
                "    widest so far: {}.{:02} C for {}{}.{:03}%, so {}{}.{:03}%/C — twenty degrees of that is {}{}.{:01}%, against 13.34% across three boards",
                peak_dt / 100, (peak_dt % 100).abs(),
                if drift_at_peak < 0 { "-" } else { "+" },
                drift_at_peak.abs() / 1000, drift_at_peak.abs() % 1000,
                if per_degree < 0 { "-" } else { "+" },
                per_degree.abs() / 1000, per_degree.abs() % 1000,
                if over_twenty < 0 { "-" } else { "+" },
                over_twenty.abs() / 10, over_twenty.abs() % 10
            );
        }
    }
}
