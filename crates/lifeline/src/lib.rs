// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 rp2350-yi26 contributors
//! A board that cannot be reached is a walk to a bench. This is how it stops.
//!
//! # The problem, counted
//!
//! One round of work on the authenticator road cost **four trips to a bench**,
//! and every one was the same shape: firmware died, and with it went USB, the
//! log, and the 1200-baud watcher that lets a host reboot the board. What was
//! left was a device that had to be unplugged, held down, and plugged back in
//! by a person standing there.
//!
//! | what died | why nobody could reach it |
//! |---|---|
//! | a `StaticCell` claimed twice, panicking on the second CBOR command | `panic-halt` halts in silence; the executor stopped and took CDC, HID and the reboot watcher with it |
//! | an HID interface declared with no task servicing it | the whole device left the USB bus |
//! | `SecretKey::from_slice` on thirty-two zero bytes, before USB was serving | the board never appeared at all |
//!
//! None of those is exotic. All three are ordinary bugs, and the reason each
//! one cost a walk is that **nothing was watching**.
//!
//! # The three things this does
//!
//! 1. **An armed watchdog**, from [`breadcrumb`], which catches what no fault
//!    handler can: a firmware that is not dead but stuck. Nothing feeds it, so
//!    it resets the board — and a board that resets is a board still reachable.
//! 2. **A death with a name.** The panic and hard-fault handlers **reboot**
//!    rather than halting, and the note that survives says which. Trying to log
//!    from inside a panic is what failed on the bench: the log is a ring drained
//!    by a task that is no longer running. The next boot reports it instead.
//! 3. **A boot loop handed to the bootrom, not to a person.** This is the part
//!    that removes the trip. If three boots in a row die before the firmware
//!    says it is reachable, the fourth does not try again — it calls
//!    `reset_to_usb_boot`, and the board appears as the `RP2350` drive with
//!    nobody touching anything. `yi26 flash` then works.
//!
//! # What counts as *up*
//!
//! [`alive`], called once, at the earliest moment the host can reach this board.
//! **The firmware decides where that is** — this crate does not know what USB
//! is, and must not: [exp103] has no USB at all, and a component that watched
//! for enumeration would be useless to it.
//!
//! A boot that reached [`alive`] is never counted towards the escape, however
//! it dies afterwards. That is deliberate: a board that got up is a board a host
//! could reach, so the 1200-baud touch is still the answer for it. The escape is
//! only for the case where nothing else can work.
//!
//! # Why the escape is on by default
//!
//! It is a `default` Cargo feature, following [`usb_reboot`]'s ruling on the
//! same trade-off: the convenience is the point, and turning it off is a build
//! flag rather than an edit. Landing in the bootloader looks alarming — a board
//! in BOOTSEL presents a drive and runs nothing — but for an experiment board
//! that is strictly better than a board which looks identical to a broken
//! cable. A firmware that must never do this builds with
//! `default-features = false`.
//!
//! [exp103]: ../../../experiments/exp103-embassy-blink/
//! [`usb_reboot`]: ../../usb-reboot/

#![cfg_attr(not(test), no_std)]

#[cfg(target_os = "none")]
pub use breadcrumb::Cause;

/// How long the firmware has to reach [`alive`] before the watchdog gives up.
///
/// Generous, because it covers everything a board does on the way up — USB
/// enumeration, a host opening the log, tasks being spawned. exp189's first log
/// line lands at about 3 s on a quiet host.
pub const DEFAULT_BOOT_US: u32 = 8_000_000;

/// How long a running firmware may go without feeding the watchdog.
///
/// Short, because after [`alive`] the only reason nothing feeds it is that
/// nothing is running.
pub const DEFAULT_RUN_US: u32 = 3_000_000;

/// Boots that never got up, after which the board is handed to the bootrom.
///
/// Three, not two. Two consecutive deaths can be one flaky power-up; three in
/// the same place is deterministic, and the cost of being sure is two reset
/// cycles — a few seconds — against a person walking to a bench.
pub const DEFAULT_ESCAPE_AFTER: u8 = 3;

/// The step number [`alive`] is recorded at, kept out of the way of an
/// experiment's own steps.
pub(crate) const STEP_BOOTING: u8 = 16;

#[derive(Clone, Copy, Debug)]
pub struct Config {
    pub boot_us: u32,
    pub run_us: u32,
    pub escape_after: u8,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            boot_us: DEFAULT_BOOT_US,
            run_us: DEFAULT_RUN_US,
            escape_after: DEFAULT_ESCAPE_AFTER,
        }
    }
}

/// What a boot should do about the boots before it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// Carry on, and this is the tally to write back — this boot is presumed
    /// dead until it says otherwise.
    Try(u8),
    /// Enough. Hand the board to the ROM bootloader instead of failing again.
    HandOver,
}

/// The whole policy, and it is four lines.
///
/// `tally` is how many boots in a row have died before saying they were
/// reachable; a boot that gets up clears it. This takes a number and returns a
/// decision, so it is the one part of this crate a host can run — the rest
/// touches the watchdog, the ROM or a peripheral and cannot be tested anywhere
/// but on a board.
///
/// **It counts before it tries, not after.** A boot that increments on the way
/// in is a boot that is recorded as dead even if it dies before it could record
/// anything — which is the only case that matters, because a firmware that dies
/// on the way up is exactly the one with no way to tell anybody.
pub fn decide(tally: u8, escape_after: u8) -> Decision {
    if tally >= escape_after {
        Decision::HandOver
    } else {
        Decision::Try(tally.saturating_add(1))
    }
}

#[cfg(target_os = "none")]
mod board;
#[cfg(target_os = "none")]
pub use board::*;

#[cfg(test)]
mod tests {
    use super::*;

    const AFTER: u8 = DEFAULT_ESCAPE_AFTER;

    #[test]
    fn a_board_that_has_never_failed_just_tries() {
        assert_eq!(decide(0, AFTER), Decision::Try(1));
    }

    /// The boundary, stated as a test rather than as a comment: two is not yet
    /// a boot loop and three is.
    #[test]
    fn two_is_not_yet_a_boot_loop_and_three_is() {
        assert_eq!(decide(1, AFTER), Decision::Try(2));
        assert_eq!(decide(2, AFTER), Decision::Try(3));
        assert_eq!(decide(3, AFTER), Decision::HandOver);
    }

    /// **It counts on the way in.** A boot that only recorded its death on the
    /// way out would record nothing at all when it died on the way up, which is
    /// the only case this crate exists for.
    #[test]
    fn the_tally_rises_before_the_attempt_not_after() {
        let mut tally = 0;
        for expected in 1..=3 {
            match decide(tally, AFTER) {
                Decision::Try(next) => {
                    assert_eq!(next, expected);
                    tally = next;
                }
                Decision::HandOver => panic!("too early at {tally}"),
            }
        }
        assert_eq!(decide(tally, AFTER), Decision::HandOver);
    }

    /// Two bits hold 0..=3, so the count saturates rather than rolling — a
    /// tally that wrapped to zero would be a board that never gives up.
    #[test]
    fn the_count_saturates_rather_than_wrapping() {
        assert_eq!(decide(u8::MAX, AFTER), Decision::HandOver);
        assert_eq!(decide(0, 255), Decision::Try(1));
        assert_eq!(decide(255, 255), Decision::HandOver);
    }

    /// A threshold of zero hands over immediately, which is a legitimate thing
    /// to ask for and must not loop.
    #[test]
    fn a_threshold_of_zero_hands_over_at_once() {
        assert_eq!(decide(0, 0), Decision::HandOver);
    }
}
