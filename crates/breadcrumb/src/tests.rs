// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 rp2350-yi26 contributors

//! What the instrument must not get wrong.
//!
//! Every comment in `lib.rs` names a mistake a board paid for, and until this
//! file none of them had a test. They are the tests, one each, named after the
//! wrong answer rather than after the function — because the risk here is not
//! that a function returns an error, it is that the harness reports a
//! *plausible* lie and somebody spends a bench trip on it.

use super::*;

/// A boot that armed and then died at `step`, with `tally` already counted.
fn left_by(boot: u32, step: u8, tally: u8) -> Scratch {
    Scratch { s0: MAGIC, s1: pack(boot, step | (tally << STEP_TALLY_SHIFT)), s2: 0, s3: 0 }
}

// --- the token, and the reflash that broke the first design ----------------

#[test]
fn a_boot_with_no_token_is_fresh_however_convincing_the_rest_looks() {
    let (note, after) = interpret(
        Scratch { s0: 0, s1: pack(9, 7), s2: 0xFFFF_FFFF, s3: 0x0403_0201 },
        false,
    );
    assert_eq!(note.cause, Cause::Fresh);
    assert_eq!(note.boot, 1);
    assert_eq!(note.step, 0);
    assert_eq!(note.steps, 0);
    assert_eq!(note.history, [0; HISTORY]);
    assert_eq!(after, Scratch { s0: 0, s1: pack(1, 0), s2: 0, s3: 0 });
}

#[test]
fn a_reflashed_board_does_not_inherit_the_previous_builds_death() {
    // The first design trusted a note whenever WATCHDOG.REASON said a watchdog
    // caused the boot. The 1200-baud reflash touch reboots THROUGH the
    // watchdog, so `forced` is exactly what a freshly flashed firmware sees —
    // and it reported the previous build's history as its own.
    let (note, _) = interpret(Scratch { s0: 0, s1: pack(4, 3), s2: 0x55, s3: 0x0302 }, true);
    assert_eq!(note.cause, Cause::Fresh);
    assert_eq!(note.boot, 1);
}

// --- how a boot ended -------------------------------------------------------

#[test]
fn a_step_in_progress_and_a_forced_reset_is_a_fault() {
    let (note, _) = interpret(left_by(1, 5, 0), true);
    assert_eq!(note.cause, Cause::Fault);
    assert_eq!(note.step, 5);
    assert_eq!(note.boot, 2);
}

#[test]
fn a_step_in_progress_and_a_timeout_is_a_hang() {
    // The failure no fault handler catches, and exp156's very first round.
    let (note, _) = interpret(left_by(1, 5, 0), false);
    assert_eq!(note.cause, Cause::Hang);
    assert_eq!(note.step, 5);
}

#[test]
fn a_boot_that_got_up_is_completed_and_not_a_death_at_step_sixty_four() {
    // Three things share the low byte. Reading all of it as a step number turns
    // a boot that finished, carrying a tally of 2, into a death at step 192.
    let s1 = with_finished(pack(3, 2 << STEP_TALLY_SHIFT));
    assert_eq!(unpack(s1).1, STEP_STICKY | (2 << STEP_TALLY_SHIFT));
    let (note, _) = interpret(Scratch { s0: MAGIC, s1, s2: 0, s3: 0 }, false);
    assert_eq!(note.cause, Cause::Completed);
    assert_eq!(note.step, 0);
}

#[test]
fn a_tally_without_the_sticky_bit_is_still_not_a_step() {
    // 2 << 5 is 64, which is the number the crate's own comment names.
    let (note, _) = interpret(left_by(2, 0, 2), false);
    assert_eq!(note.cause, Cause::Completed);
    assert_ne!(note.step, 64);
}

// --- the matrix, which is the whole of lever two ---------------------------

