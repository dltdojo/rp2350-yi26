//! exp190 — the board that brings itself back.
//!
//! [exp157](../exp157-a-note-for-the-next-boot/) proved that a firmware killed
//! in a way that takes USB and the log with it **comes back and says which step
//! it died in**. This one is the next thing that asks for: not a board that
//! explains its death, but a board that **survives it without a person**.
//!
//! # The claim
//!
//! > **A firmware that dies on the way up brings itself back, and when it
//! > cannot, it hands itself to the ROM bootloader rather than to somebody at a
//! > bench.**
//!
//! # Why, counted
//!
//! One round of work on the authenticator road cost **four trips to a bench**,
//! and every one was the same shape: firmware died, and with it went USB, the
//! log, and the 1200-baud watcher that lets a host reboot the board. What was
//! left needed unplugging, holding down, and plugging back in by a person
//! standing there. The three deaths were ordinary — a `StaticCell` claimed
//! twice, an interface declared with no task servicing it, and
//! `SecretKey::from_slice` on thirty-two zero bytes. **None of them is exotic.
//! The reason each cost a walk is that nothing was watching.**
//!
//! # It has to be able to fail, or it has proved nothing
//!
//! [exp140](../exp140-a-checksum-that-passes/) is this repository's name for a
//! harness that cannot be caught being wrong, and a safety net nobody has
//! dropped a weight on is exactly that. So `EXP190_DIE` is a build input and
//! the run drops four different weights:
//!
//! ```text
//!   never   gets up and stays up                  -> the control
//!   late    dies AFTER saying it is reachable     -> must come back, must NOT hand over
//!   early   dies BEFORE saying it is reachable    -> must hand over after three tries
//!   hang    stops without dying, interrupts off   -> the case no fault handler catches
//! ```
//!
//! **`late` is the one that can fail in the expensive direction.** A board that
//! got up is a board a host can still reboot at 1200 baud, so handing it to the
//! bootloader there would turn an ordinary crash into a device that runs
//! nothing. If this experiment only tested `early` it would be unable to
//! distinguish a working escape from one that fires at everything.
//!
//! # What is not this experiment's
//!
//! The mechanism is [`crates/lifeline`](../../crates/lifeline/), which is used
//! by other firmwares and tested on a host. This experiment is the weight.

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicBool, Ordering};

use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Duration, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::UsbDevice;
use static_cell::StaticCell;

use usb_log::log;

include!(concat!(env!("OUT_DIR"), "/exp190_config.rs"));

/// The defaults, named once. The escape threshold is the number this whole
/// experiment is about: three boots that never got up.
const LIFELINE: lifeline::Config = lifeline::Config {
    boot_us: lifeline::DEFAULT_BOOT_US,
    run_us: lifeline::DEFAULT_RUN_US,
    escape_after: lifeline::DEFAULT_ESCAPE_AFTER,
};

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

const PACKET: usize = 64;

static UP: AtomicBool = AtomicBool::new(false);

/// Stop, without dying.
///
/// Interrupts off and a loop that yields to nothing: no exception fires, no
/// handler runs, and the LED goes on blinking if it is driven by hardware — but
/// nothing else in the firmware will ever run again. **This is the case a fault
/// handler cannot catch**, and the reason the watchdog is armed rather than
/// trusted to one.
#[inline(always)]
fn make_it_hang() -> ! {
    cortex_m::interrupt::disable();
    loop {
        cortex_m::asm::nop();
    }
}

/// Die, in a way that raises an exception on every Cortex-M, every time.
///
/// exp157 measured that reading a peripheral "held in reset" does **not** fault
/// inside an embassy firmware, because `init()` takes every peripheral out of
/// reset before any experiment's code runs. `udf` needs no peripheral, no
/// address and no assumption.
#[inline(always)]
fn make_it_fault() -> ! {
    cortex_m::asm::udf()
}

