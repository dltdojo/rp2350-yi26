// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 rp2350-yi26 contributors
//! The same key every time, out of a source that is never the same twice.
//!
//! [exp181] enrolled a 256-bit key against SRAM bank 8's startup pattern and
//! reconstructed it on the next power cycle — **all 256 bits came back**, from
//! a window whose cells had moved by 6.22%. [exp182] then put that key behind a
//! working authenticator, and [exp175]'s forgery, unchanged, found nothing in
//! the image. This crate is the arithmetic those two used, lifted out of
//! exp182's `main.rs` so a second experiment can have it without a `cp`.
//!
//! # What a fuzzy commitment is, in one paragraph
//!
//! A physical source gives you `w` — 4 KB of ones and zeros that are *mostly*
//! the same on every boot of the same chip, and different on a different chip.
//! Mostly is the problem: a key that is wrong in one bit is wrong. So the key
//! `K` is not derived from `w` at all. It is **chosen**, and what gets stored is
//! `H = K ⊕ w` — the helper data, which is one half of an XOR whose other half
//! only exists inside a powered chip. Reconstruction is `K = H ⊕ w'`, and the
//! bits where `w'` disagrees with `w` are exactly the bits that come back wrong.
//!
//! Error correction is the crude kind, and crude is the point here: each key bit
//! is spread across [`REPEAT`] cells and recovered by majority vote. Sixteen of
//! thirty-one cells have to flip before one key bit does. exp181 measured 1.93
//! flips per bit on average, so the code was nowhere near its limit — and
//! [`reconstruct`] returns that number, because a reconstruction that succeeded
//! by luck and one that succeeded with room to spare are different results.
//!
//! # What this crate is not
//!
//! - **Not a PUF.** It is the code around one. Whether the window it is handed
//!   is stable, and whether it is *unique to a board*, are properties of the
//!   silicon; exp181 showed the first on one board and could not show the
//!   second. A source that is stable but not unique makes this reconstruct
//!   somebody else's key perfectly.
//! - **Not a place to hide a key while it is in use.** [exp163] measured that
//!   and it applies unchanged.
//! - **Not hardware.** Nothing here reads SRAM or flash. The window arrives as
//!   a slice and the record as bytes, which is why every line of it can be
//!   tested on a host with no board — and why the two things that *are*
//!   hardware, the bank 8 address and where the record lives in flash, stay in
//!   the experiment that owns them.
//!
//! [exp163]: ../../experiments/exp163-how-long-is-a-secret-in-the-open/
//! [exp175]: ../../experiments/exp175-the-secret-is-the-file/
//! [exp181]: ../../experiments/exp181-a-key-that-is-written-nowhere/
//! [exp182]: ../../experiments/exp182-where-the-wrapping-key-comes-from/

#![cfg_attr(not(test), no_std)]

use sha2::{Digest, Sha256};

/// How many bytes of noisy source one enrolment consumes.
pub const WINDOW_BYTES: usize = 4096;
const WINDOW_BITS: usize = WINDOW_BYTES * 8;

/// The key this crate commits to and recovers.
pub const KEY_BITS: usize = 256;
/// Bytes of key. 32.
pub const KEY_BYTES: usize = KEY_BITS / 8;

/// Cells per key bit. **Odd, or a majority vote has no majority** — the
/// assertion below is not decoration.
pub const REPEAT: usize = 31;
/// Cells one enrolment actually consumes: 256 × 31 = 7,936.
///
/// Public because it is the denominator of the only number that says whether a
/// reconstruction had room to spare — exp181's was 494 of these.
pub const USED_BITS: usize = KEY_BITS * REPEAT;

/// Bytes of helper data. It is not the key and it is not secret; publishing it
/// costs nothing without the window it was made against.
pub const HELPER_BYTES: usize = USED_BITS / 8;

const _: () = assert!(USED_BITS <= WINDOW_BITS, "the window is smaller than the code needs");
const _: () = assert!(REPEAT % 2 == 1, "an even repetition has no majority");

/// The band a window's one-bit share must fall in, per mille, for enrolment to
/// be allowed.
///
/// **This guard is the one that matters most and the least obvious.** The path
/// that puts firmware on the chip zeroes SRAM, so a window read on the boot
/// straight after a flash is all zeros — and enrolling there stores
/// `H = K ⊕ 0 = K`, which is the key, in the clear, in flash. exp179 measured
/// 50.5–51.2% one-bits on a real cold boot and 127 of 130 blocks all-zero after
/// a flash, which is what these numbers are drawn from.
pub const UNIFORMITY_MIN: u32 = 400;
/// Upper end of the band. See [`UNIFORMITY_MIN`].
pub const UNIFORMITY_MAX: u32 = 600;

