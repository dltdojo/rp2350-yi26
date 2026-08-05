//! The last few log lines, kept where something other than the serial port can
//! read them.
//!
//! [`usb-log`](../usb-log/) drains its queue into a USB endpoint and forgets
//! each line as it goes. That is the right design for it: a queue that
//! remembers is a queue that fills up, and the whole point of that crate is
//! that logging never stalls the thing being logged.
//!
//! But it means the log has exactly one reader, and reaching it needs the CDC
//! interface — which needs WebUSB in a browser, which a phone may not have.
//! A board that serves its own log over HTTP needs a *second* copy, with
//! different rules: nothing waits for it, nothing blocks on it, and it throws
//! away the oldest rather than the newest, because a reader who arrives late
//! wants what just happened and not what happened first.
//!
//! # What it is
//!
//! A fixed array of fixed-width lines with a write cursor that wraps. No
//! allocator, no growth, no failure mode. Pushing into a full ring overwrites
//! the oldest line, and the count of lines lost that way is kept so a reader
//! can be told rather than misled.
//!
//! ```
//! let mut ring: log_ring::Ring<4, 16> = log_ring::Ring::new();
//! ring.push(b"first");
//! ring.push(b"second");
//! let mut seen = alloc::vec::Vec::new();
//! # extern crate alloc;
//! ring.for_each(|line| seen.push(core::str::from_utf8(line).unwrap().to_string()));
//! assert_eq!(seen, ["first", "second"]);
//! ```
//!
//! # The two numbers that decide everything
//!
//! `LINES` and `WIDTH` multiply into the SRAM this costs, and both truncate
//! rather than fail: a line longer than `WIDTH` is cut, and a ring fuller than
//! `LINES` drops its oldest. Neither is an error, because a log that can fail
//! is a log that callers stop calling.

#![no_std]
#![forbid(unsafe_code)]

/// The most recent `LINES` lines, each up to `WIDTH` bytes.
pub struct Ring<const LINES: usize, const WIDTH: usize> {
    buf: [[u8; WIDTH]; LINES],
    len: [u16; LINES],
    /// Where the next line goes. Wraps.
    next: usize,
    /// How many have ever been pushed — the reader needs this to know whether
    /// the ring has wrapped at all.
    pushed: u32,
    /// How many were overwritten before anybody read them.
    lost: u32,
}

impl<const LINES: usize, const WIDTH: usize> Default for Ring<LINES, WIDTH> {
    fn default() -> Self {
        Self::new()
    }
}

impl<const LINES: usize, const WIDTH: usize> Ring<LINES, WIDTH> {
    pub const fn new() -> Self {
        Self {
            buf: [[0; WIDTH]; LINES],
            len: [0; LINES],
            next: 0,
            pushed: 0,
            lost: 0,
        }
    }

    /// Add a line, overwriting the oldest if the ring is full.
    ///
    /// Truncates at `WIDTH` rather than refusing. A caller that has to handle
    /// a failed log call is a caller that will eventually stop making them.
    pub fn push(&mut self, line: &[u8]) {
        let n = if line.len() > WIDTH { WIDTH } else { line.len() };
        self.buf[self.next][..n].copy_from_slice(&line[..n]);
        self.len[self.next] = n as u16;
        self.next = (self.next + 1) % LINES;
        if self.pushed >= LINES as u32 {
            self.lost += 1;
        }
        self.pushed += 1;
    }

    /// Every line held, oldest first.
    pub fn for_each(&self, mut f: impl FnMut(&[u8])) {
        let held = self.held();
        // Start at the oldest: the cursor when the ring has wrapped, or zero
        // when it has not.
        let start = if self.pushed as usize > LINES { self.next } else { 0 };
        for i in 0..held {
            let idx = (start + i) % LINES;
            f(&self.buf[idx][..self.len[idx] as usize]);
        }
    }

