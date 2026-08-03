//! What a bounded log queue should do when it is full — and when nobody is
//! reading it at all.
//!
//! # The false dichotomy this crate exists to correct
//!
//! `crates/usb-log` states the problem like this, and the statement is wrong:
//!
//! > It has to give somewhere, and there are only two choices: **wait** for
//! > room, or **drop** the line.
//!
//! Waiting is genuinely disqualified — it is the original bug wearing a hat,
//! and exp104 measured what it costs (two counter values 21 seconds apart).
//! But "drop the line" hides a second question that nobody asked:
//!
//! > **which** line?
//!
//! A queue that refuses the newest arrival keeps the *oldest* entries. A queue
//! that evicts its head to make room keeps the *newest*. Both are "dropping",
//! both preserve the caller's timing exactly, both cost the same RAM — and
//! they hand a reader two entirely different logs.
//!
//! # Which one is right depends on why you are reading
//!
//! - Chasing a **crash**, you want what came *before* it. The last thing the
//!   firmware managed to say is often the least interesting line in the file;
//!   the cause is further up. Keep the oldest.
//! - Asking **what is it doing now**, you want the most recent seconds. The
//!   boot banner from five minutes ago tells you nothing you did not already
//!   know. Keep the newest.
//!
//! Neither is universally correct, which is exactly why this is a policy and
//! not a constant. What *is* universally correct is counting the loss, and
//! that is not a policy — it stays unconditional in the caller.
//!
//! # And a third option that is not about fullness at all
//!
//! On a USB CDC device the log has an audience only while the host has the
//! port open. Before that, every line is being queued for a reader who may
//! never arrive, and by the time one does the queue holds a snapshot of
//! ancient history plus a large loss count.
//!
//! [`Policy::SilentWhileIdle`] refuses to queue anything while no reader is
//! present. It keeps *nothing*, counts *everything*, and guarantees that the
//! first line a reader sees describes the present. That is a real trade — the
//! content is genuinely gone — and it is the right one when the reason nobody
//! was listening is simply that the operator had not opened the page yet.
//!
//! # Why this is a crate and not three lines in `usb-log`
//!
//! Because `usb-log` cannot be tested. It depends on `embassy-rp`, so it only
//! compiles for the board, and every question here — what survives, what is
//! counted, what happens at the boundaries — is answerable with no hardware
//! at all. Reaching the interesting states on a board takes minutes of
//! deliberate idling per case. Here it takes a function call.
//!
//! The caller keeps the queue. This crate is handed two facts about it and
//! returns one instruction.

#![no_std]

/// What to do with a line that has just been formatted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Admission {
    /// Put it in the queue. There was room, or room is not the question.
    Enqueue,

    /// Refuse it, and count it as lost. The queue is unchanged.
    Drop,

    /// Discard the oldest queued line, count *that* one as lost, then enqueue
    /// this one.
    ///
    /// Returned only when the queue is full, so there is always something to
    /// discard. A caller that acts on this against an empty queue has a bug
    /// somewhere else — see `an_empty_queue_is_never_asked_to_evict`.
    EvictOldest,
}

/// How a full queue, or an unread one, should behave.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Policy {
    /// Refuse new lines while full. Keeps the oldest; the default, and what
    /// `Channel::try_send` does on its own.
    DropNewest,

    /// Evict the oldest to make room. Keeps the most recent, so a reader who
    /// connects late sees the seconds just before they arrived.
    KeepRecent,

    /// Queue nothing at all while no reader is present.
    ///
    /// When a reader *is* present this behaves exactly like
    /// [`Policy::DropNewest`]: a full queue then means a slow reader rather
    /// than an absent one, and evicting under a reader's feet would delete
    /// lines that were about to be delivered.
    SilentWhileIdle,
}

impl Policy {
    /// A short name, for a firmware that has to say which build it is.
    ///
    /// It matters more here than it usually would. Under
    /// [`Policy::KeepRecent`] the boot banner is the *first* thing evicted, so
    /// a build that announced itself only at startup would be unidentifiable
    /// by the time anybody connected — which is the failure this policy is
    /// meant to fix, reappearing as a way to hide which policy is running.
    pub const fn name(self) -> &'static str {
        match self {
            Policy::DropNewest => "drop-newest",
            Policy::KeepRecent => "keep-recent",
            Policy::SilentWhileIdle => "silent-while-idle",
        }
    }
}

