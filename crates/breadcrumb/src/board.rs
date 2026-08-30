// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 rp2350-yi26 contributors

//! The half that needs a chip.
//!
//! `WATCHDOG.SCRATCH0`-`SCRATCH3` in, `WATCHDOG.SCRATCH0`-`SCRATCH3` out. Every
//! decision about what those words mean is in the parent module, where
//! `cargo test` can reach it.

use embassy_rp::pac;

use super::{
    interpret, tally_of, with_finished, with_mark, with_step, with_tally, Note, Scratch, MAGIC,
};


/// Read the note, fold the previous boot into the history, and start this one.
///
/// **Call this first, before anything else in `main`** — before
/// `embassy_rp::init`, before the USB stack, before any peripheral. Not
/// superstition: anything that resets a peripheral or takes a fault before this
/// runs destroys the only record of why the last boot ended.
///
/// It clears `WATCHDOG.REASON` on the way through, so the next boot's reading of
/// it describes the next death and not this one.
pub fn read() -> Note {
    let wd = pac::WATCHDOG;

    // Disarm FIRST, unconditionally, before reading anything.
    //
    // "Stop calling `arm`" is not the same as "the watchdog is off", and the
    // difference cost a board. A watchdog left enabled by the boot that died is
    // still enabled in the boot that comes back, and it will cut that boot down
    // before USB finishes enumerating — which looks exactly like a firmware that
    // never started, and leaves nothing able to reflash it.
    //
    // So a boot can never inherit an armed watchdog. Arming is something a run
    // does deliberately, after it has reported, and it starts from off.
    wd.ctrl().modify(|w| w.set_enable(false));

    // REASON tells a hang from a fault. It does NOT decide whether this note is
    // ours: the 1200-baud reflash touch reboots through the watchdog, so REASON
    // says "watchdog" on the first boot of a newly flashed firmware, which is
    // precisely the boot that must not inherit anything.
    let reason = wd.reason().read();
    let forced = reason.force();
    wd.reason().write_value(pac::watchdog::regs::Reason(0));

    // The token is consumed before the fold and not after it, so a reset landing
    // in the middle of this cannot leave a note that gets inherited twice.
    let s0 = wd.scratch0().read();
    wd.scratch0().write_value(0);

    let before =
        Scratch { s0, s1: wd.scratch1().read(), s2: wd.scratch2().read(), s3: wd.scratch3().read() };
    let (note, after) = interpret(before, forced);

    wd.scratch1().write_value(after.s1);
    wd.scratch2().write_value(after.s2);
    wd.scratch3().write_value(after.s3);
    note
}

/// Say which step is about to run.
///
/// **Before it runs, never after.** The number that survives has to name the
/// step that did not come back; a number written afterwards names the last one
/// that did, which is the same information the LED already had.
///
/// Steps count from 1. Step 0 means "between steps" and is not reportable.
pub fn step(n: u8) {
    let wd = pac::WATCHDOG;
    wd.scratch1().write_value(with_step(wd.scratch1().read(), n));
}

/// Read the caller's tally. See [`STEP_TALLY`].
pub fn tally() -> u8 {
    tally_of(pac::WATCHDOG.scratch1().read())
}

/// Write the caller's tally, saturating at [`TALLY_MAX`].
pub fn set_tally(n: u8) {
    let wd = pac::WATCHDOG;
    wd.scratch1().write_value(with_tally(wd.scratch1().read(), n));
}

/// The per-step outcomes as they stand **right now**.
///
/// [`Note`] is a snapshot taken at boot, so a report built from it is stale the
/// moment this boot marks anything — and a run whose last act is to mark a step
/// will report that step as never attempted. Measured, in exp159's first run,
/// where the final line said *not reached* about the candidate it had just
/// finished.
pub fn steps_now() -> u32 {
    pac::WATCHDOG.scratch2().read()
}

/// Record what became of a step that **survived**, with the firmware's own
/// meaning: [`SURVIVED_A`] or [`SURVIVED_B`].
///
/// A step that dies is marked by [`read`] on the way back up. A step that lives
/// has to say so, or the next boot cannot tell "already tried, and it worked"
/// from "not tried yet" and will attempt it again forever.
pub fn mark(n: u8, outcome: u8) {
    let wd = pac::WATCHDOG;
    wd.scratch2().write_value(with_mark(wd.scratch2().read(), n, outcome));
}

/// Say that the sequence finished without dying.
///
/// Without this every completed boot looks like a boot that died in whatever
/// step it ran last, and a report that cannot say "nothing went wrong" is a
/// report whose failures mean nothing.
pub fn finished() {
    let wd = pac::WATCHDOG;
    wd.scratch1().write_value(with_finished(wd.scratch1().read()));
}

/// Start the watchdog. From here a hang is a reboot.
///
/// `timeout_us` has to be longer than the slowest step that is expected to
/// succeed, or the harness reports a death that never happened.
pub fn arm(timeout_us: u32) {
    select_reset_targets();
    let wd = pac::WATCHDOG;
    // Hand the token forward: from here, a death is ours to report.
    wd.scratch0().write_value(MAGIC);
    wd.ctrl().modify(|w| w.set_enable(false));
    wd.load().write(|w| w.set_load(timeout_us.min(0x00ff_ffff)));
    wd.ctrl().modify(|w| w.set_enable(true));
}

