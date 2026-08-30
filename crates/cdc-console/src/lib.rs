// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 rp2350-yi26 contributors

//! One call that puts a serial console on the bus and leaves nothing half-wired.
//!
//! # What this replaces, counted
//!
//! Seventy-five experiments in this repository build a CDC-ACM port, and they
//! build it the same way: the same vendor and product id, the same four
//! `StaticCell`s, the same `Builder`, the same `split_with_control`, and the
//! same three tasks spawned afterwards. Twenty-two lines, copied, with the
//! product string changed.
//!
//! Line count is not the argument. [exp190](../../experiments/exp190-the-board-that-brings-itself-back/)
//! counted what one round on the authenticator road cost — four trips to a
//! bench — and named the three deaths:
//!
//! > a `StaticCell` claimed twice, an interface declared with no task servicing
//! > it, and `SecretKey::from_slice` on thirty-two zero bytes
//!
//! **Two of those three live in the twenty-two lines.** A cell claimed twice is
//! a panic at boot, before USB, so the board comes up mute and needs a person.
//! An interface with nothing servicing it enumerates, and then the host waits
//! for a device that will never answer — which reads exactly like a bad cable.
//! Neither is exotic and neither is interesting, and both are structurally
//! impossible here: the cells are private to this crate and initialised once,
//! and there is no way to obtain the port without its tasks already running,
//! because [`open`] does both or neither.
//!
//! # The drift it also settles
//!
//! Seventy-one of the seventy-five set `composite_with_iads`; four do not.
//! exp157 and exp180 are both plain `USB_IFACE="cdc"` firmwares and they
//! disagree, with nothing in either README explaining why. That is not two
//! decisions, it is one decision made seventy-five times and remembered
//! seventy-one. This crate sets it, which is the answer that keeps working when
//! a second interface is added later: CDC-ACM is two interfaces wearing one
//! coat, and the association descriptor is what tells a host so.
//!
//! # What is deliberately not here
//!
//! Seventeen experiments add HID, MSC or a vendor interface to the same
//! `Builder`, and they need it back between construction and `build()`. There
//! is no method for that yet, **on purpose**: an API shaped for a caller that
//! does not exist yet is an API nobody has ever been able to catch being wrong,
//! and this repository has a name for that ([exp140](../../experiments/exp140-a-checksum-that-passes/)).
//! The first composite experiment that wants it is what should decide its
//! shape, and adding it then breaks nothing here.
//!
//! # Using it
//!
//! ```ignore
//! cdc_console::open(spawner, p.USB, cdc_console::Config {
//!     product: "exp190 the board that brings itself back",
//!     serial: "190",
//! });
//! ```
//!
//! After it returns, `usb_log::log!` reaches a host and the 1200-baud touch
//! reboots the board. Nothing else is left to wire.

#![no_std]

use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::peripherals::USB;
use embassy_rp::Peri;
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::UsbDevice;
use static_cell::StaticCell;

/// The USB driver these experiments use, re-exported so a caller needs one
/// import rather than three.
pub use usb_reboot::UsbDriver;

// The USB interrupt, bound here.
//
// It lives in this crate rather than in each experiment because there is
// exactly one right answer and no experiment has ever wanted a different one.
// An experiment that binds *other* interrupts declares its own
// `bind_interrupts!` struct for those; the two do not collide as long as
// nobody else claims `USBCTRL_IRQ`, and nobody has a reason to.
//
// A `///` here is silently dropped — rustdoc does not document macro
// invocations — so this is a plain comment on purpose.
bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

/// The two things that differ between one experiment and the next.
///
/// Everything else — the vendor and product id, the manufacturer, the power
/// draw, the endpoint-zero packet size — is identical across all seventy-five
/// callers this crate was read out of, so it is not offered as a choice. A
/// knob nobody turns is a knob somebody eventually turns by accident.
pub struct Config {
    /// What the host shows in its device list. By convention here: the
    /// experiment number and its title, so `lsusb` names the firmware.
    pub product: &'static str,
    /// The experiment number as a string, e.g. `"190"`. `yi26` matches on it
    /// to tell one board's firmware from another's.
    pub serial: &'static str,
}

