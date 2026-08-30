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
//! # Two shapes, because the tree has two
//!
//! Forty-five experiments here are `USB_IFACE="cdc"` and want nothing else;
//! [`open`] serves them in one call. Twenty-nine add HID, MSC, NCM or a vendor
//! interface to the *same* `Builder`, and they need it back between
//! construction and `build()` — that is [`open_composite`], which hands over a
//! [`Composite`] and builds nothing until [`Composite::finish`] is called.
//!
//! `open` is `open_composite(..).finish(..)`. There is one bring-up, not two.
//!
//! The second shape was not invented in advance. It exists because
//! [exp193](../../experiments/exp193-how-many-doors-fit/) asked how many
//! interfaces fit in one configuration descriptor and could not ask without it
//! — an API shaped for a caller that does not exist is an API nobody has been
//! able to catch being wrong, which is
//! [exp140](../../experiments/exp140-a-checksum-that-passes/)'s subject.
//!
//! # Two budgets, and the console spends half of one
//!
//! [`CONFIG_DESCRIPTOR_BYTES`] is how much descriptor room every interface on
//! this device shares, and the console spends **70 of 256** — measured from the
//! host by [exp193](../../experiments/exp193-how-many-doors-fit/), not claimed
//! here. Run out and `embassy-usb` asserts `"Descriptor buffer full"` inside
//! `Builder`.
//!
//! That is the budget a caller expects. The one that actually bites first is
//! not this crate's at all: **`embassy-usb`'s `MAX_INTERFACE_COUNT` defaults to
//! 4**, and CDC-ACM is two interfaces wearing one IAD, so **opening a console
//! spends half the device's interface budget before the caller adds anything**.
//! exp193 measured a board stopping at five interfaces with 120 descriptor bytes
//! still free.
//!
//! A composite firmware that wants more than two of its own interfaces has to
//! raise it, and it is a Cargo feature on `embassy-usb` rather than anything
//! this crate can do for it. Eight experiments here already do — exp148–exp155
//! and exp161 — and thirty-two others fit under the default without saying so:
//!
//! ```toml
//! embassy-usb = { version = "0.6.0", features = ["max-interface-count-8", "max-handler-count-8"] }
//! ```
//!
//! Both walls are a panic before the board is reachable — no USB, no log, no
//! 1200-baud watcher — so a firmware that might approach either wants
//! [`crates/lifeline`](../../crates/lifeline/) under it. exp193's board reached
//! the bootloader by itself in one second from both, and was reflashed with
//! nobody in the room.
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

/// How many bytes every interface on this device shares.
///
/// 256 is what every CDC-only caller used, and CDC alone spends 70 of it —
/// measured from the host, not claimed by the board. Public because a firmware
/// that adds interfaces is spending against a budget, and a budget nobody can
/// read is one every caller guesses at.
///
/// **This number is a finding waiting to happen, not a considered default.** No
/// composite firmware had ever been built from this crate when it was chosen,
/// so raising it before exp193 measured where 256 runs out would have been
/// picking a number to avoid learning one.
pub const CONFIG_DESCRIPTOR_BYTES: usize = 256;

const DESCRIPTOR_BYTES: usize = CONFIG_DESCRIPTOR_BYTES;
/// The control buffer is 128 rather than the 64 a third of the callers chose:
/// 64 is enough for CDC alone, 128 leaves room for the control transfers a
/// second class brings with it, and the difference is sixty-four bytes of SRAM
/// on a chip with 520 KiB of it.
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

/// A device under construction: the serial console is in it, nothing is built
/// yet, and the `Builder` is still reachable.
///
/// Hold it only for as long as it takes to add interfaces. Nothing is on the
/// bus until [`finish`](Self::finish), so a `Composite` dropped instead of
/// finished is a board that enumerates as nothing at all — which looks exactly
/// like a dead firmware and is the one mistake this shape can still make.
pub struct Composite {
    builder: embassy_usb::Builder<'static, Driver<'static, USB>>,
    class: CdcAcmClass<'static, Driver<'static, USB>>,
}

impl Composite {
    /// The `Builder`, for adding an interface beside the console.
    ///
    /// Everything written through this shares
    /// [`CONFIG_DESCRIPTOR_BYTES`] with the console's own 70.
    pub fn builder(&mut self) -> &mut embassy_usb::Builder<'static, Driver<'static, USB>> {
        &mut self.builder
    }

    /// Build the device and spawn the three tasks that serve the console.
    ///
    /// Consumes `self`, so the `Builder` cannot be reached afterwards — adding
    /// an interface to a device that is already running is not a thing that can
    /// be written here, rather than a thing that is documented as not working.
    pub fn finish(self, spawner: Spawner) {
        let device = self.builder.build();
        let (sender, receiver, control) = self.class.split_with_control();
        spawner.spawn(usb_task(device).unwrap());
        spawner.spawn(log_task(sender).unwrap());
        spawner.spawn(reboot_task(control, receiver).unwrap());
    }
}

/// Begin a device with a serial console on it, and hand back the `Builder`.
///
/// For a firmware that puts something else on the same port. The console is
/// already declared when this returns, so the console's interfaces come first
/// and every later interface is numbered after them — which is what makes a
/// composite firmware's `ttyACM` predictable across builds.
///
/// **Call it once**, and call [`Composite::finish`] on what it returns.
///
/// It must be called *after* whatever this firmware's LED does, and after
/// [`lifeline::begin`](../../crates/lifeline/) if the firmware uses it: this is
/// the first thing in a boot that can hang, and a board that hangs before its
/// LED is up is indistinguishable from a board that never started.
pub fn open_composite(usb: Peri<'static, USB>, cfg: Config) -> Composite {
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
    Composite { builder, class }
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
    open_composite(usb, cfg).finish(spawner);
}
