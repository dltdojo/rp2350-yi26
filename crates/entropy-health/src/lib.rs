//! The two continuous health tests from NIST SP 800-90B, section 4.4.
//!
//! exp111 counted ones and counted changes, printed two percentages, and said
//! plainly that this was monitoring rather than certification. This module is
//! what the monitoring is supposed to look like when it is written down by a
//! standards body instead of invented on the spot.
//!
//! Two differences from exp111's tests matter more than the arithmetic.
//!
//! **The thresholds are derived, not chosen.** Both cutoffs come from a stated
//! false-positive rate — α = 2^-20, about one spurious alarm per million
//! samples — and an assumed min-entropy per sample. Nobody picked 21 or 589
//! because they looked strict enough.
//!
//! **Failing means refusing.** A test that prints a percentage and carries on
//! is a report. A health test stops the source from being used. That is the
//! whole difference, and it is one `if`.

// `no_std` for the firmware, `std` under `cargo test` so the harness can run
// on the host. That is not a compromise — running these tests is the reason
// this crate has no dependencies at all. The cutoffs are the part most likely
// to be wrong, and a wrong threshold still produces confident output.
#![cfg_attr(not(test), no_std)]

/// Per-sample min-entropy the cutoffs below assume, in bits.
///
/// One bit per bit is the most demanding assumption available for a binary
/// source, and therefore the right one for something claiming to be a TRNG:
/// it produces the tightest cutoffs and the most sensitive tests. A source
/// assessed at less would get looser bounds and catch less.
///
/// SP 800-90B expects this to come from an entropy assessment of the specific
/// noise source. This is not that assessment, and calling it one would be the
/// kind of claim exp112 is about.
pub const ASSUMED_H: f32 = 1.0;

/// Repetition Count Test cutoff.
///
/// `C = 1 + ceil(-log2(α) / H)` with α = 2^-20 and H = 1, so `C = 21`.
///
/// Catches catastrophic failure: a source that has stuck. Twenty-one identical
/// bits in a row from a fair coin has probability 2^-20, which is exactly the
/// false-positive rate being spent.
pub const RCT_CUTOFF: u32 = 21;

/// Adaptive Proportion Test window, in samples.
pub const APT_WINDOW: u32 = 1024;

/// Adaptive Proportion Test cutoff.
///
/// The smallest `C` for which `P(Binomial(1024, 2^-H) >= C) <= 2^-20`, which
/// for H = 1 is **589** against a window mean of 512.
///
/// Catches a large loss of entropy rather than a total one: a source that
/// still changes, but has developed a strong preference. That is the failure
/// mode a repetition count cannot see.
pub const APT_CUTOFF: u32 = 589;

/// Which test failed, and what it saw.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Failure {
    /// The same bit repeated this many times in a row.
    Repetition { run: u32 },
    /// This many samples in one window matched the window's first sample.
    Proportion { count: u32 },
}

/// Continuous health tests over a stream of bits.
///
/// Fed one bit at a time, forever. Once it fails it stays failed — recovery
/// from a health test failure is a policy decision for whoever owns the
/// source, and silently resuming is not one of the reasonable options.
pub struct Health {
    // Repetition count state.
    last: Option<bool>,
    run: u32,

    // Adaptive proportion state.
    window_ref: Option<bool>,
    window_seen: u32,
    window_matches: u32,

    failed: Option<Failure>,
    total: u32,
}

impl Health {
    pub const fn new() -> Self {
        Self {
            last: None,
            run: 0,
            window_ref: None,
            window_seen: 0,
            window_matches: 0,
            failed: None,
            total: 0,
        }
    }

    pub fn failed(&self) -> Option<Failure> {
        self.failed
    }

    pub fn total(&self) -> u32 {
        self.total
    }

    /// How far through the current adaptive-proportion window we are, and how
    /// many samples so far matched its reference. Reported so the log shows
    /// the test working rather than only its verdict — a health check that
    /// only speaks when it fails gives no way to tell it apart from a health
    /// check that is not running.
    pub fn window_progress(&self) -> (u32, u32) {
        (self.window_seen, self.window_matches)
    }