/// Marks a record as this crate's rather than whatever else is at that address.
pub const RECORD_MAGIC: u32 = 0x8181_5241;

/// What enrolment leaves behind. **None of it is the key.**
///
/// `repr(C)` because it is written to flash as its own bytes and read back by
/// mapping this type over them. The parameters travel with it so that a build
/// which changed [`REPEAT`] cannot silently misread a record made by one that
/// did not — [`Record::usable`] is that check.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Record {
    pub magic: u32,
    pub key_bits: u32,
    pub repeat: u32,
    /// The window's one-bit share at enrolment, per mille. Kept so a transcript
    /// can say what the source looked like on the day.
    pub uniformity_per_mille: u32,
    /// SHA-256 of the key. Lets a reconstruction check itself without the key
    /// ever being in flash.
    pub key_hash: [u8; 32],
    pub helper: [u8; HELPER_BYTES],
}

impl Record {
    /// Is this a record this build can act on?
    ///
    /// Three things, and the last two are why the parameters are stored at all:
    /// the magic is present, and the key length and repetition match what this
    /// build was compiled with.
    pub fn usable(&self) -> bool {
        self.magic == RECORD_MAGIC
            && self.key_bits == KEY_BITS as u32
            && self.repeat == REPEAT as u32
    }
}

fn bit(buf: &[u8], i: usize) -> u8 {
    (buf[i / 8] >> (i % 8)) & 1
}

fn set_bit(buf: &mut [u8], i: usize, v: u8) {
    if v != 0 {
        buf[i / 8] |= 1 << (i % 8);
    } else {
        buf[i / 8] &= !(1 << (i % 8));
    }
}

/// A window's one-bit share, per mille.
///
/// Compare it against [`UNIFORMITY_MIN`]..=[`UNIFORMITY_MAX`] **before**
/// enrolling. A window of zeros scores 0 and is the failure that guard exists
/// for.
pub fn uniformity(window: &[u8; WINDOW_BYTES]) -> u32 {
    let ones: u32 = window.iter().map(|b| b.count_ones()).sum();
    (ones as u64 * 1000 / WINDOW_BITS as u64) as u32
}

/// `H = K ⊕ w`, with each key bit spread across [`REPEAT`] cells.
///
/// The result is safe to store in the clear. Without a window close to the one
/// it was made against it is 992 bytes of nothing.
pub fn helper(key: &[u8; KEY_BYTES], window: &[u8; WINDOW_BYTES]) -> [u8; HELPER_BYTES] {
    let mut h = [0u8; HELPER_BYTES];
    for i in 0..USED_BITS {
        set_bit(&mut h, i, bit(key, i / REPEAT) ^ bit(window, i));
    }
    h
}

/// `K = H ⊕ w'`, by majority vote, and **how much room was left**.
///
/// The second return value counts cells that disagreed with the majority — the
/// distance between this window and the one enrolment saw. It is not an error
/// count in the sense of "things that went wrong": a reconstruction with 494 of
/// 7,936 cells changed and one with 3,900 both return the right key, and only
/// one of them is a result anybody should be comfortable with. Report it.
pub fn reconstruct(
    helper: &[u8; HELPER_BYTES],
    window: &[u8; WINDOW_BYTES],
) -> ([u8; KEY_BYTES], u32) {
    let mut key = [0u8; KEY_BYTES];
    let mut minority = 0u32;
    for j in 0..KEY_BITS {
        let mut ones = 0usize;
        for r in 0..REPEAT {
            let i = j * REPEAT + r;
            ones += (bit(helper, i) ^ bit(window, i)) as usize;
        }
        let majority = if ones * 2 > REPEAT { 1 } else { 0 };
        set_bit(&mut key, j, majority);
        minority += if majority == 1 { (REPEAT - ones) as u32 } else { ones as u32 };
    }
    (key, minority)
}

/// SHA-256 of a key, for the `key_hash` a [`Record`] carries.
pub fn hash(key: &[u8; KEY_BYTES]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(key);
    h.finalize().into()
}

/// How many cells may flip in one key bit's [`REPEAT`] before the vote turns.
/// 16 of 31, so 15 is the last safe number.
pub const CORRECTABLE_PER_BIT: usize = REPEAT / 2;

#[cfg(test)]
mod tests {
    use super::*;

    /// A window that is not all zeros and not all ones, deterministically.
    fn window(seed: u8) -> [u8; WINDOW_BYTES] {
        let mut w = [0u8; WINDOW_BYTES];
        let mut x = seed as u32 | 1;
        for b in w.iter_mut() {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            *b = (x & 0xff) as u8;
        }
        w
    }

    fn flip(w: &mut [u8; WINDOW_BYTES], count: usize, stride: usize) {
        for n in 0..count {
            let i = (n * stride) % USED_BITS;
            let v = bit(w, i) ^ 1;
            set_bit(w, i, v);
        }
    }

