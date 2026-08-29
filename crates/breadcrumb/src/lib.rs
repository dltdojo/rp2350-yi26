//! A note left for the next boot.
//!
//! When firmware dies, everything it knew dies with it. USB is gone, the log is
//! gone, the page cannot connect, and the only thing left is an LED that a
//! person has to watch and count. [exp156] spent seven flash cycles inside that
//! constraint — each one a walk to a bench — and **two of them produced a fact
//! about the subject**. The rest went on making the experiment run at all, on
//! making the LED able to say *where* rather than *that*, and one was lost to a
//! report that said "it kept blinking" when slow and fast mean different things.
//!
//! This crate exists to remove the constraint rather than to survive it. The
//! reasoning is in [`docs/the-board-is-the-loop.md`][doc].
//!
//! # How it works
//!
//! `WATCHDOG.SCRATCH0`–`SCRATCH3` are four words of ordinary registers that
//! **survive a watchdog reset**, which is the documented mechanism the bootrom
//! itself uses for `reset_usb_boot()`. Sixteen bytes, written before each step
//! and never after, so the number that survives names the step that did not
//! come back:
//!
//! ```text
//!   SCRATCH0   a magic word — is there a note here at all?
//!   SCRATCH1   which boot this is
//!   SCRATCH2   the step being attempted RIGHT NOW
//!   SCRATCH3   one byte per boot: how that boot ended
//! ```
//!
//! `SCRATCH4`–`SCRATCH7` are **the bootrom's** — it reads magic values there to
//! decide the boot outcome — so nothing here touches them.
//!
//! # It catches hangs, which no fault handler does
//!
//! exp156's very first failure was a hang: `spawn_core1` waiting forever on a
//! core that could not answer. No exception fires for that. The board simply
//! stopped, and the signal was darkness, which is also what a firmware that
//! never started looks like.
//!
//! An armed watchdog catches it, and [`Note::cause`] tells the two kinds of
//! death apart:
//!
//! - **the watchdog timed out** — nothing fed it, so the firmware hung
//! - **the reset was forced** — a fault handler called [`reboot`], so it faulted
//!
//! # A stale note is worse than no note
//!
//! Reflashing does not clear these registers. A firmware that trusted whatever
//! it found would report the *previous build's* death as its own, which is the
//! failure this whole crate is written against, arriving through the front door.
//!
//! The first attempt at guarding that was to trust a note only when
//! `WATCHDOG.REASON` said a watchdog caused this boot, on the reasoning that a
//! power-on or a flash leaves it at zero. **That was measured wrong within one
//! run.** The 1200-baud reflash touch reboots the board *through the watchdog*,
//! so `REASON` says watchdog on exactly the boot that is furthest from being a
//! continuation — the first boot of a freshly flashed firmware. It reported a
//! previous build's history as its own and skipped its whole scenario.
//!
//! So the note is a **one-shot handoff token** instead. [`arm`] and [`reboot`]
//! write the magic; [`read`] consumes it, clearing `SCRATCH0` before returning.
//! A note therefore exists only if the boot before it was inside a sequence that
//! had deliberately armed, and a firmware that stops cleanly leaves nothing
//! behind for the next one to misread.
//!
//! `REASON` is still read — it is what separates a hang from a fault — but it no
//! longer decides whether the note is ours.
//!
//! # The safety property, and it is not optional
//!
//! [`arm`] must stop being called at some point. A board in a reboot loop it
//! cannot be talked out of is worse than the slow loop this replaces: the
//! 1200-baud reflash touch needs the device to stay enumerated long enough to
//! hear it. Use [`Note::boot`] as the counter and stop.
//!
//! **And keep reporting after you stop.** A harness whose whole purpose is
//! reporting must not fall silent when it gives up — that is exactly the state
//! exp156's round seven could not diagnose.
//!
//! [exp156]: https://github.com/dltdojo/rp2350-yi26/tree/main/experiments/exp156-a-wall-you-can-measure
//! [doc]: https://github.com/dltdojo/rp2350-yi26/blob/main/docs/the-board-is-the-loop.md

#![no_std]

use embassy_rp::pac;

/// Says a note was left deliberately, rather than being whatever was in the
/// register. Not a checksum: it only has to be a value nobody writes by
/// accident, and the note is already gated on `REASON` before this is consulted.
const MAGIC: u32 = 0xB1EA_D500;

/// How many boots [`Note::history`] can carry. One byte each, in `SCRATCH3`.
pub const HISTORY: usize = 4;

/// Set in a history byte when the boot ended in a fault rather than a hang.
const FAULT_BIT: u8 = 0x80;

/// Written to `SCRATCH2` while no step is in progress.
///
/// Zero would be ambiguous with "step 0", and a firmware that numbers its first
/// step 0 is a firmware whose first step is invisible.
const NO_STEP: u32 = 0;

