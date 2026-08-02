//! exp122 — an interface nobody claims.
//!
//! Every USB interface so far has had a **class**: CDC-ACM in exp104, HID in
//! exp121. A class is a promise about behaviour, and an operating system that
//! recognises it loads a driver and takes the interface. That is why
//! `/dev/ttyACM0` exists, and it is also why exp116 has to run `yi26 detach`
//! before a browser can have the port.
//!
//! This one declares class `0xFF` — **vendor specific**, which is USB for *no
//! promise at all*. No driver knows what to do with it, so no driver claims
//! it, so anything in userspace can. That is not a gap in the design; on this
//! track it is the whole point.
//!
//! # The demonstration is two owners at once
//!
//! exp116 taught that an interface has exactly one owner, and paid for it: a
//! browser holding the CDC pair means no `/dev/ttyACM0`, so the log stops
//! being readable by every ordinary tool at the moment you most want it.
//!
//! Here there is nothing to trade. The kernel keeps the CDC pair, the serial
//! port stays, the log keeps flowing — and at the same time something else
//! claims the vendor interface and talks to it. Both, simultaneously, with no
//! detaching and nothing given up.
//!
//! # What it does with the bytes
//!
//! Echoes them, uppercased. Uppercasing rather than a plain echo for one
//! reason: a plain echo cannot distinguish a firmware that received and
//! returned your bytes from a host stack that looped them back somewhere
//! below. If what comes back is changed, and changed the way this code says
//! it changes them, the round trip really happened.
//!
//! # What this does not do
//!
//! Windows. A vendor-specific interface there needs to be bound to WinUSB,
//! which needs Microsoft OS 2.0 descriptors in the firmware — a BOS platform
//! capability the host reads at enumeration. `embassy-usb` can emit them and
//! this firmware does not, because this repository has no Windows machine to
//! check the result on and does not publish claims it cannot check.
//!
//! On Linux and Android nothing is needed: an unclaimed interface is simply
//! available.

#![no_std]
#![no_main]

use core::fmt::Write as _;
use core::sync::atomic::{AtomicU32, Ordering};

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, Endpoint, InterruptHandler, Out, In};
use embassy_time::{Duration, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::driver::{Endpoint as _, EndpointIn, EndpointOut};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

const PACKET: usize = 64;
const ROW: usize = 16;
const IDLE_REPORT: Duration = Duration::from_secs(5);

/// Vendor specific. USB's way of saying "this interface makes no promise about
/// how it behaves", which is exactly why no driver binds to it.
const CLASS_VENDOR: u8 = 0xFF;

/// Subclass and protocol are ours to choose and mean nothing to anyone else.
/// Zeroes, and the fact that they *could* be anything is the point: without a
/// class there is no specification to be compatible with.
const SUBCLASS_NONE: u8 = 0x00;
const PROTOCOL_NONE: u8 = 0x00;

static PACKETS: AtomicU32 = AtomicU32::new(0);
static BYTES: AtomicU32 = AtomicU32::new(0);
static ECHOES: AtomicU32 = AtomicU32::new(0);

struct Hex<'a>(&'a [u8]);

impl core::fmt::Display for Hex<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        for i in 0..ROW {
            match self.0.get(i) {
                Some(b) => write!(f, "{:02x} ", b)?,
                None => f.write_str("   ")?,
            }
        }
        Ok(())
    }
}

struct Printable<'a>(&'a [u8]);

impl core::fmt::Display for Printable<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        for &b in self.0 {
            f.write_char(if (0x20..0x7f).contains(&b) { b as char } else { '.' })?;
        }
        Ok(())
    }
}

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