    /// Feeds one bit. Returns the failure if this bit caused one.
    pub fn push(&mut self, bit: bool) -> Option<Failure> {
        if self.failed.is_some() {
            return self.failed;
        }
        self.total += 1;

        // -- Repetition Count Test -------------------------------------------
        match self.last {
            Some(prev) if prev == bit => self.run += 1,
            _ => self.run = 1,
        }
        self.last = Some(bit);
        if self.run >= RCT_CUTOFF {
            self.failed = Some(Failure::Repetition { run: self.run });
            return self.failed;
        }

        // -- Adaptive Proportion Test ----------------------------------------
        //
        // The first sample of each window is the reference and counts as a
        // match, per the standard. The window then runs to APT_WINDOW samples
        // and the verdict is taken at the end of it.
        match self.window_ref {
            None => {
                self.window_ref = Some(bit);
                self.window_seen = 1;
                self.window_matches = 1;
            }
            Some(r) => {
                self.window_seen += 1;
                if bit == r {
                    self.window_matches += 1;
                }
                if self.window_seen >= APT_WINDOW {
                    if self.window_matches >= APT_CUTOFF {
                        self.failed = Some(Failure::Proportion {
                            count: self.window_matches,
                        });
                        return self.failed;
                    }
                    self.window_ref = None;
                    self.window_seen = 0;
                    self.window_matches = 0;
                }
            }
        }

        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The cutoffs are the experiment. If either drifts, the tests below stop
    /// meaning what the standard says they mean — silently, because a wrong
    /// threshold still produces confident output.
    #[test]
    fn cutoffs_match_the_standard_for_one_bit_of_entropy() {
        // C = 1 + ceil(20 / H), H = 1.
        assert_eq!(RCT_CUTOFF, 21);
        // Smallest C with P(Binomial(1024, 0.5) >= C) <= 2^-20.
        assert_eq!(APT_CUTOFF, 589);
        assert_eq!(APT_WINDOW, 1024);
        assert_eq!(ASSUMED_H, 1.0);
    }

    #[test]
    fn a_stuck_source_trips_the_repetition_count() {
        let mut h = Health::new();
        for i in 0..RCT_CUTOFF {
            let f = h.push(true);
            if i + 1 < RCT_CUTOFF {
                assert!(f.is_none(), "failed early at bit {}", i + 1);
            } else {
                assert!(matches!(f, Some(Failure::Repetition { run }) if run == RCT_CUTOFF));
            }
        }
    }

    /// One short of the cutoff must not fire. An off-by-one here would make
    /// the test stricter than the false-positive rate it claims to spend.
    #[test]
    fn a_run_one_short_of_the_cutoff_passes() {
        let mut h = Health::new();
        for _ in 0..(RCT_CUTOFF - 1) {
            assert!(h.push(false).is_none());
        }
        assert!(h.failed().is_none());
        assert!(h.push(true).is_none());
    }

    /// A biased-but-changing source is what the adaptive proportion test
    /// exists for: it never repeats enough to trip the repetition count.
    #[test]
    fn a_biased_source_trips_the_adaptive_proportion() {
        let mut h = Health::new();
        let mut failure = None;
        // Nine ones then a zero: 90% ones, longest run 9, well under 21.
        for i in 0..APT_WINDOW * 2 {
            if let Some(f) = h.push(i % 10 != 9) {
                failure = Some(f);
                break;
            }
        }
        match failure {
            Some(Failure::Proportion { count }) => assert!(count >= APT_CUTOFF),
            Some(Failure::Repetition { .. }) => panic!("repetition fired; the bias test did not"),
            None => panic!("a 90%-ones source passed both tests"),
        }
    }

    /// An alternating source is perfectly balanced and perfectly predictable.
    /// Both tests pass it, which is the honest limit of what they are for.
    #[test]
    fn a_perfectly_predictable_source_passes_both() {
        let mut h = Health::new();
        for i in 0..APT_WINDOW * 4 {
            assert!(h.push(i % 2 == 0).is_none());
        }
        assert!(h.failed().is_none());
    }
}