/// Set in the step byte once [`finished`] has been called, and never cleared by
/// [`step`].
///
/// **A boot that got up cannot un-get-up.** Without this, a firmware that calls
/// `finished` and then goes on marking its own steps — which is the ordinary
/// way to use this crate — overwrites the record of having got up, and the next
/// boot reads an ordinary reflash as a death. [`lifeline`](../../lifeline/)
/// counts consecutive deaths to decide when a board has stopped coming back, so
/// that miscount is the difference between a useful escape and a board that
/// drops into its bootloader because somebody flashed it three times.
const STEP_STICKY: u8 = 0x80;

/// Two bits of the step byte, for a caller counting boots that failed at
/// something.
///
/// A step is 0..=[`STEPS`], which needs five bits, and [`STEP_STICKY`] takes
/// the top one. These two are what is left, and they survive a reset exactly as
/// the rest of this does.
///
/// **They exist because the history above cannot do this job.** `history` is
/// four slots indexed by *absolute boot number*, so from the fifth boot onwards
/// it stops being written and [`Note::ended`] keeps reporting the first four
/// boots for ever. That is right for [exp157], which demonstrates a short
/// deliberate sequence, and useless for a board that has been powered on for a
/// week. Rather than change what exp157 verified, a caller that needs "how many
/// in a row, ending now" gets a counter of its own.
///
/// [exp157]: ../../experiments/exp157-a-note-for-the-next-boot/
const STEP_TALLY: u8 = 0x60;
const STEP_TALLY_SHIFT: u32 = 5;

/// The largest tally these two bits hold. Saturating, not wrapping: a caller
/// deciding *give up after three* must never see the count roll to zero.
pub const TALLY_MAX: u8 = 3;

/// How many steps [`Note::outcome`] can carry. Two bits each, in `SCRATCH2`.
pub const STEPS: u8 = 16;

/// A step nobody has attempted yet. Zero on purpose: an untouched register reads
/// as "nothing has been tried", which is the safe reading.
pub const NOT_ATTEMPTED: u8 = 0;

/// A step that was in progress when the boot ended. **Written by the crate**,
/// never by the caller: it is the outcome nobody is alive to report.
pub const DIED: u8 = 1;

/// The two codes a firmware may define for itself, for steps that survived.
///
/// "It came back" is rarely the whole answer. A write that is silently ignored
/// and a write that takes effect both survive, and telling them apart is usually
/// the actual question — so a step that lives says which of the two it was.
pub const SURVIVED_A: u8 = 2;
pub const SURVIVED_B: u8 = 3;

/// How the previous boot ended.
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum Cause {
    /// There was no previous boot to report on — power-on, or a fresh flash.
    Fresh,
    /// It reached [`finished`] without dying.
    Completed,
    /// The watchdog timed out: nothing fed it, so the firmware **hung**.
    Hang,
    /// A fault handler called [`reboot`], so the firmware **faulted**.
    Fault,
}

/// What the previous boot left behind.
pub struct Note {
    /// Which boot this is, counting from 1.
    pub boot: u32,
    /// How the previous boot ended.
    pub cause: Cause,
    /// The step the previous boot was attempting when it died. `0` if it did
    /// not die.
    pub step: u8,
    /// One byte per boot, oldest first: `0` completed, otherwise the step it
    /// died at, with the top bit set if that death was a fault.
    ///
    /// Read it with [`Note::ended`] rather than by hand.
    pub history: [u8; HISTORY],
    /// Two bits per step. Read it with [`Note::outcome`].
    pub steps: u32,
}

impl Note {
    /// What became of step `n`, counting from 1: [`NOT_ATTEMPTED`], [`DIED`], or
    /// whichever of [`SURVIVED_A`] / [`SURVIVED_B`] the firmware marked.
    pub fn outcome(&self, n: u8) -> u8 {
        if n == 0 || n > STEPS {
            return NOT_ATTEMPTED;
        }
        ((self.steps >> (2 * (n - 1) as u32)) & 0b11) as u8
    }

    /// The lowest-numbered step nobody has tried yet, or `None` when the matrix
    /// is exhausted.
    ///
    /// **A step that died counts as tried.** That is the whole of lever two: a
    /// boot that comes back after a death does not retry the thing that killed
    /// it — it steps over it and attempts the next candidate, so one flash walks
    /// a list that a human would otherwise walk one bench trip at a time.
    pub fn next_unattempted(&self, count: u8) -> Option<u8> {
        (1..=count.min(STEPS)).find(|&n| self.outcome(n) == NOT_ATTEMPTED)
    }