    /// How many lines are in the ring right now.
    pub fn held(&self) -> usize {
        if (self.pushed as usize) < LINES {
            self.pushed as usize
        } else {
            LINES
        }
    }

    /// How many were overwritten before anyone read them. Reported rather than
    /// hidden: a reader shown a gap and not told about it draws conclusions
    /// from a log that is missing its middle.
    pub fn lost(&self) -> u32 {
        self.lost
    }

    /// Total ever pushed, held or not.
    pub fn pushed(&self) -> u32 {
        self.pushed
    }
}

#[cfg(test)]
extern crate alloc;

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::string::String;
    use alloc::vec::Vec;

    fn drain<const L: usize, const W: usize>(r: &Ring<L, W>) -> Vec<String> {
        let mut out = Vec::new();
        r.for_each(|l| out.push(String::from_utf8_lossy(l).into_owned()));
        out
    }

    #[test]
    fn empty_yields_nothing() {
        let r: Ring<4, 8> = Ring::new();
        assert_eq!(drain(&r).len(), 0);
        assert_eq!(r.held(), 0);
        assert_eq!(r.lost(), 0);
    }

    #[test]
    fn keeps_order_before_it_wraps() {
        let mut r: Ring<4, 8> = Ring::new();
        for s in ["a", "b", "c"] {
            r.push(s.as_bytes());
        }
        assert_eq!(drain(&r), ["a", "b", "c"]);
        assert_eq!(r.lost(), 0, "nothing was overwritten");
    }

    #[test]
    fn exactly_full_has_lost_nothing() {
        let mut r: Ring<3, 8> = Ring::new();
        for s in ["a", "b", "c"] {
            r.push(s.as_bytes());
        }
        assert_eq!(drain(&r), ["a", "b", "c"]);
        assert_eq!(r.held(), 3);
        assert_eq!(r.lost(), 0, "a full ring has not yet dropped anything");
    }

    /// The behaviour that makes this different from `usb-log`'s queue: the
    /// **oldest** goes, not the newest. A reader who arrives late wants what
    /// just happened.
    #[test]
    fn wrapping_drops_the_oldest_and_says_how_many() {
        let mut r: Ring<3, 8> = Ring::new();
        for s in ["a", "b", "c", "d", "e"] {
            r.push(s.as_bytes());
        }
        assert_eq!(drain(&r), ["c", "d", "e"]);
        assert_eq!(r.lost(), 2);
        assert_eq!(r.pushed(), 5);
    }

    #[test]
    fn a_long_line_is_cut_not_refused() {
        let mut r: Ring<2, 4> = Ring::new();
        r.push(b"abcdefgh");
        assert_eq!(drain(&r), ["abcd"]);
    }

    #[test]
    fn a_reused_slot_does_not_show_the_previous_line_s_tail() {
        // The bug this exists to prevent: writing four bytes over a slot that
        // held eight and then reading eight back.
        let mut r: Ring<1, 8> = Ring::new();
        r.push(b"llllllll");
        r.push(b"s");
        assert_eq!(drain(&r), ["s"]);
    }

    #[test]
    fn an_empty_line_is_a_line() {
        let mut r: Ring<3, 8> = Ring::new();
        r.push(b"a");
        r.push(b"");
        r.push(b"c");
        assert_eq!(drain(&r), ["a", "", "c"]);
        assert_eq!(r.held(), 3);
    }

    /// Wrapping many times over must not drift: the ring is a modulo, and an
    /// off-by-one in the start index only shows up after the second wrap.
    #[test]
    fn many_wraps_still_yield_the_last_n_in_order() {
        let mut r: Ring<4, 8> = Ring::new();
        for i in 0..1000u32 {
            let mut b = [0u8; 8];
            let s = alloc::format!("{}", i);
            b[..s.len()].copy_from_slice(s.as_bytes());
            r.push(&b[..s.len()]);
        }
        assert_eq!(drain(&r), ["996", "997", "998", "999"]);
        assert_eq!(r.lost(), 996);
    }
}