    const KEY: [u8; KEY_BYTES] = *b"a key nobody chose at random....";

    #[test]
    fn a_clean_window_gives_the_key_back() {
        let w = window(7);
        let h = helper(&KEY, &w);
        let (k, minority) = reconstruct(&h, &w);
        assert_eq!(k, KEY);
        assert_eq!(minority, 0, "an unchanged window should have nothing in the minority");
    }

    /// The helper data is one half of an XOR. On its own it is not the key, and
    /// this is the assertion that says so rather than the prose above.
    #[test]
    fn the_helper_is_not_the_key() {
        let w = window(7);
        let h = helper(&KEY, &w);
        assert_ne!(&h[..KEY_BYTES], &KEY[..]);
        // And against a window it was not made against, it recovers nothing.
        let (k, _) = reconstruct(&h, &window(9));
        assert_ne!(k, KEY);
    }

    /// A zeroed window is what the flashing path leaves behind, and enrolling
    /// there would store `H = K ⊕ 0 = K`. The guard is a number, so here is the
    /// number failing.
    #[test]
    fn a_zeroed_window_is_refused_by_the_uniformity_guard() {
        let zeros = [0u8; WINDOW_BYTES];
        assert_eq!(uniformity(&zeros), 0);
        assert!(!(UNIFORMITY_MIN..=UNIFORMITY_MAX).contains(&uniformity(&zeros)));
        // And it is not a theoretical worry. With `w = 0`, `H = K ⊕ 0` — so the
        // helper data alone, sitting in flash where anybody can read it, is the
        // key. That is the whole reason the band exists.
        let h = helper(&KEY, &zeros);
        for j in 0..KEY_BITS {
            for r in 0..REPEAT {
                assert_eq!(bit(&h, j * REPEAT + r), bit(&KEY, j),
                    "every cell of key bit {j} is the key bit itself");
            }
        }
    }

    /// A real window scores near half, which is what the band is drawn around.
    #[test]
    fn a_plausible_window_lands_inside_the_band() {
        let u = uniformity(&window(3));
        assert!((UNIFORMITY_MIN..=UNIFORMITY_MAX).contains(&u), "{u} per mille");
    }

    /// Fifteen flips in a bit's cells is survivable and sixteen is not. This is
    /// the code's limit stated as a test rather than as a comment.
    #[test]
    fn the_vote_turns_at_sixteen_of_thirty_one() {
        let w = window(11);
        let h = helper(&KEY, &w);

        let mut nearly = w;
        for r in 0..CORRECTABLE_PER_BIT {
            let i = r;
            let v = bit(&nearly, i) ^ 1;
            set_bit(&mut nearly, i, v);
        }
        assert_eq!(reconstruct(&h, &nearly).0, KEY, "15 of 31 must still vote the right way");

        let mut over = w;
        for r in 0..=CORRECTABLE_PER_BIT {
            let i = r;
            let v = bit(&over, i) ^ 1;
            set_bit(&mut over, i, v);
        }
        assert_ne!(reconstruct(&h, &over).0, KEY, "16 of 31 must turn the first key bit");
    }

    /// exp181 measured 494 of 7,936 cells changed — 6.22% — and all 256 bits
    /// came back. Noise spread thinly is what this code is for.
    #[test]
    fn six_percent_of_cells_scattered_is_survivable() {
        let w = window(5);
        let h = helper(&KEY, &w);
        let mut noisy = w;
        flip(&mut noisy, 494, 17);
        let (k, minority) = reconstruct(&h, &noisy);
        assert_eq!(k, KEY);
        assert!(minority > 0 && minority < USED_BITS as u32, "{minority}");
    }

    #[test]
    fn a_record_names_the_build_that_made_it() {
        let r = Record {
            magic: RECORD_MAGIC,
            key_bits: KEY_BITS as u32,
            repeat: REPEAT as u32,
            uniformity_per_mille: 511,
            key_hash: hash(&KEY),
            helper: helper(&KEY, &window(1)),
        };
        assert!(r.usable());
        assert!(!Record { magic: 0, ..r }.usable());
        assert!(!Record { repeat: 29, ..r }.usable(), "a different code must not be read as this one");
        assert!(!Record { key_bits: 128, ..r }.usable());
    }

    #[test]
    fn the_hash_is_what_lets_a_reconstruction_check_itself() {
        let w = window(2);
        let h = helper(&KEY, &w);
        let (k, _) = reconstruct(&h, &w);
        assert_eq!(hash(&k), hash(&KEY));
        assert_ne!(hash(&reconstruct(&h, &window(4)).0), hash(&KEY));
    }
}
