//! Print from anywhere, without the printing becoming the bug.
//!
//! A serial log carries far more than a blinking LED can: numbers, timings,
//! which of several tasks did what and when. exp104 gave this repository the
//! ability to print at all. This crate makes it something you can call from
//! *any* task, at any moment, without stopping to think about who owns the
//! USB endpoint or what happens if nobody is listening.
//!
//! ```ignore
//! usb_log::log!("button #{} down after {} ms", presses, uptime);
//! ```
//!
//! That call is an ordinary synchronous function. It does not `.await`, it
//! cannot block, and it takes the same bounded time whether the host is
//! reading avidly, has the port open and ignores it, or is not plugged in.
//!
//! # The problem this exists to solve
//!
//! exp104 measured what naive printing does: two consecutive counter values
//! arrived **21 seconds apart**, because `write_all` parks the task until
//! something drains the endpoint. exp106 worked around it by only printing
//! when DTR was asserted — which helps, and is still not enough: a terminal
//! that is open but not reading asserts DTR just fine, and then the write
//! parks anyway. A debug tool that changes the timing of the thing being
//! debugged is worse than no debug tool, because it lies.
//!
//! # How it is solved: move the blocking, do not remove it
//!
//! There is exactly one way to make a USB write not block, and it is not to
//! make USB faster. It is to put a **queue** between the code that has
//! something to say and the code that says it:
//!
//! ```text
//!   button task  ─┐
//!   timer task   ─┼─→ [ queue, 16 lines ] ─→ logger task ─→ USB ─→ host
//!   any task     ─┘        (never waits)      (waits here)
//! ```
//!
//! The logger task still blocks — that part is unavoidable. The point is
//! *where* it blocks: in a task whose only job is logging, where being stuck
//! harms nothing. Your button keeps being polled at 20 ms whatever the host
//! is doing.
//!
//! # It waits for a listener before it writes at all
//!
//! One extra rule, and it is not politeness — it was learned by wedging a
//! board. The writer will not put a line on the wire until the host asserts
//! DTR, which is what opening the port does.
//!
//! Without that check, a line written while nobody is collecting leaves a
//! packet armed in the USB IN endpoint indefinitely. Keep doing that and the
//! chip eventually stops answering **control** requests, while the serial
//! stream itself keeps flowing perfectly. The board looks healthy and is not:
//! `SET_LINE_CODING` never completes, so the 1200-baud reflash touch hangs and
//! the BOOTSEL button becomes the only way back in. Measured on hardware —
//! reproducible after about thirty seconds of writing into a closed port, and
//! not recoverable by attaching a reader afterwards.
//!
//! So the queue is not only a buffer against slow readers. It is where output
//! waits for an audience, and the drop counting below is what keeps that
//! honest.
//!
//! # What happens when the queue fills
//!
//! Waiting for room is disqualified: it is the original bug wearing a hat.
//! So the line is dropped, and this crate **counts what it dropped**. The
//! count is attached to the first line that survives after the gap, so the
//! loss is marked exactly where it happened:
//!
//! ```text
//! [    9012 ms] (+47 lines lost) heartbeat #10 (LED flashed)
//! ```
//!
//! For a long time the paragraph above said there were "only two choices",
//! wait or drop, and that was wrong in a way nobody noticed for thirty-three
//! experiments. Dropping hides a second question: **which** line? Refusing the
//! new arrival keeps the *oldest* entries; evicting the head keeps the
//! *newest*. Both are dropping, both cost the same RAM, and they hand a reader
//! two completely different logs — which matters most to somebody who opens a
//! browser page two minutes after the interesting thing happened.
//!
//! [`POLICY`] is that choice, made at build time, and [`log_policy`] holds the
//! decision itself so it can be tested without a board. The default is
//! unchanged and always will be: refuse the newest, keep the oldest, count
//! everything.
//!
//! Counting at the sending end rather than announcing it from the writer is
//! what makes that position right: the writer only ever sees lines that were
//! accepted, and would have to guess where the missing ones belonged.
//!
//! Silent loss would be the worst of all options: you would read an
//! incomplete log believing it complete. Losing data is survivable; not
//! knowing you lost it is not. That principle is the same one behind
//! `experiments/audit.sh` — a tool that asks to be trusted has already
//! failed.
//!
//! # The timestamp is taken by the caller, not by the writer
//!
//! [`log`] stamps the line the moment you call it, before it enters the
//! queue. If it were stamped on the way out, every timestamp would record
//! when USB got around to it — and the delays you are trying to debug would
//! be invisible, having been quietly absorbed into the measurement. A log
//! that hides the very effect you are hunting is a trap, and this ordering is
//! the difference.
//!
//! # Costs, stated plainly
//!
//! - **RAM:** [`QUEUE_DEPTH`] × [`LINE_CAPACITY`] bytes of static buffer
//!   (1536 with the defaults), plus one [`Line`] built on the caller's stack.
//! - **Time per call:** formatting, a copy of at most [`LINE_CAPACITY`]
//!   bytes, and a brief critical section inside the queue. Bounded and
//!   short — but not zero. Do not call this from an interrupt-critical path
//!   without measuring it, and do not put it inside a tight loop.
//! - **Lines are truncated** at [`LINE_CAPACITY`] bytes rather than being
//!   split or dropped. A cut line ends in `...` so you can see it happened.
//! - **Nothing is authenticated.** Everything logged is readable by any local
//!   process that can open the serial port. `experiments/audit.sh` reports
//!   this. Do not log secrets.

