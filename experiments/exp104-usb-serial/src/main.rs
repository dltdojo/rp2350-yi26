//! exp104 — the board talks back.
//!
//! exp103's blink was mute: it ran, but you could not ask it anything. This
//! firmware brings up a USB CDC-ACM serial port, so the board appears in
//! `lsusb` again (exp101 explained why the blink did not) and prints a line
//! every second that you can read in a terminal.
//!
//! As in exp103, this file IS the walkthrough — every line explains itself.
//! Only what is new since exp103 is commented in depth.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_rp::gpio::{Level, Output};
use embassy_time::{Timer, Instant};
use panic_halt as _;
use rp2350_linker as _; // the labelled magic from exp103: memory map + boot block

// NEW since exp103 ───────────────────────────────────────────────────────────

// `bind_interrupts!` wires a hardware interrupt to the driver that handles it.
// USB is interrupt-driven: the controller raises USBCTRL_IRQ on every packet,
// and this hands those interrupts to embassy-rp's USB driver. Without it the
// USB stack would never be told anything happened.
use embassy_rp::bind_interrupts;
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, InterruptHandler};
// The USB device stack: `Builder` assembles descriptors, `UsbDevice` is the
// running device, `CdcAcmClass` is the "virtual serial port" class.
use embassy_usb::class::cdc_acm::{CdcAcmClass, State};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
// StaticCell hands out `&'static mut` references to buffers, checked at
// runtime to happen only once. The USB stack needs buffers that outlive
// every task, and on a chip with no heap this is how you get them safely.
use static_cell::StaticCell;
// Gives `write_all` on the CDC-ACM sender.
use embedded_io_async::Write;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

/// Runs the USB device state machine forever: enumeration, control transfers,
/// suspend/resume. It must keep running for the port to stay alive, which is
/// why it lives in its own task rather than in `main`'s loop.
#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());

    // Board-specific, as in exp103: the official Pico 2's LED is on GPIO 25.
    // Change it for your board — or ignore it entirely, since the serial port
    // this experiment is actually about does not depend on the LED.
    let mut led = Output::new(p.PIN_25, Level::Low);

    // 1. The USB driver, fed by the interrupt bound above.
    let driver = Driver::new(p.USB, Irqs);

    // 2. What the host will see when it enumerates this device. The VID/PID
    //    pair 1209:0001 belongs to pid.codes, a registry that hands out IDs
    //    for open-source hardware — the honest choice for a learning project
    //    (never ship someone else's vendor ID).
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp104 USB serial");
    config.serial_number = Some("104");
    // CDC-ACM is a two-interface class (control + data). These three bytes
    // tell the host "the interfaces belong together" — without them some
    // hosts bind a driver to only half the device.
    config.device_class = 0xef;
    config.device_sub_class = 0x02;
    config.device_protocol = 0x01;
    config.composite_with_iads = true;

    // 3. Buffers the USB stack keeps for the lifetime of the program: the
    //    descriptors it reports to the host, and scratch space for control
    //    transfers.
    static CONFIG_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; 64]> = StaticCell::new();
    static ACM_STATE: StaticCell<State> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESCRIPTOR.init([0; 256]),
        BOS_DESCRIPTOR.init([0; 256]),
        &mut [], // no Microsoft OS descriptors needed
        CONTROL_BUF.init([0; 64]),
    );

    // 4. Add the serial-port class, then freeze the device: `build()` closes
    //    the descriptor set, so no interface can be added afterwards.
    //    64 is the endpoint packet size — the USB 1.1 maximum for bulk.
    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), 64);
    let usb = builder.build();

    // 5. Hand the device state machine to its own task. From here the host
    //    can enumerate us; `lsusb` will show the board again.
    // (`usb_task(...)` returns a Result because each task has a fixed pool of
    //  instances — unwrap says "we only ever spawn this one".)
    spawner.spawn(usb_task(usb).unwrap());

    // We only print, so keep the sending half and drop the receiving half.
    // (Reading what the host types is a later experiment.)
    let (mut sender, _receiver) = class.split();

    let mut count: u32 = 0;
    loop {
        // Wait until a terminal actually opens the port. Writing to a port
        // nobody has opened would block forever on the first packet — this
        // is why a firmware that prints on boot can look "dead" until you
        // connect.
        sender.wait_connection().await;

        // Blink while connected, so the board still shows a sign of life
        // even if you have no terminal open.
        led.set_high();

        // Format into a fixed-size stack buffer — no heap on this chip.
        let uptime = Instant::now().as_millis();
        let mut line: heapless::String<128> = heapless::String::new();
        let _ = core::fmt::Write::write_fmt(
            &mut line,
            format_args!("exp104: hello #{} — uptime {} ms\r\n", count, uptime),
        );

        // `\r\n`, not `\n`: this is a terminal, and many of them need the
        // carriage return to start the next line at column 0.
        let _ = sender.write_all(line.as_bytes()).await;

        count = count.wrapping_add(1);
        led.set_low();
        Timer::after_millis(1000).await;
    }
}