/// The one question the caller asks.
///
/// `full` is the queue's own answer about itself, and `reader_present` is
/// whether the host currently has the port open. Everything else — the depth,
/// the line length, how the loss is counted — belongs to the caller.
pub const fn admit(policy: Policy, full: bool, reader_present: bool) -> Admission {
    // Checked before fullness, deliberately. The whole point of this policy is
    // that an empty queue with no audience is still the wrong place to put a
    // line: it will be stale by the time anyone reads it, and it will push out
    // the line that would have been useful.
    if matches!(policy, Policy::SilentWhileIdle) && !reader_present {
        return Admission::Drop;
    }

    if !full {
        return Admission::Enqueue;
    }

    match policy {
        Policy::DropNewest | Policy::SilentWhileIdle => Admission::Drop,
        Policy::KeepRecent => Admission::EvictOldest,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [Policy; 3] = [Policy::DropNewest, Policy::KeepRecent, Policy::SilentWhileIdle];

    #[test]
    fn room_and_a_reader_means_every_policy_agrees() {
        for p in ALL {
            assert_eq!(admit(p, false, true), Admission::Enqueue, "{p:?}");
        }
    }

    #[test]
    fn a_full_queue_is_where_they_part_company() {
        assert_eq!(admit(Policy::DropNewest, true, true), Admission::Drop);
        assert_eq!(admit(Policy::KeepRecent, true, true), Admission::EvictOldest);
        assert_eq!(admit(Policy::SilentWhileIdle, true, true), Admission::Drop);
    }

    #[test]
    fn only_one_policy_cares_whether_anybody_is_listening() {
        // The other two must be blind to it. If that ever changes, the
        // reader flag has grown a second meaning and this test is the place
        // that finds out.
        for p in [Policy::DropNewest, Policy::KeepRecent] {
            assert_eq!(admit(p, false, true), admit(p, false, false), "{p:?}");
            assert_eq!(admit(p, true, true), admit(p, true, false), "{p:?}");
        }
        assert_ne!(
            admit(Policy::SilentWhileIdle, false, true),
            admit(Policy::SilentWhileIdle, false, false)
        );
    }

    #[test]
    fn silence_applies_to_an_empty_queue_too() {
        // The tempting implementation checks fullness first and only then asks
        // about the reader. It would enqueue happily into an empty queue with
        // nobody there, which is the exact behaviour this policy exists to
        // stop — and it would still pass every other test here.
        assert_eq!(admit(Policy::SilentWhileIdle, false, false), Admission::Drop);
    }

    #[test]
    fn an_empty_queue_is_never_asked_to_evict() {
        // `EvictOldest` promises the caller there is something to discard.
        // A queue that is not full is not empty-proof, but a queue that is not
        // full must never be told to evict, because the caller would then
        // discard a line it did not have to lose.
        for p in ALL {
            assert_ne!(admit(p, false, true), Admission::EvictOldest, "{p:?}");
            assert_ne!(admit(p, false, false), Admission::EvictOldest, "{p:?}");
        }
    }

    #[test]
    fn nothing_is_ever_told_to_wait() {
        // There is no `Admission::Wait`, and there must never be one. Waiting
        // is the original bug: exp104 measured two counter values arriving 21
        // seconds apart because the caller was parked inside `write_all`. This
        // test is a reminder in executable form — if a fourth variant appears,
        // it has to justify itself here first.
        for p in ALL {
            for full in [true, false] {
                for reader in [true, false] {
                    let a = admit(p, full, reader);
                    assert!(
                        matches!(a, Admission::Enqueue | Admission::Drop | Admission::EvictOldest),
                        "{p:?} {full} {reader}"
                    );
                }
            }
        }
    }

    /// The behaviour the repository already ships, restated as a test.
    ///
    /// `usb-log` today calls `Channel::try_send` and counts the failure. That
    /// is `DropNewest` exactly, and this asserts the equivalence — so the
    /// default build cannot change behaviour by accident while this crate is
    /// being edited.
    #[test]
    fn drop_newest_is_what_try_send_already_does() {
        assert_eq!(admit(Policy::DropNewest, false, true), Admission::Enqueue);
        assert_eq!(admit(Policy::DropNewest, false, false), Admission::Enqueue);
        assert_eq!(admit(Policy::DropNewest, true, true), Admission::Drop);
        assert_eq!(admit(Policy::DropNewest, true, false), Admission::Drop);
    }

    /// A queue of three, ten lines logged, and nobody reading until the end.
    ///
    /// Returns what a reader would then find, and how many lines were counted
    /// lost. One call at a time the policies look like hair-splitting; over a
    /// sequence the difference is the whole experiment, and this is the shape
    /// a person actually meets.
    fn simulate(policy: Policy, reader_present: bool) -> ([u32; 3], usize, u32) {
        let mut q = [0u32; 3];
        let mut len = 0usize;
        let mut lost = 0u32;

        for line in 1..=10u32 {
            match admit(policy, len == q.len(), reader_present) {
                Admission::Enqueue => {
                    q[len] = line;
                    len += 1;
                }
                Admission::Drop => lost += 1,
                Admission::EvictOldest => {
                    // Discard the head, shuffle down, append. A real queue
                    // moves an index instead; the visible result is the same
                    // and this way the test reads like the diagram.
                    lost += 1;
                    q.copy_within(1.., 0);
                    q[len - 1] = line;
                }
            }
        }
        (q, len, lost)
    }

    #[test]
    fn ten_lines_into_a_queue_of_three_with_nobody_reading() {
        // The oldest three. Lines 4 to 10 never happened, as far as a reader
        // can tell — and this is what the repository ships today, which is why
        // connecting a page after two idle minutes shows two-minute-old state.
        assert_eq!(simulate(Policy::DropNewest, false), ([1, 2, 3], 3, 7));

        // The newest three.
        assert_eq!(simulate(Policy::KeepRecent, false), ([8, 9, 10], 3, 7));

        // Nothing at all, and an honest count. Note it loses *ten*, not seven:
        // the three the others kept were never worth keeping, and this policy
        // says so rather than pretending a stale line is a delivered one.
        assert_eq!(simulate(Policy::SilentWhileIdle, false), ([0, 0, 0], 0, 10));
    }

    #[test]
    fn with_a_reader_present_two_of_the_three_are_indistinguishable() {
        // The reader flag changes only `SilentWhileIdle`, and once a reader is
        // there it collapses onto the default. That is the point: it is a
        // policy about *absence*, and it must not quietly become a policy
        // about slowness.
        assert_eq!(
            simulate(Policy::SilentWhileIdle, true),
            simulate(Policy::DropNewest, true)
        );
        assert_eq!(simulate(Policy::DropNewest, true), ([1, 2, 3], 3, 7));
    }
}