//!
//! # Two halves, and only one of them needs a board
//!
//! How a line is cut at [`LINE_CAPACITY`], which [`POLICY`] a build chose, and
//! how the loss count is claimed by the line that reports it and handed back
//! when that line loses a race — all of that is in this file, and `cargo test`
//! runs it on a machine with no board. `board.rs` is the rest: the queue, the
//! USB sender, the clock, the DTR wait. It compiles only for the chip.
//!
//! For seventy-four experiments this crate was the one instrument everything
//! printed through, with no tests, because it depends on `embassy-rp`. That
//! was true of half of it.
//!
//! **The split changes nothing a board runs**, and that is measured rather
//! than argued: every firmware that depends on this crate builds to the same
//! bytes after it as before. The same measurement is why the stamp and the
//! loss marker are still written inline in `board.rs`. Moving them here, in
//! each of five shapes tried, changed the code emitted for `log` in every
//! dependent firmware — equivalent, but no longer the same bytes, and so a
//! change that would need a board to verify. They are the next thing to move
//! the day somebody is at one.

#![no_std]

use core::fmt::{self, Write};
use core::sync::atomic::{AtomicU32, Ordering};

use log_policy::Policy;

#[cfg(target_os = "none")]
mod board;
#[cfg(target_os = "none")]
pub use board::*;

/// Longest line, in bytes, including the timestamp prefix. Longer lines are
/// truncated and marked with `...`.
pub const LINE_CAPACITY: usize = 96;

/// How many lines can be waiting to go out before new ones are dropped.
///
/// Bigger absorbs longer stalls and costs proportionally more RAM. 16 lines
/// is enough to ride out a host that pauses for a moment, and small enough
/// that a host which stops reading altogether shows you the drop message
/// quickly instead of pretending everything is fine.
pub const QUEUE_DEPTH: usize = 16;

#[cfg(all(feature = "keep-recent", feature = "silent-while-idle"))]
compile_error!(
    "keep-recent and silent-while-idle are alternatives, not additions: one \
     keeps the newest lines and the other keeps none. Choose one."
);

/// What this build does when the queue is full, or when nobody is reading.
///
/// Selected at compile time because the answer is a property of the firmware,
/// not of the moment — and because a runtime switch would mean shipping all
/// three and letting a mistake be a mistake in the field rather than in the
/// build. See [`log_policy`] for what each one means and why none of them is
/// universally right.
pub const POLICY: Policy = if cfg!(feature = "keep-recent") {
    Policy::KeepRecent
} else if cfg!(feature = "silent-while-idle") {
    Policy::SilentWhileIdle
} else {
    Policy::DropNewest
};

/// One formatted line, waiting its turn.
///
/// A fixed-size array rather than a `String`: there is no allocator on this
/// chip, and a log line whose size depends on its content is a log line that
/// can run the queue out of memory at the worst possible moment.
pub struct Line {
    buf: [u8; LINE_CAPACITY],
    len: usize,
    truncated: bool,
}

impl Line {
    #[cfg_attr(not(target_os = "none"), allow(dead_code))]
    const fn new() -> Self {
        Self { buf: [0; LINE_CAPACITY], len: 0, truncated: false }
    }
}