#[test]
fn the_step_that_died_is_marked_so_the_next_boot_steps_over_it() {
    // 1 and 2 survived, 3 killed the board. The next boot must attempt 4.
    let s2 = with_mark(with_mark(0, 1, SURVIVED_A), 2, SURVIVED_B);
    let (note, after) = interpret(Scratch { s0: MAGIC, s1: pack(3, 3), s2, s3: 0 }, false);
    assert_eq!(note.outcome(3), DIED);
    assert_eq!(note.next_unattempted(6), Some(4));
    assert_eq!(after.s2, note.steps);
}

#[test]
fn a_harness_that_retried_what_killed_it_would_never_finish() {
    // The same note fed back in: step 3 stays DIED and 4 is still next.
    let s2 = with_mark(with_mark(0, 1, SURVIVED_A), 2, SURVIVED_B);
    let (first, after) = interpret(Scratch { s0: MAGIC, s1: pack(3, 3), s2, s3: 0 }, false);
    let (second, _) = interpret(Scratch { s0: MAGIC, s1: after.s1, s2: after.s2, s3: after.s3 }, false);
    assert_eq!(first.next_unattempted(6), second.next_unattempted(6));
}

#[test]
fn a_death_does_not_overwrite_a_step_that_already_said_what_it_was() {
    let s2 = with_mark(0, 3, SURVIVED_B);
    let (note, _) = interpret(Scratch { s0: MAGIC, s1: pack(1, 3), s2, s3: 0 }, true);
    assert_eq!(note.outcome(3), SURVIVED_B);
}

#[test]
fn next_unattempted_ends_rather_than_looping_when_the_matrix_is_exhausted() {
    let mut s2 = 0;
    for n in 1..=4 {
        s2 = with_mark(s2, n, SURVIVED_A);
    }
    let note = Note { boot: 1, cause: Cause::Fresh, step: 0, history: [0; HISTORY], steps: s2 };
    assert_eq!(note.next_unattempted(4), None);
}

#[test]
fn all_sixteen_steps_fit_and_the_seventeenth_does_not() {
    let mut s2 = 0;
    for n in 1..=STEPS {
        s2 = with_mark(s2, n, SURVIVED_A);
    }
    let note = Note { boot: 1, cause: Cause::Fresh, step: 0, history: [0; HISTORY], steps: s2 };
    assert_eq!(note.outcome(STEPS), SURVIVED_A);
    assert_eq!(note.outcome(STEPS + 1), NOT_ATTEMPTED);
    assert_eq!(note.outcome(0), NOT_ATTEMPTED);
    assert_eq!(with_mark(s2, 0, DIED), s2);
    assert_eq!(with_mark(s2, STEPS + 1, DIED), s2);
}

// --- the history, and the confident plausible lie --------------------------

#[test]
fn ended_never_reports_the_boot_that_is_asking() {
    // The first version bounded on `self.boot` rather than `self.boot - 1`, so
    // every boot opened its report by announcing that it had itself completed
    // all its steps, before running any of them. An unwritten slot reads zero
    // and zero means completed, so it was not nonsense. It was a lie.
    let note = Note { boot: 1, cause: Cause::Fresh, step: 0, history: [0; HISTORY], steps: 0 };
    assert_eq!(note.ended(1), None);
    assert_eq!(note.ended(0), None);
}

#[test]
fn a_death_lands_in_the_previous_boots_slot_and_the_next_boot_can_read_it() {
    let (note, _) = interpret(left_by(1, 5, 0), true);
    assert_eq!(note.boot, 2);
    assert_eq!(note.ended(1), Some((Cause::Fault, 5)));
    assert_eq!(note.ended(2), None);
}

#[test]
fn a_completed_boot_leaves_a_zero_in_its_slot_and_reads_back_as_completed() {
    let s1 = with_finished(pack(1, 0));
    let (note, _) = interpret(Scratch { s0: MAGIC, s1, s2: 0, s3: 0xFF }, false);
    assert_eq!(note.history[0], 0);
    assert_eq!(note.ended(1), Some((Cause::Completed, 0)));
}