    /// How boot `n` ended, counting from 1. `None` once `n` is beyond what has
    /// **finished** or beyond what sixteen bytes can hold.
    ///
    /// `self.boot - 1` and not `self.boot`, because the boot that is asking has
    /// not ended yet. The first version used `self.boot`, so every boot opened
    /// its report by announcing that it had itself completed all its steps —
    /// before running any of them. A history slot that has never been written
    /// reads as zero, and zero means *completed*, so the wrong bound did not
    /// produce nonsense. It produced a confident, plausible lie.
    pub fn ended(&self, n: u32) -> Option<(Cause, u8)> {
        if n == 0 || n > self.boot.saturating_sub(1).min(HISTORY as u32) {
            return None;
        }
        let byte = self.history[(n - 1) as usize];
        Some(match byte {
            0 => (Cause::Completed, 0),
            b if b & FAULT_BIT != 0 => (Cause::Fault, b & !FAULT_BIT),
            b => (Cause::Hang, b),
        })
    }
}

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

    // The token is one-shot: consumed here, and only rewritten by `arm` or
    // `reboot`. So a firmware that stopped cleanly leaves nothing behind, and a
    // fresh flash finds nothing to believe.
    let ours = wd.scratch0().read() == MAGIC;
    wd.scratch0().write_value(0);

    if !ours {
        wd.scratch1().write_value(pack(1, 0));
        wd.scratch2().write_value(0);
        wd.scratch3().write_value(0);
        return Note { boot: 1, cause: Cause::Fresh, step: 0, history: [0; HISTORY], steps: 0 };
    }

    let (previous, step_raw) = unpack(wd.scratch1().read());
    let boot = previous.saturating_add(1);
    let mut steps = wd.scratch2().read();

    // SCRATCH1's low byte still holds whatever step the previous boot was inside
    // when it stopped, because it is written before each step and cleared only
    // by `finished`.
    // Three things share this byte and only one of them is the step: the tally
    // belongs to a caller and outlives boots, and the sticky bit says this boot
    // got up. Reading the whole byte as a step number turns a successful boot
    // with a tally of 2 into a death at step 64.
    let step = if step_raw & STEP_STICKY != 0 {
        NO_STEP as u8
    } else {
        step_raw & !(STEP_STICKY | STEP_TALLY)
    };
    let (cause, step) = if step == NO_STEP as u8 {
        (Cause::Completed, 0)
    } else if forced {
        (Cause::Fault, step)
    } else {
        (Cause::Hang, step)
    };

    // A step that was in progress at the death is marked DIED here — by the
    // crate, because there was nobody alive to mark it. This is what makes
    // `next_unattempted` step over it instead of walking into it again, and a
    // harness that retried the thing that killed it would never finish.
    if step != 0 && step <= STEPS {
        let shift = 2 * (step - 1) as u32;
        if (steps >> shift) & 0b11 == NOT_ATTEMPTED as u32 {
            steps = (steps & !(0b11 << shift)) | ((DIED as u32) << shift);
        }
    }
    wd.scratch2().write_value(steps);

    // Fold it into the history, in the previous boot's slot.
    let mut history = wd.scratch3().read().to_le_bytes();
    if previous >= 1 && (previous as usize) <= HISTORY {
        history[(previous - 1) as usize] = match cause {
            Cause::Fault => step | FAULT_BIT,
            Cause::Hang => step,
            _ => 0,
        };
    }

    // The tally is the caller's and outlives a boot; the step is not.
    wd.scratch1().write_value(pack(boot, step_raw & STEP_TALLY));
    wd.scratch3().write_value(u32::from_le_bytes(history));

    Note { boot, cause, step, history, steps }
}

/// `SCRATCH1` carries two things, because four words have to hold five.
///
/// The boot counter needs a handful of bits and the step in progress needs a
/// byte, so they share a word and `SCRATCH2` is freed for the per-step outcomes
/// that lever two runs on.
fn pack(boot: u32, step: u8) -> u32 {
    (boot << 8) | step as u32
}

fn unpack(v: u32) -> (u32, u8) {
    (v >> 8, (v & 0xff) as u8)
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
    let (boot, current) = unpack(wd.scratch1().read());
    // Ignored once this boot has said it got up. See STEP_STICKY.
    if current & STEP_STICKY != 0 {
        return;
    }
    wd.scratch1().write_value(pack(boot, (n & !(STEP_STICKY | STEP_TALLY)) | (current & STEP_TALLY)));
}

/// Read the caller's tally. See [`STEP_TALLY`].
pub fn tally() -> u8 {
    let (_, step) = unpack(pac::WATCHDOG.scratch1().read());
    (step & STEP_TALLY) >> STEP_TALLY_SHIFT
}

/// Write the caller's tally, saturating at [`TALLY_MAX`].
pub fn set_tally(n: u8) {
    let wd = pac::WATCHDOG;
    let (boot, step) = unpack(wd.scratch1().read());
    let n = n.min(TALLY_MAX);
    wd.scratch1()
        .write_value(pack(boot, (step & !STEP_TALLY) | (n << STEP_TALLY_SHIFT)));
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
    if n == 0 || n > STEPS {
        return;
    }
    let wd = pac::WATCHDOG;
    let shift = 2 * (n - 1) as u32;
    let v = wd.scratch2().read();
    wd.scratch2()
        .write_value((v & !(0b11 << shift)) | (((outcome as u32) & 0b11) << shift));
}

/// Say that the sequence finished without dying.
///
/// Without this every completed boot looks like a boot that died in whatever
/// step it ran last, and a report that cannot say "nothing went wrong" is a
/// report whose failures mean nothing.
pub fn finished() {
    let wd = pac::WATCHDOG;
    let (boot, _) = unpack(wd.scratch1().read());
    let (_, step) = unpack(wd.scratch1().read());
    wd.scratch1()
        .write_value(pack(boot, NO_STEP as u8 | STEP_STICKY | (step & STEP_TALLY)));
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
