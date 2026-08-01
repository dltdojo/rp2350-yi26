//! exp105 — retire the BOOTSEL button.
//!
//! This is exp104's firmware plus **one spawned task**. That task watches the
//! serial port's settings and, when the host opens it at 1200 baud, reboots
//! the chip into its USB bootloader — so reflashing no longer needs anyone to
//! hold a button while replugging the cable.
//!
//! The interesting code is not here. It is in
//! `crates/usb-reboot/src/lib.rs`, shared by every experiment that wants this
//! behaviour, and that file explains both the trick and its downside. Read it
//! next.
//!
//! Only what is new since exp104 is commented below.

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
use embedded_io_async::Write;
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

/// NEW: the 1200-baud watcher, running independently of everything else.
///
/// The body is one call into the shared crate. A task has to name concrete
/// types, which a library cannot do for us — so the wrapper lives here and
/// the logic lives there.
#[embassy_executor::task]
async fn reboot_task(
    control: ControlChanged<'static>,
    receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    usb_reboot::watch(control, receiver).await
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());

    // Board-specific, as in exp103. Not what this experiment is about.
    let mut led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp105 USB reboot");
    config.serial_number = Some("105");
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

    // NEW: `split_with_control` instead of `split`. The third handle is what
    // lets a task *sleep* until the host changes the port's settings, rather
    // than polling for it.
    //
    // exp104 dropped the receiver; here it goes to the watcher, because
    // `line_coding()` — the thing that reports 1200 baud — lives on it.
    let (mut sender, receiver, control) = class.split_with_control();
    spawner.spawn(reboot_task(control, receiver).unwrap());

    let mut count: u32 = 0;
    loop {
        sender.wait_connection().await;
        led.set_high();

        let mut line: heapless::String<128> = heapless::String::new();
        let _ = core::fmt::Write::write_fmt(
            &mut line,
            format_args!(
                "exp105: hello #{} — uptime {} ms (touch me at 1200 baud)\r\n",
                count,
                Instant::now().as_millis()
            ),
        );
        let _ = sender.write_all(line.as_bytes()).await;

        count = count.wrapping_add(1);
        led.set_low();
        Timer::after_millis(1000).await;
    }
}
