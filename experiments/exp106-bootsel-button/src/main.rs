//! exp106 — the button that was there all along.
//!
//! Press BOOTSEL, the LED lights. Release it, the LED goes out. The classic
//! first microcontroller experiment — on a board that has no user button and
//! with nothing plugged into it.
//!
//! The trick lives in `crates/bootsel/src/lib.rs`; read that file to find out
//! what reading this "button" actually costs. This firmware also *measures*
//! that cost and prints it, so the number comes from your board rather than
//! from a README.
//!
//! Only what is new since exp105 is commented in depth.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Instant, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, State};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;

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

/// How often we ask the button whether it is pressed.
///
/// Every check costs a few microseconds with interrupts disabled, so this is a
/// real trade-off rather than a free choice: faster feels more responsive and
/// steals more interrupt latency. 20 ms is far quicker than a finger and still
/// leaves the chip alone 99.9% of the time.
const POLL_INTERVAL_MS: u64 = 20;

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let mut led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp106 BOOTSEL button");
    config.serial_number = Some("106");
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

    let (mut sender, receiver, control) = class.split_with_control();
    spawner.spawn(reboot_task(control, receiver).unwrap());

    // NEW: measure what the button costs, once, before the loop starts.
    //
    // `Instant`/`Duration` are microsecond-resolution here, and a single read
    // is only a few microseconds, so time a batch and divide — the same thing
    // you would do to benchmark anything too fast to measure once.
    const SAMPLES: u32 = 100;
    let t0 = Instant::now();
    for _ in 0..SAMPLES {
        core::hint::black_box(bootsel::is_pressed());
    }
    let per_read_ns = (Instant::now() - t0).as_micros() * 1000 / SAMPLES as u64;

    let mut was_pressed = false;
    let mut presses: u32 = 0;

    loop {
        // NEW: the whole experiment, in one line. Everything else here is
        // scaffolding.
        let pressed = bootsel::is_pressed();

        // Drive the LED directly from the button. No debouncing: while you
        // hold the button the level is steady, and the few milliseconds of
        // contact bounce at each edge are far too short to see.
        if pressed {
            led.set_high();
        } else {
            led.set_low();
        }

        // Report edges over USB serial — but only when a terminal is actually
        // attached (DTR asserted). exp104 measured what happens otherwise: a
        // write into a port nobody drains parks the task indefinitely, and a
        // parked task would stop reading the button. The LED has to keep
        // working whether or not anyone is watching the log, so the log is the
        // part that gets skipped.
        if pressed != was_pressed {
            was_pressed = pressed;
            if pressed {
                presses = presses.wrapping_add(1);
            }

            let mut line: heapless::String<128> = heapless::String::new();
            let _ = core::fmt::Write::write_fmt(
                &mut line,
                format_args!(
                    "exp106: BOOTSEL {} (press #{}, each read costs ~{} ns)\r\n",
                    if pressed { "DOWN" } else { "up  " },
                    presses,
                    per_read_ns
                ),
            );
            if sender.dtr() {
                let _ = sender.write_packet(line.as_bytes()).await;
            }
        }

        Timer::after_millis(POLL_INTERVAL_MS).await;
    }
}