#[test]
fn a_hang_and_a_fault_at_the_same_step_are_different_bytes() {
    let (hung, _) = interpret(left_by(1, 6, 0), false);
    let (faulted, _) = interpret(left_by(1, 6, 0), true);
    assert_eq!(hung.ended(1), Some((Cause::Hang, 6)));
    assert_eq!(faulted.ended(1), Some((Cause::Fault, 6)));
    assert_ne!(hung.history[0], faulted.history[0]);
}

#[test]
fn beyond_four_boots_the_history_stops_being_written_and_says_so() {
    // A documented limit, not a bug: `history` is indexed by absolute boot
    // number. `ended` must refuse to answer rather than repeat boot four.
    let (note, _) = interpret(left_by(HISTORY as u32 + 1, 2, 0), false);
    assert_eq!(note.boot, HISTORY as u32 + 2);
    assert_eq!(note.ended(HISTORY as u32 + 1), None);
    assert_eq!(note.history, [0; HISTORY]);
}

// --- the tally, which belongs to the caller and outlives a boot ------------

#[test]
fn the_tally_survives_a_boot_and_the_step_does_not() {
    let (_, after) = interpret(left_by(2, 5, 3), false);
    assert_eq!(tally_of(after.s1), 3);
    assert_eq!(unpack(after.s1).1 & !(STEP_STICKY | STEP_TALLY), 0);
    assert_eq!(unpack(after.s1).0, 3);
}

#[test]
fn a_tally_saturates_rather_than_rolling_back_to_zero() {
    // A caller deciding "give up after three" must never see the count wrap.
    let s1 = with_tally(pack(2, 0), TALLY_MAX + 5);
    assert_eq!(tally_of(s1), TALLY_MAX);
    assert_eq!(tally_of(with_tally(s1, 0)), 0);
}

#[test]
fn setting_the_tally_does_not_disturb_the_step_or_the_boot() {
    let s1 = with_tally(with_step(pack(7, 0), 9), 2);
    assert_eq!(unpack(s1).0, 7);
    assert_eq!(unpack(s1).1 & !(STEP_STICKY | STEP_TALLY), 9);
    assert_eq!(tally_of(s1), 2);
}

// --- the sticky bit --------------------------------------------------------

#[test]
fn a_boot_that_got_up_cannot_un_get_up() {
    // Without this, a firmware that calls `finished` and then goes on marking
    // its own steps — the ordinary way to use this crate — overwrites the
    // record of having got up, and the next boot reads an ordinary reflash as
    // a death. `lifeline` counts consecutive deaths, so that miscount drops a
    // board into its bootloader because somebody flashed it three times.
    let s1 = with_finished(pack(2, 0));
    assert_eq!(with_step(s1, 5), s1);
    let (note, _) = interpret(Scratch { s0: MAGIC, s1: with_step(s1, 5), s2: 0, s3: 0 }, false);
    assert_eq!(note.cause, Cause::Completed);
}

#[test]
fn finished_keeps_the_tally_and_clears_the_step() {
    let s1 = with_finished(with_tally(with_step(pack(4, 0), 11), 2));
    assert_eq!(tally_of(s1), 2);
    assert_eq!(unpack(s1).1 & !(STEP_STICKY | STEP_TALLY), NO_STEP as u8);
    assert_eq!(unpack(s1).0, 4);
}

// --- the packing -----------------------------------------------------------

#[test]
fn pack_and_unpack_are_inverses_across_the_whole_low_byte() {
    for boot in [0u32, 1, 2, 255, 0x00FF_FFFF] {
        for step in [0u8, 1, 16, STEP_STICKY, STEP_TALLY, 0xFF] {
            assert_eq!(unpack(pack(boot, step)), (boot, step));
        }
    }
}

#[test]
fn a_step_number_cannot_reach_the_sticky_or_tally_bits() {
    // `with_step` masks, so a caller passing rubbish corrupts neither.
    let s1 = with_tally(pack(1, 0), 3);
    let after = with_step(s1, 0xFF);
    assert_eq!(tally_of(after), 3);
    assert_eq!(unpack(after).1 & STEP_STICKY, 0);
}