/// Keep it quiet for another `timeout_us`.
pub fn feed(timeout_us: u32) {
    pac::WATCHDOG.load().write(|w| w.set_load(timeout_us.min(0x00ff_ffff)));
}

/// Stop the watchdog, and withdraw the handoff token.
///
/// Both halves matter. Stopping the watchdog means nothing after this reboots
/// the board; clearing the token means that if something else does, the next
/// boot knows the note is not a continuation of anything.
pub fn disarm() {
    pac::WATCHDOG.ctrl().modify(|w| w.set_enable(false));
    pac::WATCHDOG.scratch0().write_value(0);
}

/// Reboot **now**, and let the note say what kind of reboot it was.
///
/// One function and not two, because the classification is not in the caller's
/// hands and should not look as if it were: [`read`] asks whether a step was in
/// progress. Called from a fault handler, with [`step`] set, this is recorded as
/// a **fault**. Called after [`finished`], it is recorded as a boot that
/// **completed** and chose to go round again.
///
/// Written to survive a fault handler: no HAL, no executor, no interrupts, no
/// allocation, because those are exactly what is no longer trustworthy at that
/// point. It does not return.
///
/// Simply hanging would also reboot, once the watchdog ran out — and would be
/// recorded as a **hang**. So the distinction between *it stopped* and *it
/// faulted* is bought by a fault handler calling this instead of parking.
pub fn reboot() -> ! {
    select_reset_targets();
    let wd = pac::WATCHDOG;
    wd.scratch0().write_value(MAGIC);

    // Load a short timeout BEFORE forcing the reset, and that order is the
    // whole point.
    //
    // `CTRL.TRIGGER` forcing a reset from inside a fault handler is the fast
    // path and it is the one that had never been measured. A timeout reset had
    // been — five of them in a row, on this part. So the timeout is armed first
    // and acts as the fallback: if TRIGGER turns out to do nothing here, this
    // still brings the board home a fifth of a second later.
    //
    // The failure is then **visible instead of silent**: the next boot reads
    // `REASON.TIMER` rather than `REASON.FORCE` and reports the death as a hang
    // where a fault was expected. A wrong label in a log is recoverable. A board
    // that never comes back is a walk to a bench.
    wd.load().write(|w| w.set_load(200_000));
    wd.ctrl().modify(|w| {
        w.set_pause_dbg0(false);
        w.set_pause_dbg1(false);
        w.set_pause_jtag(false);
        w.set_enable(true);
    });
    wd.ctrl().modify(|w| w.set_trigger(true));
    loop {
        cortex_m_nop();
    }
}

/// What the watchdog is allowed to reset.
///
/// **This is `embassy-rp`'s mask, kept because it is the one that was
/// measured**, and that sentence is the whole point of this comment.
///
/// A spike run before this crate existed armed the watchdog with exactly this
/// value and was reset by it five times in a row, on an RP2350, coming back
/// healthy and reflashable every time. That is evidence.
///
/// Reading the register layout afterwards suggests it should not work at all.
/// `embassy-rp` applies one constant to both parts with no `cfg`, and the two
/// parts do not agree:
///
/// ```text
///                        bit 0      bit 1   bit 2   bit 3    top bit
///   RP2040  PSM.WDSEL    rosc       xosc    ...                   16
///   RP2350  PSM.WDSEL    proc_cold  otp     ROSC    XOSC          24
/// ```
///
/// So on an RP2350 `0x0001_ffff & !0b11` clears `proc_cold` and `otp`, leaves
/// ROSC and XOSC **in** the reset set, and never reaches `proc0` or `proc1` at
/// bits 23 and 24. pico-sdk's `watchdog_reboot` uses
/// `PSM_WDSEL_BITS & ~(PSM_WDSEL_ROSC_BITS | PSM_WDSEL_XOSC_BITS)`, which on
/// this part is a different set of bits entirely.
///
/// **The deduction was acted on, and it was the wrong call.** A build using the
/// bit-by-bit "corrected" mask went onto a board before anything measured it,
/// on the strength of the reasoning above — and the board had to be recovered by
/// hand. The cause turned out to be somewhere else entirely (a product string
/// one character too long for the USB control buffer), so the corrected mask was
/// never even the problem; it was simply an unmeasured change made in the same
/// breath as a real fix, which is how an unmeasured change gets believed.
///
/// So: the measured value stays until something measures the other one.
/// **Which mask is right for RP2350 is an open question, not a settled one**,
/// and it is written down as a question in the experiment that will answer it.
fn select_reset_targets() {
    pac::PSM
        .wdsel()
        .write_value(pac::psm::regs::Wdsel(0x0001_ffff & !0b11));
}

#[inline(always)]
fn cortex_m_nop() {
    unsafe { core::arch::asm!("nop", options(nomem, nostack, preserves_flags)) }
}