impl Write for Line {
    /// Copies what fits and remembers if anything did not.
    ///
    /// Note it returns `Ok` even when it dropped bytes. That is deliberate: a
    /// logging path that can fail becomes a thing callers have to handle, and
    /// then they stop logging. Truncation is recorded in the output instead,
    /// where a human will see it.
    fn write_str(&mut self, s: &str) -> fmt::Result {
        let bytes = s.as_bytes();
        let room = LINE_CAPACITY - self.len;
        let n = if bytes.len() < room { bytes.len() } else { room };
        self.buf[self.len..self.len + n].copy_from_slice(&bytes[..n]);
        self.len += n;
        if n < bytes.len() {
            self.truncated = true;
        }
        Ok(())
    }
}

/// How many lost lines the line being built should report, taken from the
/// shared count.
///
/// A **delta** is safe only in a queue that never discards what it already
/// accepted: the number is rendered into one line's text, and if that line is
/// thrown away the number goes with it. `keep-recent` throws accepted lines
/// away by design, so a delta would quietly undercount every gap it evicted a
/// marker for. It therefore reads the count and leaves it, and every later
/// line repeats the total. The other two policies take the count and zero it
/// in one step, so two tasks logging at once cannot both report the same gap.
// Called only from `board.rs`, which a host build does not compile; the tests
// below are the other caller.
#[cfg_attr(not(target_os = "none"), allow(dead_code))]
#[inline(always)]
fn claim(policy: Policy, dropped: &AtomicU32) -> u32 {
    if matches!(policy, Policy::KeepRecent) {
        dropped.load(Ordering::Relaxed)
    } else {
        dropped.swap(0, Ordering::Relaxed)
    }
}

/// Account for a line that lost the race for the last slot: `is_full` said
/// there was room, and another task filled it before this one got there.
///
/// Under a delta policy the line was carrying the count it [`claim`]ed, so
/// that goes back along with the line itself — otherwise the gap it was about
/// to report would vanish with it. Under `keep-recent` nothing was taken, so
/// only the line itself is new loss.
// Called only from `board.rs`, which a host build does not compile; the tests
// below are the other caller.
#[cfg_attr(not(target_os = "none"), allow(dead_code))]
#[inline(always)]
fn refund(policy: Policy, dropped: &AtomicU32, lost: u32) {
    if matches!(policy, Policy::KeepRecent) {
        dropped.fetch_add(1, Ordering::Relaxed);
    } else {
        dropped.fetch_add(lost + 1, Ordering::Relaxed);
    }
}

/// Log a line, `println!`-style. Callable from any task.
///
/// ```ignore
/// usb_log::log!("worst wakeup lateness so far: {} us", worst);
/// ```
#[macro_export]
macro_rules! log {
    ($($arg:tt)*) => {
        $crate::log(::core::format_args!($($arg)*))
    };
}

/// Log a line that goes to the serial port but is **not** kept in the retained
/// ring. See [`log_transient`] for why that distinction exists.
///
/// ```ignore
/// usb_log::log_transient!("http: served request #{}", n);
/// ```
#[macro_export]
macro_rules! log_transient {
    ($($arg:tt)*) => {
        $crate::log_transient(::core::format_args!($($arg)*))
    };
}

#[cfg(test)]
mod tests {
    //! Named after the wrong answer each one prevents. A log that misreports is
    //! worse than no log: the rounds it costs look like rounds spent on the
    //! subject.

    extern crate std;
    use std::string::String;

    use super::*;

    fn text(line: &Line) -> String {
        String::from_utf8(line.buf[..line.len].to_vec()).unwrap()
    }

    fn filled(n: usize) -> Line {
        let mut line = Line::new();
        for _ in 0..n {
            let _ = line.write_str("x");
        }
        line
    }

    // --- cutting a line at LINE_CAPACITY -----------------------------------

    #[test]
    fn a_line_that_exactly_fits_is_not_called_truncated() {
        let line = filled(LINE_CAPACITY);
        assert_eq!(line.len, LINE_CAPACITY);
        assert!(!line.truncated);
    }

    #[test]
    fn one_byte_over_is_cut_and_says_so() {
        let mut line = filled(LINE_CAPACITY);
        let _ = line.write_str("y");
        assert_eq!(line.len, LINE_CAPACITY);
        assert!(line.truncated);
        assert!(text(&line).bytes().all(|b| b == b'x'), "the overflow must not overwrite what fitted");
    }

    #[test]
    fn a_write_that_straddles_the_end_keeps_the_part_that_fits() {
        let mut line = filled(LINE_CAPACITY - 3);
        let _ = line.write_str("abcdef");
        assert_eq!(line.len, LINE_CAPACITY);
        assert!(line.truncated);
        assert!(text(&line).ends_with("xabc"));
    }

