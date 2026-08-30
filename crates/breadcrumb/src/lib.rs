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
//! # The token carries a tag, because a magic word alone was not enough
//!
//! "A fresh flash finds nothing to believe" was **wider than what it could
//! promise**, and the first hardware run after this crate was split proved it.
//! exp157 came up and reported this, having run nothing:
//!
//! ```text
//!   boot #19, and the boot before it completed.
//!     boot 1: HANG in step 92
//!   STOP after 19 boots. Nothing armed; still reflashable.
//! ```
//!
//! Step 92 does not fit the five bits a step gets, so no code here wrote it; it
//! was whatever `SCRATCH3` happened to hold. `SCRATCH1` held 18, so the first
//! boot of a freshly flashed firmware was boot 19 and went **straight past its
//! own hard stop without running a single step, reporting success**. Eight of
//! the thirteen firmwares that use this crate stop on `note.boot >= N`, so
//! eight of them could do that.
//!
//! The token is consumed by the next boot's [`read`], and that was the whole
//! assumption. If the firmware that boots next does not use this crate — 81 of
//! the 94 experiments here do not — nobody consumes it, and it survives every
//! flash until some later breadcrumb firmware inherits a stranger's note.
//!
//! **So the token carries who left it.** [`read`] takes a `tag`, the firmware
//! answers with something unique to itself (these experiments pass their own
//! number, which they already hold for the USB serial), and a note is only ours
//! when the whole word matches:
//!
//! ```text
//!   SCRATCH0 = 0xB1EAD5_00 | tag
//!                         ^^ the low byte of the magic was always zero
//! ```
//!
//! A note from another build now reads as [`Cause::Fresh`], which is what it
//! always should have been. [`arm`] and [`reboot`] keep their signatures — the
//! tag is remembered from [`read`] — because `reboot` is called from fault
//! handlers, where the caller has nothing to hand it.
//!
//! **Pass a non-zero tag.** Tag `0` writes exactly the old magic word, so it
//! inherits from, and is inherited by, every untagged build. Nothing can stop
//! a caller doing that; the experiment number is never zero.
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

/// Says a note was left deliberately, rather than being whatever was in the
/// register — and **whose** note it is, in the low byte.
///
/// Not a checksum. It has to be a value nobody writes by accident, and it has
/// to differ between firmwares, which is the part a fixed word could not do and
/// a board proved it could not do. See the module documentation.
const MAGIC: u32 = 0xB1EA_D500;

/// The word `SCRATCH0` holds while a note is in flight, for this firmware.
pub const fn token(tag: u8) -> u32 {
    MAGIC | tag as u32
}

/// Is the word in `SCRATCH0` a note **this** firmware left?
pub const fn is_ours(s0: u32, tag: u8) -> bool {
    s0 == token(tag)
}

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
// ---------------------------------------------------------------------------
// The arithmetic, with no chip in it.
//
// Everything below decides what four words MEAN and what they should become.
// `board` does the only two things that need silicon: reading those words out
// of `WATCHDOG.SCRATCH0`-`SCRATCH3`, and writing them back.
//
// The split is this repository's existing one — `lifeline` and `ctap-hid` both
// gate their board half on the target so `cargo test` never sees embassy — and
// it is applied here late, for a reason worth stating: this crate is the
// INSTRUMENT. Every comment above names a bug that a board paid for, and until
// now not one of them had a test. A harness that misreports is worse than no
// harness, because the rounds it costs look like rounds spent on the subject.
// See `docs/the-board-is-the-loop.md`, which says instrumentation is exactly
// what the slow loop cannot develop.

/// The four words, as values rather than as registers.
///
/// `SCRATCH4`-`SCRATCH7` are the bootrom's and are not here.
#[derive(Copy, Clone, PartialEq, Eq, Debug, Default)]
pub struct Scratch {
    /// The handoff token: [`MAGIC`](self) when a note was left deliberately.
    pub s0: u32,
    /// Boot counter in the top 24 bits; step, sticky bit and tally in the low 8.
    pub s1: u32,
    /// Two bits per step: what became of each.
    pub s2: u32,
    /// One byte per boot, oldest first: how that boot ended.
    pub s3: u32,
}

