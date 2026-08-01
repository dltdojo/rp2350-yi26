//! Read the BOOTSEL button while your firmware is running.
//!
//! The Pico 2 has no user button. It has exactly one button, BOOTSEL, and
//! exp101 showed what it is for: hold it while plugging in and the ROM
//! bootloader takes over. That is a power-on decision — press BOOTSEL while
//! firmware is running and *nothing happens*, because nothing is looking.
//!
//! This crate looks. It gives a board with no user button a button, with no
//! wiring and no parts.
//!
//! # This is a bigger box of magic than it looks
//!
//! Elsewhere this repository hides awkward machinery behind a labelled
//! one-liner — `rp2350-linker` in exp103, for instance. This crate is the
//! same idea but a much larger box, and pretending otherwise would be
//! dishonest, so here is what is inside.
//!
//! **BOOTSEL is not wired to a GPIO.** To save a pin, it hangs off the QSPI
//! flash chip's chip-select line through a resistor. Pressing it pulls that
//! line low. Reading it therefore means:
//!
//! 1. enable the input buffer on the QSPI SS pad, so the pad voltage can be
//!    read back at all;
//! 2. stop *driving* chip-select, leaving it floating so the button's pull
//!    is what determines the level;
//! 3. wait for the line to settle, read it, and restore chip-select.
//!
//! While chip-select is floating, **the flash chip cannot be talked to** — and
//! on this chip your code is executing straight out of flash. So the read
//! routine must live in RAM, and interrupts must be off for its duration, or
//! an interrupt handler would try to fetch instructions from a flash chip that
//! is not currently answering. That is what [`is_pressed`] does, and why it
//! costs more than reading a GPIO.
//!
//! # The consequences you actually have to live with
//!
//! - **It is not free.** Every call disables interrupts for a few
//!   microseconds. exp106 measures the real number on your board rather than
//!   asking you to take a figure on trust.
//! - **Do not poll it in a tight loop.** Every read is a small hole in your
//!   interrupt latency. Something like every 20 ms is plenty for a button.
//! - **Never call it while writing to flash.** The write would be interrupted
//!   mid-operation.
//! - **Core 1 must not be executing from flash** during the read. These
//!   experiments are single-core, so this does not arise here.
//! - **It still bounces.** This is a mechanical switch; the hack does not
//!   change that.
//!
//! The upside: it is the only zero-hardware button an RP2350 board has, and
//! pressing it at runtime does *not* reboot anything — the ROM only checks it
//! at power-on, so it is safe to use as an ordinary input.
//!
//! # Provenance
//!
//! Derived from the `pico-sk` project's `crates/platform/src/bootsel.rs`
//! (Apache-2.0), where it has run in production as a FIDO2 user-presence
//! button alongside a live USB stack. `embassy-rp` does have a `bootsel`
//! module, but as of 0.10 it is gated behind the `rp2040` feature and does
//! not build for the RP2350 — hence this implementation.

#![no_std]

/// PADS_QSPI, chip-select pad. Bit 6 is IE (input enable); without it set,
/// reading the pad always returns 0 regardless of the actual voltage.
const PADS_QSPI_SS: u32 = 0x4004_0000 + 0x18;
const PADS_QSPI_SS_IE: u32 = 1 << 6;

/// IO_QSPI, chip-select GPIO. STATUS at +0x00, CTRL at +0x04.
const IO_QSPI_SS: u32 = 0x4003_0000 + 0x18;

/// OEOVER occupies bits 15:14 of CTRL; 0b10 means "override output enable to
/// disabled", i.e. stop driving the pin and let it float.
const OEOVER_MASK: u32 = 0xc000;
const OEOVER_DISABLE: u32 = 0x8000;

/// INFROMPAD is bit 17 of GPIO_STATUS: the raw voltage at the pad, before any
/// override logic.
const INFROMPAD_SHIFT: u32 = 17;

/// Returns `true` while the BOOTSEL button is held down.
///
/// Costs a few microseconds with interrupts disabled — see the module docs.
/// Call it at a human-scale rate (every 20 ms or so), not in a tight loop.
pub fn is_pressed() -> bool {
    let orig_ctrl = unsafe { core::ptr::read_volatile((IO_QSPI_SS + 4) as *const u32) };
    let floating_ctrl = (orig_ctrl & !OEOVER_MASK) | OEOVER_DISABLE;
    let orig_pads = unsafe { core::ptr::read_volatile(PADS_QSPI_SS as *const u32) };

    let mut status: u32 = 0;

    // Interrupts off for the whole window: while chip-select floats, no code
    // can be fetched from flash, and an interrupt handler would try to do
    // exactly that.
    cortex_m::interrupt::free(|_| unsafe {
        core::ptr::write_volatile(PADS_QSPI_SS as *mut u32, orig_pads | PADS_QSPI_SS_IE);
        status = read_pad_with_cs_floating(IO_QSPI_SS, orig_ctrl, floating_ctrl);
        core::ptr::write_volatile(PADS_QSPI_SS as *mut u32, orig_pads);
    });

    // BOOTSEL is active-low: pressed pulls the pad down, so 0 means pressed.
    ((status >> INFROMPAD_SHIFT) & 1) == 0
}

/// Floats chip-select, samples GPIO_STATUS, and restores chip-select.
///
/// Lives in RAM (`.data.ram_func`) because it runs while the flash chip is
/// unreachable, and is written in assembly so the compiler cannot slip a call
/// to some helper that happens to live in flash into the middle of it.
///
/// # Safety
///
/// Caller must have interrupts disabled and must ensure nothing else touches
/// flash for the duration.
#[inline(never)]
#[link_section = ".data.ram_func"]
unsafe fn read_pad_with_cs_floating(io_qspi_ss: u32, orig_ctrl: u32, floating_ctrl: u32) -> u32 {
    let status: u32;
    // Long enough for the line to settle once we stop driving it. A pure
    // count-down loop rather than a timer, since this must not call anything.
    let settle: u32 = 1000;

    core::arch::asm!(
        "str {floating}, [{base}, #4]",   // stop driving chip-select
        "2:",                              // settle delay
        "subs {settle}, #1",
        "bne 2b",
        "ldr {status}, [{base}, #0]",     // sample GPIO_STATUS
        "str {orig}, [{base}, #4]",       // drive chip-select again
        base = in(reg) io_qspi_ss,
        floating = in(reg) floating_ctrl,
        orig = in(reg) orig_ctrl,
        settle = inout(reg) settle => _,
        status = out(reg) status,
        options(nostack),
    );

    status
}