/// exp118's loop, unchanged. It owns the CDC `Receiver`, so it does both of
/// the jobs that half makes possible.
#[embassy_executor::task]
async fn console_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut buf = [0u8; PACKET];

    loop {
        match select(control.control_changed(), receiver.read_packet(&mut buf)).await {
            Either::First(()) => {
                let rate = receiver.line_coding().data_rate();
                log!(
                    "control: {} baud, DTR {}",
                    rate,
                    if receiver.dtr() { "on" } else { "off" }
                );
                usb_reboot::reboot_if_requested(rate).await;
            }
            Either::Second(Ok(0)) => log!("zero-length packet — not counted, nobody sent it"),
            Either::Second(Ok(n)) => {
                let data = &buf[..n];
                let seq = PACKETS.fetch_add(1, Ordering::Relaxed) + 1;
                BYTES.fetch_add(n as u32, Ordering::Relaxed);
                log!("in #{}: {} bytes", seq, n);
                for (i, row) in data.chunks(ROW).enumerate() {
                    log!("  {:04x}  {} {}", i * ROW, Hex(row), Printable(row));
                }
            }
            Either::Second(Err(_)) => {
                receiver.wait_connection().await;
                log!("interface enabled again — listening");
            }
        }
    }
}

/// The experiment. Two raw bulk endpoints and nothing between them and the
/// wire.
///
/// No class means no class driver, which also means no library: there is no
/// `VendorClass::new` to call and no `read_packet` helper. What arrives is
/// what the endpoint gives you, and what goes back is what you write. That is
/// less convenient than CDC-ACM and considerably easier to reason about,
/// because there is nothing in between to have an opinion.
#[embassy_executor::task]
async fn echo_task(
    mut read_ep: Endpoint<'static, USB, Out>,
    mut write_ep: Endpoint<'static, USB, In>,
) -> ! {
    let mut buf = [0u8; PACKET];

    loop {
        // Nothing has claimed this endpoint until a host program does, so this
        // waits for the interface to be enabled and then for bytes.
        read_ep.wait_enabled().await;

        loop {
            let n = match read_ep.read(&mut buf).await {
                Ok(n) => n,
                Err(_) => break, // the host went away; wait for it to come back
            };

            // Uppercased, not echoed verbatim. A plain echo cannot tell a
            // firmware that handled your bytes from a host stack that looped
            // them back below — but a change that only this code makes can.
            for b in &mut buf[..n] {
                b.make_ascii_uppercase();
            }

            let seq = ECHOES.fetch_add(1, Ordering::Relaxed) + 1;
            log!("echo #{}: {} bytes back, uppercased", seq, n);

            if write_ep.write(&buf[..n]).await.is_err() {
                break;
            }
        }
    }
}

#[embassy_executor::task]
async fn idle_task() -> ! {
    loop {
        Timer::after(IDLE_REPORT).await;
        let echoes = ECHOES.load(Ordering::Relaxed);
        if echoes == 0 {
            log!("idle: vendor interface waiting — try  yi26 echo hello");
        } else {
            log!(
                "idle: {} echo{} on the vendor interface, {} CDC packets",
                echoes,
                if echoes == 1 { "" } else { "es" },
                PACKETS.load(Ordering::Relaxed)
            );
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
    config.product = Some("exp122 vendor bulk");
    config.serial_number = Some("122");
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

    // CDC first, so the interface numbers every other experiment found stay
    // put. exp121 showed both orders and showed that nothing here depends on
    // the answer.
    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), PACKET as u16);

    // And the raw one, built by hand because there is no class to build it for
    // us. Function, interface, alternate setting, two endpoints — this is what
    // `CdcAcmClass::new` and `HidWriter::new` have been doing all along.
    let (read_ep, write_ep) = {
        let mut function = builder.function(CLASS_VENDOR, SUBCLASS_NONE, PROTOCOL_NONE);
        let mut interface = function.interface();
        let mut alt = interface.alt_setting(CLASS_VENDOR, SUBCLASS_NONE, PROTOCOL_NONE, None);
        // OUT first so the addresses read in the same order as the transfers.
        let out = alt.endpoint_bulk_out(None, PACKET as u16);
        let in_ = alt.endpoint_bulk_in(None, PACKET as u16);
        (out, in_)
    };

    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(console_task(control, receiver).unwrap());
    spawner.spawn(echo_task(read_ep, write_ep).unwrap());
    spawner.spawn(idle_task().unwrap());

    log!("exp122 up. One interface the kernel drives, one it will not touch.");

    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
