//! exp107 — three tasks, one log.
//!
//! Every experiment so far did one thing at a time, and reported it by
//! writing to USB from the same loop that did the work. That works until two
//! things want to report at once, or until the host stops reading — exp104
//! measured a 21-second stall, and exp106 had to skip its log to keep a
//! button responsive.
//!
//! Here, three independent tasks all log freely:
//!
//! - a **heartbeat** that flashes the LED once a second (an output),
//! - a **button watcher** polling BOOTSEL every 20 ms (an input),
//! - a **scheduler probe** measuring how late its own wakeups are (something
//!   with no physical existence at all — the kind of thing you can never see
//!   by blinking).
//!
//! None of them knows the others exist, none owns the USB endpoint, and none
//! of them can be stalled by the host. That is the entire experiment.
//!
//! The machinery is in `crates/usb-log/src/lib.rs`. Read it — this file is
//! mostly three small loops that call `log!`.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
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

/// NEW: the only task permitted to touch the USB sender.
///
/// Everything else in the program logs through a queue. Handing the `Sender`
/// to exactly one task is what makes that safe — there is no lock to forget
/// and no way for two tasks to interleave half-written lines.
#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_log::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

/// NEW: an input, reporting to the log instead of to an LED.
///
/// Compare with exp106, which had to gate its printing behind `dtr()` so an
/// unread port could not park the button. There is nothing to gate here:
/// `log!` returns immediately whatever the host is doing, so this loop keeps
/// its 20 ms rhythm unconditionally.
///
/// Note it takes no arguments at all. `bootsel::is_pressed()` reads hardware
/// registers directly rather than owning a peripheral, so any task can call
/// it — convenient, and a reminder of how far outside the type system that
/// particular trick lives.
#[embassy_executor::task]
async fn button_task() -> ! {
    let mut was_pressed = false;
    let mut presses: u32 = 0;

    loop {
        let pressed = bootsel::is_pressed();
        if pressed != was_pressed {
            was_pressed = pressed;
            if pressed {
                presses += 1;
                log!("BOOTSEL down  (press #{})", presses);
            } else {
                log!("BOOTSEL up    (press #{})", presses);
            }
        }
        Timer::after_millis(20).await;
    }
}

/// NEW: a measurement that has no physical form.
///
/// This task asks to be woken every 100 ms and then measures how late that
/// wakeup actually was. Lateness is the executor's honesty check: with
/// everything cooperating it is tens of microseconds, and anything that hogs
/// the CPU — a long computation, a blocking write, a pile of interrupts —
/// shows up here as a spike.
///
/// You cannot blink this. It is exactly the kind of thing a serial log is
/// for.
#[embassy_executor::task]
async fn scheduler_probe() -> ! {
    const TICK: Duration = Duration::from_millis(100);
    const REPORT_EVERY: u32 = 10;

    // Absolute deadlines, not `after_millis`. Sleeping "100 ms from now"
    // accumulates every wakeup's lateness into the next deadline; sleeping
    // "until t0 + n*100 ms" does not, so the drift being measured is the
    // executor's and not this loop's own.
    let mut next = Instant::now();
    let mut ticks: u32 = 0;
    let mut worst_us: u64 = 0;

    loop {
        next += TICK;
        Timer::at(next).await;

        let late_us = (Instant::now() - next).as_micros();
        if late_us > worst_us {
            worst_us = late_us;
        }

        ticks += 1;
        if ticks % REPORT_EVERY == 0 {
            log!("scheduler: {} wakeups, worst lateness {} us", ticks, worst_us);
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
    config.product = Some("exp107 debug logging");
    config.serial_number = Some("107");
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

    // The three halves go to three different tasks and nowhere else.
    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(reboot_task(control, receiver).unwrap());
    spawner.spawn(log_task(sender).unwrap());

    // Logging is available from here on. These lines are queued long before
    // any host opens the port — the log survives being written to while
    // nobody is listening, which is the whole point.
    log!("exp107 up. Queue holds {} lines.", usb_log::QUEUE_DEPTH);
    log!("Nothing has been read from this port yet, and nothing cares.");

    spawner.spawn(button_task().unwrap());
    spawner.spawn(scheduler_probe().unwrap());

    // The heartbeat. Its job is to prove liveness with no host involved: if
    // the LED keeps flashing while the log is stalled, the stall was contained
    // to the log — which is the claim this experiment has to back up.
    let mut seq: u32 = 0;
    loop {
        led.set_high();
        Timer::after_millis(50).await;
        led.set_low();

        seq += 1;
        log!("heartbeat #{} (LED flashed)", seq);

        Timer::after_millis(950).await;
    }
}
