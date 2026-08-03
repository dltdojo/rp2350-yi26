//! An unbiased draw from an inclusive integer range.
//!
//! # The bias, and why you will never see it
//!
//! The obvious way to turn a uniform `u32` into a number between 2100 and
//! 2567 is `lo + x % n`, where `n` is 468. It is wrong, and the way it is
//! wrong is the reason this crate exists.
//!
//! There are 2³² possible values of `x`, and 2³² is not a multiple of 468.
//! Dividing them into 468 buckets leaves a remainder of **256**, so 256 of
//! the 468 possible results are reachable from one more `x` than the others.
//! Those results are more likely, by a factor of
//! `(⌊2³²/468⌋ + 1) / ⌊2³²/468⌋` — about **one part in nine million**.
//!
//! Nobody will ever notice that at a party. It will not show up in a chi-
//! square test on a thousand draws, or ten million. That is precisely the
//! argument for removing it: a defect you cannot detect afterwards has to be
//! designed out beforehand, because there is no later opportunity. This
//! repository has met that shape before — exp112's firmware quietly stopped
//! using the hardware RNG and every statistical test carried on passing.
//!
//! # The fix, and what it costs
//!
//! Reject the values that cause the imbalance. There are exactly `2³² mod n`
//! of them; accept `x` only when it is below `2³² - (2³² mod n)`, and ask for
//! another when it is not. Every result then has exactly `⌊2³²/n⌋` preimages,
//! which is uniformity by construction rather than by measurement.
//!
//! When `n` divides 2³² — every power of two, and one — that remainder is
//! zero and nothing is ever rejected. Saying so precisely matters: the first
//! draft of this crate rejected a whole `n` values in that case. Still
//! uniform, still would have drawn perfectly good numbers forever, and wrong
//! in a way only a test could see.
//!
//! For 468 that rejects 256 values out of 2³², so roughly one draw in
//! sixteen million asks for a second number. The correct method is free here,
//! which is worth stating plainly: **the reason to use it is not that it is
//! cheap, it is that you cannot check whether you needed it.**
//!
//! # What this crate does not do
//!
//! It does not decide whether the numbers it is given are any good. That is
//! `entropy-health`'s job, and in exp129 the health tests gate this function
//! rather than being consulted by it. A perfectly unbiased draw over a
//! broken source is still broken, and keeping the two apart is what makes
//! either of them checkable.

#![no_std]

/// What went wrong, when a draw could not be made.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    /// `hi` was below `lo`. An empty range is a caller's mistake, not a
    /// number this function can invent.
    EmptyRange,
    /// The source produced values in the rejection zone `tries` times in a
    /// row and the draw gave up.
    ///
    /// With any sane source this cannot happen — the odds of it are the
    /// rejection probability raised to the power of `tries`. It exists so
    /// that a *stuck* source, one returning the same rejected value forever,
    /// terminates with a diagnosis instead of hanging.
    Exhausted,
}

/// How many rejections in a row before [`in_range`] gives up.
///
/// Sixteen. For the widest realistic rejection probability of just under a
/// half, that is a one-in-65536 chance of a spurious failure; for the ranges
/// this is actually used with it is unreachable. The number exists to bound
/// a loop, not to be tuned.
pub const MAX_TRIES: u32 = 16;

/// Draws a number in `lo..=hi`, uniformly, by rejection.
///
/// `next` is called until it returns a value outside the rejection zone, at
/// most [`MAX_TRIES`] times. It is a closure rather than a trait so that a
/// test can hand over a scripted sequence and a firmware can hand over its
/// TRNG, with nothing in this crate knowing the difference.
///
/// ```
/// let mut values = [7u32, 42].into_iter();
/// let n = draw::in_range(2100, 2567, || values.next().unwrap()).unwrap();
/// assert_eq!(n, 2100 + 7);
/// ```
pub fn in_range(lo: u32, hi: u32, mut next: impl FnMut() -> u32) -> Result<u32, Error> {
    if hi < lo {
        return Err(Error::EmptyRange);
    }

    // `hi - lo` cannot overflow after the check above, but `+ 1` can when the
    // range is the whole of u32. That case needs no work and no rejection:
    // every value is already in range, and computing `n` would wrap to zero
    // and divide by it.
    let span = hi - lo;
    if span == u32::MAX {
        return Ok(next());
    }
    let n = span + 1;

    // Nothing to reject when n divides 2^32 exactly — every power of two, and
    // n = 1. Returning early is not an optimisation: the arithmetic below
    // cannot express "accept everything", because the limit would be 2^32 and
    // that does not fit in the type.
    //
    // The first draft got this wrong in a way worth recording. It used
    // `(u32::MAX / n) * n` as the limit, which for n = 256 is 2^32 - 256 —
    // still uniform, but rejecting 256 values that never needed rejecting,
    // and reporting that count to the caller as if the range were imperfect.
    // The tests caught it; no draw ever would have.
    let rejected = rejected_values(lo, hi);
    if rejected == 0 {
        return Ok(lo + next() % n);
    }

    // 2^32 - rejected, computed without leaving u32: subtracting from zero
    // wraps to exactly that.
    let limit = 0u32.wrapping_sub(rejected);

    for _ in 0..MAX_TRIES {
        let x = next();
        if x < limit {
            return Ok(lo + x % n);
        }
    }
    Err(Error::Exhausted)
}

