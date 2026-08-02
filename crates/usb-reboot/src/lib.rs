//! Retire the BOOTSEL button: let the host reboot the board into its USB
//! bootloader by opening the serial port at **1200 baud**.
//!
//! This is the *1200-baud touch*, a convention Arduino popularised. Nothing
//! is actually transmitted at 1200 baud — the baud rate is being used as a
//! signal. The host sets it, the firmware notices, and the firmware jumps
//! into the ROM bootloader itself. The result is a board that can be
//! reflashed without anyone touching a button.
//!
//! This crate is shared by every experiment that wants the behaviour, so
//! there is one copy of it rather than one per experiment.
//!
//! # The catch, and why it is a Cargo feature
//!
//! Baud rate is not a secret handshake. *Any* program that opens your serial
//! port at 1200 baud reboots your board — an old terminal emulator with 1200
//! in its saved settings, a modem script, a colleague's tool probing serial
//! devices. Half the time that is a delight (your flashing tool triggers it
//! deliberately) and half the time it is a mystery ("why does my board keep
//! disappearing?").
//!
//! So the decision is yours, not this crate's. The `auto-reboot` feature is
//! **on by default** because the convenience is the point. Experiments
//! re-export it as their own feature, so turning it off is a build flag
//! rather than an edit:
//!
//! ```sh
//! cargo build --release --no-default-features
//! ```
//!
//! With it off, [`watch`] still consumes the events but never reboots — so
//! your code does not change shape, only its behaviour, and you can flip
//! between the two to feel the difference. Either way the firmware records
//! which it was: see [`BUILD_MARKER`], which `experiments/audit.sh` reads.

#![no_std]

use embassy_rp::peripherals::USB;
use embassy_rp::usb::Driver;
use embassy_time::Timer;
use embassy_usb::class::cdc_acm::{ControlChanged, Receiver};

/// The USB driver type these experiments use. Spelling it out here keeps the
/// call site short.
pub type UsbDriver = Driver<'static, USB>;

/// The baud rate that means "reboot into the bootloader". Not a real speed —
/// a signal.
pub const MAGIC_BAUD: u32 = 1200;

/// A plain-text marker stamped into the firmware image recording how this
/// crate was compiled.
///
/// Without it, nothing outside the build could tell an auto-reboot firmware
/// from one built with the feature off: the two differ only by code that is
/// no longer there. Reading `Cargo.toml` does not help either — it describes
/// the *default* build, not the flags whoever produced the `.uf2` actually
/// used.
///
/// So the binary carries the answer itself, in a form `strings` can read:
///
/// ```sh
/// strings firmware.uf2 | grep yi26-cfg
/// ```
///
/// `#[used]` and an explicit section keep the linker from discarding it —
/// nothing in the program ever reads this string, which normally makes it
/// dead weight to be optimised away. `experiments/audit.sh` reports it.
#[used]
#[unsafe(link_section = ".rodata.yi26_build_marker")]
pub static BUILD_MARKER: [u8; 24] = *if cfg!(feature = "auto-reboot") {
    b"yi26-cfg:auto-reboot=on "
} else {
    b"yi26-cfg:auto-reboot=off"
};

/// Watches the host's serial-port settings and reboots into the USB
/// bootloader when it sees [`MAGIC_BAUD`]. Never returns.
///
/// Spawn this in its own task. That is not decoration: a task that is busy
/// writing to the host can be parked mid-write when nothing is draining the
/// port (exp104 measured exactly that), and a parked task cannot notice
/// anything. Watching from a separate task is what makes the reboot reliable
/// even when the printing side is stuck.
///
/// It takes the `Receiver` because that is where `line_coding()` lives, and
/// because an experiment that only prints has no other use for it — the half
/// exp104 dropped on the floor now has a job.
pub async fn watch(control: ControlChanged<'static>, receiver: Receiver<'static, UsbDriver>) -> ! {
    loop {
        // Sleeps until the host changes DTR, RTS, or the line coding. No
        // polling, so this costs nothing while idle.
        control.control_changed().await;

        reboot_if_requested(receiver.line_coding().data_rate()).await;
    }
}

/// Reboots into the USB bootloader if `data_rate` is [`MAGIC_BAUD`]. Returns
/// immediately for any other rate, and never returns when it does reboot.
///
/// [`watch`] is this function plus a loop, and is what an experiment that only
/// prints should use. This half is public for the case [`watch`] cannot serve:
/// a firmware that also wants to **read** the OUT endpoint.
///
/// The obstacle is ownership, not style. `line_coding()` can be read from the
/// `Sender`, the `Receiver` or the class itself, but not from
/// `ControlChanged` — and `read_packet` needs `&mut Receiver`. So the task
/// that reads what the host sends is necessarily the same task that can see
/// the host's baud rate, and it has to wait on both at once. Handing it this
/// function means the delicate part below exists once in this repository
/// rather than once per experiment that wants to listen. exp118 is the first
/// caller.
pub async fn reboot_if_requested(data_rate: u32) {
    if data_rate != MAGIC_BAUD {
        return;
    }

    #[cfg(feature = "auto-reboot")]
    {
        // Let the host finish the control transfer that just woke us.
        //
        // This delay is not politeness, it is the difference between working
        // and not. `control_changed()` fires while the host's SET_LINE_CODING
        // request is still in flight — its status stage has not completed.
        // Resetting the chip at that instant tears USB down mid-transfer: the
        // host's `stty` blocks forever waiting for a status stage that will
        // never come, and the reboot does not complete either, leaving a board
        // that is enumerated but dead. Measured, not theorised — see exp105's
        // README.
        //
        // 250 ms is far more than a control transfer needs and still
        // imperceptible to a person.
        Timer::after_millis(250).await;

        // Into the ROM bootloader. The first argument can flash a GPIO as a
        // USB-activity light; the second can hide the mass storage or PICOBOOT
        // interfaces. 0, 0 = the plain BOOTSEL behaviour exp101 met.
        //
        // This call does not return: the chip resets, the serial port
        // disappears, and the RP2350 boot drive appears in its place.
        embassy_rp::rom_data::reset_to_usb_boot(0, 0);
    }

    // With the feature off we deliberately do nothing. The host still got its
    // 1200-baud setting; the board simply ignores the hint.
}