/// Everything [`board::read`] decides, given what it found.
///
/// Returns the note to hand the firmware and the four words to write back.
/// `forced` is `WATCHDOG.REASON.FORCE` — the one bit that separates a fault
/// from a hang, and the only thing outside these four words that matters.
///
/// **`s0` comes back zero either way.** The token is one-shot: a firmware that
/// stops cleanly must leave nothing for the next one to misread, and a fresh
/// flash must find nothing to believe.
///
/// `tag` is what makes the second half of that true. A note whose tag is not
/// this firmware's is not this firmware's note, however well-formed it looks.
pub fn interpret(before: Scratch, forced: bool, tag: u8) -> (Note, Scratch) {
    if !is_ours(before.s0, tag) {
        return (
            Note { boot: 1, cause: Cause::Fresh, step: 0, history: [0; HISTORY], steps: 0 },
            Scratch { s0: 0, s1: pack(1, 0), s2: 0, s3: 0 },
        );
    }

    let (previous, step_raw) = unpack(before.s1);
    let boot = previous.saturating_add(1);
    let mut steps = before.s2;

    // Three things share the low byte and only one of them is the step: the
    // tally belongs to a caller and outlives boots, and the sticky bit says
    // this boot got up. Reading the whole byte as a step number turns a
    // successful boot with a tally of 2 into a death at step 64.
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

    // Fold it into the history, in the previous boot's slot.
    let mut history = before.s3.to_le_bytes();
    if previous >= 1 && (previous as usize) <= HISTORY {
        history[(previous - 1) as usize] = match cause {
            Cause::Fault => step | FAULT_BIT,
            Cause::Hang => step,
            _ => 0,
        };
    }

    (
        Note { boot, cause, step, history, steps },
        // The tally is the caller's and outlives a boot; the step is not.
        Scratch { s0: 0, s1: pack(boot, step_raw & STEP_TALLY), s2: steps, s3: u32::from_le_bytes(history) },
    )
}

/// `SCRATCH1` with the step set. See [`board::step`].
///
/// Returns `s1` unchanged once this boot has said it got up — see
/// [`STEP_STICKY`](self).
pub fn with_step(s1: u32, n: u8) -> u32 {
    let (boot, current) = unpack(s1);
    if current & STEP_STICKY != 0 {
        return s1;
    }
    pack(boot, (n & !(STEP_STICKY | STEP_TALLY)) | (current & STEP_TALLY))
}

/// The caller's tally, out of `SCRATCH1`.
pub fn tally_of(s1: u32) -> u8 {
    let (_, step) = unpack(s1);
    (step & STEP_TALLY) >> STEP_TALLY_SHIFT
}

/// `SCRATCH1` with the tally set, **saturating** at [`TALLY_MAX`].
///
/// Saturating and not wrapping: a caller deciding *give up after three* must
/// never see the count roll back to zero.
pub fn with_tally(s1: u32, n: u8) -> u32 {
    let (boot, step) = unpack(s1);
    let n = n.min(TALLY_MAX);
    pack(boot, (step & !STEP_TALLY) | (n << STEP_TALLY_SHIFT))
}

/// `SCRATCH2` with step `n` recorded. Out-of-range steps change nothing.
pub fn with_mark(s2: u32, n: u8, outcome: u8) -> u32 {
    if n == 0 || n > STEPS {
        return s2;
    }
    let shift = 2 * (n - 1) as u32;
    (s2 & !(0b11 << shift)) | (((outcome as u32) & 0b11) << shift)
}

/// `SCRATCH1` saying the sequence finished without dying.
pub fn with_finished(s1: u32) -> u32 {
    let (boot, step) = unpack(s1);
    pack(boot, NO_STEP as u8 | STEP_STICKY | (step & STEP_TALLY))
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

/// The half that needs a chip: the same arithmetic, with the registers.
///
/// Only compiled for the target, so `cargo test` never sees embassy. Its items
/// are re-exported at the crate root, so `breadcrumb::read()` is unchanged for
/// the thirteen experiments that call it.
#[cfg(target_os = "none")]
pub mod board;
#[cfg(target_os = "none")]
pub use board::*;

#[cfg(test)]
mod tests;