/// pid.codes' free vendor id and this repository's first product under it.
///
/// Identical in all seventy-five, so it is a constant rather than a field.
const VID: u16 = 0x1209;
const PID: u16 = 0x0001;

/// The descriptor buffers.
///
/// 256/256 is what every CDC-only caller used. The control buffer is 128 rather
/// than the 64 a third of them chose: 64 is enough for CDC alone, 128 is enough
/// for CDC plus whatever the composite path will one day put beside it, and the
/// difference is sixty-four bytes of SRAM on a chip with 520 KiB of it.
const DESCRIPTOR_BYTES: usize = 256;
const CONTROL_BYTES: usize = 128;

/// The CDC-ACM bulk endpoint size. Full-speed USB permits 8, 16, 32 or 64, and
/// every caller chose the largest.
const PACKET: u16 = 64;

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, UsbDriver>) -> ! {
    usb_log::run(sender).await
}

#[embassy_executor::task]
async fn reboot_task(control: ControlChanged<'static>, receiver: Receiver<'static, UsbDriver>) -> ! {
    usb_reboot::watch(control, receiver).await
}

/// Put a serial console on the bus and spawn everything that serves it.
///
/// Returns once the device is running: the log has somewhere to go and the
/// 1200-baud touch works. It does not return a handle, because a CDC-only
/// firmware has nothing left to hold — the sender belongs to the log task and
/// the receiver to the reboot watcher, which is precisely the arrangement
/// [`usb_reboot::watch`] documents as the reliable one.
///
/// **Call it once.** Calling it twice panics inside `StaticCell` at the second
/// call, which is the same failure as claiming a cell twice by hand — except
/// that here it takes a second `open` to do it, and there is never a reason to
/// write one.
///
/// It must be called *after* whatever this firmware's LED does, and after
/// [`lifeline::begin`](../../crates/lifeline/) if the firmware uses it: this is
/// the first thing in a boot that can hang, and a board that hangs before its
/// LED is up is indistinguishable from a board that never started.
pub fn open(spawner: Spawner, usb: Peri<'static, USB>, cfg: Config) {
    static CONFIG_DESC: StaticCell<[u8; DESCRIPTOR_BYTES]> = StaticCell::new();
    static BOS_DESC: StaticCell<[u8; DESCRIPTOR_BYTES]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; CONTROL_BYTES]> = StaticCell::new();
    static ACM_STATE: StaticCell<State> = StaticCell::new();

    let driver = Driver::new(usb, Irqs);

    let mut config = embassy_usb::Config::new(VID, PID);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(cfg.product);
    config.serial_number = Some(cfg.serial);
    config.max_power = 100;
    config.max_packet_size_0 = 64;
    // Miscellaneous / common class / interface association. Without these three
    // a host is entitled to read the first interface's class as the device's
    // own, and a second interface added later is a device that enumerates
    // differently depending on which one the descriptor happens to list first.
    config.device_class = 0xef;
    config.device_sub_class = 0x02;
    config.device_protocol = 0x01;
    config.composite_with_iads = true;

    let mut builder = embassy_usb::Builder::new(
        driver,
        config,
        CONFIG_DESC.init([0; DESCRIPTOR_BYTES]),
        BOS_DESC.init([0; DESCRIPTOR_BYTES]),
        &mut [],
        CONTROL_BUF.init([0; CONTROL_BYTES]),
    );

    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), PACKET);
    let device = builder.build();

    // Built and served in one place. The interface cannot exist without the
    // task that answers for it, which is the second of exp190's three deaths
    // spent for good.
    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(usb_task(device).unwrap());
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(reboot_task(control, receiver).unwrap());
}