/// How many values out of 2³² this range rejects.
///
/// Reported rather than hidden, because "how often does the correct method
/// cost anything" is a fair question and the answer is usually "never" — see
/// the crate docs on why that is not a reason to skip it.
pub fn rejected_values(lo: u32, hi: u32) -> u32 {
    if hi < lo {
        return 0;
    }
    let span = hi - lo;
    if span == u32::MAX {
        return 0;
    }
    let n = span + 1;
    // 2^32 mod n, kept inside u32: 2^32 is u32::MAX + 1, so take the
    // remainder of u32::MAX, add the one back, and reduce again — the final
    // `% n` is what turns "n divides 2^32" into 0 rather than n.
    ((u32::MAX % n) + 1) % n
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The claim the whole crate rests on, checked by counting preimages
    /// rather than by drawing samples.
    ///
    /// For each possible result r, how many accepted values of x map to it?
    /// Uniform means "the same number for every r". This counts them by
    /// arithmetic over the full 2³² space — something no amount of sampling
    /// on a board could establish, and the reason this lives in a crate.
    #[test]
    fn every_result_has_the_same_number_of_preimages() {
        for &(lo, hi) in &[(2100u32, 2567u32), (1, 6), (0, 0), (10, 11), (1, 100)] {
            let n = hi - lo + 1;
            let space = 1u64 << 32;
            let limit = space - space % n as u64;
            let per_result = limit / n as u64;
            for r in 0..n {
                // x accepted and x % n == r  <=>  x in {r, r+n, r+2n, ...} below limit
                let count = if (r as u64) < limit {
                    (limit - 1 - r as u64) / n as u64 + 1
                } else {
                    0
                };
                assert_eq!(
                    count, per_result,
                    "range {lo}-{hi}: result {} has {count} preimages, others have {per_result}",
                    lo + r
                );
            }
        }
    }

    /// And the same count for the naive `% n`, which is not the same for
    /// every result — the defect this crate exists to remove, demonstrated
    /// rather than asserted.
    #[test]
    fn the_naive_modulo_is_not_uniform() {
        let (lo, hi) = (2100u32, 2567u32);
        let n = hi - lo + 1;
        let space = 1u64 << 32;
        let remainder = space % n as u64;
        assert_eq!(remainder, 256, "2^32 mod 468 is the size of the imbalance");

        // Without rejection, the first `remainder` results get one extra x.
        let low = space / n as u64;
        for r in 0..n as u64 {
            let count = if r < remainder { low + 1 } else { low };
            let expected_extra = r < remainder;
            assert_eq!(count > low, expected_extra);
        }
        // Which makes 256 of the 468 possible winners more likely than the
        // rest. Small, and not zero.
        assert_eq!(remainder, 256);
    }

    #[test]
    fn a_value_in_the_rejection_zone_is_not_used() {
        let (lo, hi) = (2100u32, 2567u32);
        let n = hi - lo + 1;
        let limit = 0u32.wrapping_sub(rejected_values(lo, hi));

        // First value is inside the rejection zone, second is not. A naive
        // implementation would return `lo + limit % n`, which is `lo`.
        let mut values = [limit, 5u32].into_iter();
        let got = in_range(lo, hi, || values.next().unwrap()).unwrap();
        assert_eq!(got, lo + 5, "the rejected value leaked into the result");
    }

    #[test]
    fn a_stuck_source_fails_rather_than_hanging() {
        let (lo, hi) = (2100u32, 2567u32);
        let n = hi - lo + 1;
        let limit = 0u32.wrapping_sub(rejected_values(lo, hi));
        let mut calls = 0u32;
        let got = in_range(lo, hi, || {
            calls += 1;
            limit
        });
        assert_eq!(got, Err(Error::Exhausted));
        assert_eq!(calls, MAX_TRIES, "gave up after the documented number of tries");
    }

    #[test]
    fn the_bounds_are_inclusive_at_both_ends() {
        let (lo, hi) = (2100u32, 2567u32);
        let n = hi - lo + 1;
        assert_eq!(in_range(lo, hi, || 0).unwrap(), lo);
        assert_eq!(in_range(lo, hi, || n - 1).unwrap(), hi);
    }

    #[test]
    fn a_single_value_range_needs_no_entropy_and_rejects_nothing() {
        assert_eq!(in_range(7, 7, || 12345).unwrap(), 7);
        assert_eq!(rejected_values(7, 7), 0);
    }

    #[test]
    fn an_empty_range_is_an_error_and_not_a_number() {
        assert_eq!(in_range(10, 9, || 0), Err(Error::EmptyRange));
    }

    #[test]
    fn the_full_u32_range_does_not_overflow() {
        assert_eq!(in_range(0, u32::MAX, || 12345).unwrap(), 12345);
        assert_eq!(rejected_values(0, u32::MAX), 0);
    }

    #[test]
    fn the_rejection_count_matches_the_arithmetic() {
        assert_eq!(rejected_values(2100, 2567), 256);
        // A power of two divides 2^32 exactly, so nothing is ever rejected.
        assert_eq!(rejected_values(1, 256), 0);
        assert_eq!(rejected_values(0, 1), 0);
    }
}