    #[test]
    fn a_full_line_never_makes_the_caller_handle_an_error() {
        // A logging path that can fail becomes one callers stop using.
        let mut line = filled(LINE_CAPACITY);
        assert!(line.write_str("more").is_ok());
        assert!(write!(&mut line, "{}", 12345).is_ok());
        assert_eq!(line.len, LINE_CAPACITY);
    }

    #[test]
    fn an_empty_write_is_not_a_truncation() {
        let mut line = filled(LINE_CAPACITY);
        let _ = line.write_str("");
        assert!(!line.truncated);
    }

    // --- claiming and refunding the loss count -----------------------------

    #[test]
    fn a_delta_is_reported_once_and_not_again() {
        for policy in [Policy::DropNewest, Policy::SilentWhileIdle] {
            let dropped = AtomicU32::new(5);
            assert_eq!(claim(policy, &dropped), 5);
            assert_eq!(claim(policy, &dropped), 0, "{policy:?} reported one gap twice");
        }
    }

    #[test]
    fn keep_recent_repeats_the_total_on_every_line() {
        // Because the line carrying it may itself be evicted, every later line
        // has to say it again or the gap is undercounted.
        let dropped = AtomicU32::new(5);
        assert_eq!(claim(Policy::KeepRecent, &dropped), 5);
        assert_eq!(claim(Policy::KeepRecent, &dropped), 5);
    }

    #[test]
    fn a_line_that_loses_the_race_takes_its_gap_down_with_it_unless_refunded() {
        // Under a delta the lost line was carrying the count it claimed. The
        // refund puts back that count and the line itself, so the next
        // survivor reports the whole gap: 3 earlier, plus this one.
        for policy in [Policy::DropNewest, Policy::SilentWhileIdle] {
            let dropped = AtomicU32::new(3);
            let lost = claim(policy, &dropped);
            refund(policy, &dropped, lost);
            assert_eq!(claim(policy, &dropped), 4, "{policy:?}");
        }
    }

    #[test]
    fn keep_recent_refunds_only_the_line_because_it_took_nothing() {
        let dropped = AtomicU32::new(3);
        let lost = claim(Policy::KeepRecent, &dropped);
        refund(Policy::KeepRecent, &dropped, lost);
        assert_eq!(claim(Policy::KeepRecent, &dropped), 4, "a refund of lost + 1 would count the gap twice");
    }

    #[test]
    fn every_dropped_line_is_reported_exactly_once_under_a_delta() {
        // The accounting end to end, with no queue: drops, a survivor, a lost
        // race, more drops, a survivor. What the survivors say must add up to
        // what was dropped — no more, no less.
        for policy in [Policy::DropNewest, Policy::SilentWhileIdle] {
            let dropped = AtomicU32::new(0);
            let mut reported = 0;
            let mut really_lost = 0;

            for _ in 0..4 {
                dropped.fetch_add(1, Ordering::Relaxed);
                really_lost += 1;
            }
            reported += claim(policy, &dropped); // a survivor

            let lost = claim(policy, &dropped); // a line that loses the race
            refund(policy, &dropped, lost);
            really_lost += 1;

            for _ in 0..2 {
                dropped.fetch_add(1, Ordering::Relaxed);
                really_lost += 1;
            }
            reported += claim(policy, &dropped); // the next survivor

            assert_eq!(reported, really_lost, "{policy:?}");
            assert_eq!(dropped.load(Ordering::Relaxed), 0);
        }
    }

    #[test]
    fn keep_recents_last_line_knows_the_whole_total() {
        let dropped = AtomicU32::new(0);
        for _ in 0..4 {
            dropped.fetch_add(1, Ordering::Relaxed);
        }
        let lost = claim(Policy::KeepRecent, &dropped);
        refund(Policy::KeepRecent, &dropped, lost);
        dropped.fetch_add(2, Ordering::Relaxed);
        assert_eq!(claim(Policy::KeepRecent, &dropped), 7);
    }

    // --- the build-time choice ---------------------------------------------

    #[test]
    fn the_default_build_still_refuses_the_newest() {
        // The module docs promise this "always will be". The CI job builds
        // this crate with its default features, so a change of default is a
        // failing test rather than a quietly different log.
        if !cfg!(feature = "keep-recent") && !cfg!(feature = "silent-while-idle") {
            assert_eq!(POLICY, Policy::DropNewest);
        }
    }
}