/// The LED, up before anything that can hang.
///
/// exp156's hardest-won rule, and exp157 records what ignoring it cost: a
/// firmware frozen inside the USB stack with the LED dark looks exactly like one
/// that never started.
///
/// - **one short flash a second** — up
/// - **N quick flashes then a pause** — this is retry number N after a death,
///   and N reaching three is the last boot before the board hands itself over
#[embassy_executor::task]
async fn heartbeat(mut led: Output<'static>, deaths: u8) -> ! {
    loop {
        if !UP.load(Ordering::Relaxed) && deaths > 0 {
            for _ in 0..deaths {
                led.set_high();
                Timer::after(Duration::from_millis(80)).await;
                led.set_low();
                Timer::after(Duration::from_millis(120)).await;
            }
            Timer::after(Duration::from_millis(700)).await;
        } else {
            led.set_high();
            Timer::after(Duration::from_millis(50)).await;
            led.set_low();
            Timer::after(Duration::from_millis(950)).await;
        }
    }
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

/// Everything established so far, on a loop.
///
/// Not tidiness: a fact printed once is a fact most readers never see, and
/// somebody attaching late is the normal case rather than the exception.
#[embassy_executor::task]
async fn report(boot: lifeline::Boot) -> ! {
    loop {
        log!(
            "boot {}, last ended: {:?} at step {} — {} death(s) in a row before it was up",
            boot.count, boot.cause, boot.step, boot.deaths
        );
        log!("  EXP190_DIE={}, escape after {} boots that never got up", DIE, LIFELINE.escape_after);
        Timer::after(Duration::from_secs(3)).await;
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    // FIRST, before embassy_rp::init and before any peripheral.
    //
    // If three boots in a row have died before saying they were reachable, this
    // call does not return: it hands the board to the ROM bootloader, where a
    // host can reflash it with nobody touching a button. That is the whole
    // claim, and everything below it is the weight that tests it.
    let boot = lifeline::begin(LIFELINE);

    let p = embassy_rp::init(Default::default());
    spawner.spawn(heartbeat(Output::new(p.PIN_25, Level::Low), boot.deaths).unwrap());
    spawner.spawn(lifeline::keepalive(LIFELINE).unwrap());

    if DIE == "early" {
        // Before USB. No log, no CDC, no 1200-baud watcher — the board is not
        // on the bus at all, which is exactly the state that costs a walk.
        make_it_fault();
    }
    if DIE == "hang" {
        make_it_hang();
    }

    static BUS: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL: StaticCell<[u8; 128]> = StaticCell::new();
    static ACM: StaticCell<State> = StaticCell::new();

    let driver = Driver::new(p.USB, Irqs);
    let mut config = embassy_usb::Config::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp190 the board that brings itself back");
    config.serial_number = Some("190");
    config.max_power = 100;
    config.max_packet_size_0 = 64;

    let mut builder = embassy_usb::Builder::new(
        driver,
        config,
        BUS.init([0; 256]),
        BOS.init([0; 256]),
        &mut [],
        CONTROL.init([0; 128]),
    );
    let class = CdcAcmClass::new(&mut builder, ACM.init(State::new()), PACKET as u16);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());
    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(reboot_task(control, receiver).unwrap());

    // **Reachable.** USB is built and the tasks that serve it are running, so a
    // host can reach this board — and from here a death is an ordinary crash
    // rather than a boot that never came up. This boot stops counting towards
    // the escape however it ends.
    lifeline::alive(LIFELINE);
    UP.store(true, Ordering::Relaxed);

    spawner.spawn(report(boot).unwrap());

    // **Once, not for ever.** The first version of this arm died every six
    // seconds, so the board was a moving target and the next arm could not be
    // flashed onto it. Dying once and then staying up is also the more honest
    // demonstration: recovery is the claim, and a board that dies for ever
    // never shows it recovering.
    if DIE == "late" && boot.cause != lifeline::Cause::Fault {
        // Long enough for the log to have said what boot this is, so a reader
        // sees the sequence rather than a board that reboots silently.
        Timer::after(Duration::from_secs(6)).await;
        log!("dying on purpose, AFTER saying I was up — this must not hand the board over");
        Timer::after(Duration::from_millis(300)).await;
        make_it_fault();
    }
}
