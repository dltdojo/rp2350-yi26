//! A CRC32 you can forge to any value by changing four bytes, and a hash you
//! cannot.
//!
//! The design note this arc came from says an update should "write to Slot B,
//! then verify the CRC". A CRC catches a cable that dropped a bit. It does not
//! catch a file made *for* you, and the difference between those two is the
//! whole of why *reliability* and *authenticity* are different words.
//!
//! This crate demonstrates the difference rather than asserting it. It forges
//! a CRC — produces an image that is a different image and whose CRC32 is
//! nonetheless exactly the one you were checking against — and then runs the
//! same attack against SHA-256 and shows where it breaks.
//!
//! # Why four bytes in the middle, not four bytes on the end
//!
//! Appending a correction is arithmetic too, and a bootloader that checks a
//! fixed-size region rejects it for being the wrong length. The interesting
//! forgery keeps the size and the structure: it changes four bytes *inside*
//! the image — a slice of padding, a spare word — so the result is the same
//! length, mounts and parses the same way, and passes the check. That is the
//! forgery a real loader would accept.
//!
//! # Why it works on CRC and not on a hash
//!
//! CRC32 is **linear over GF(2)**. Flipping an input bit flips a fixed set of
//! output bits, every time, regardless of the other input bits. So "which four
//! bytes make the CRC come out to X" is a system of 32 linear equations in 32
//! unknowns, and linear systems are solved, not searched. [`forge_crc32`] does
//! exactly that and always succeeds when the four bytes are independent enough
//! — which, for CRC32, they are.
//!
//! A cryptographic hash is built to destroy that. In SHA-256 the output bits a
//! flipped input bit changes *depend on all the other input bits*, so there is
//! no fixed matrix to solve. [`forge_hash_the_same_way`] builds the matrix
//! anyway, on the pretence that the hash is linear, and returns the four bytes
//! that pretence produces — which do not work, and the test that calls it
//! proves they do not.

// std, because this is a host-side tool that runs under `cargo test`, never on
// the board. Nothing in this crate is `no_std`, and nothing needs to be.

use sha2::{Digest, Sha256};

/// The IEEE CRC32 used by zlib, PNG, and most "checksum" fields — reflected,
/// polynomial `0xEDB88320`, init and xorout all-ones.
///
/// Written out by hand rather than table-driven: the inner loop *is* the
/// linearity the rest of this crate exploits. Each step shifts and
/// conditionally XORs a constant, and there is not a nonlinear operation
/// anywhere in it.
pub fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &b in bytes {
        crc ^= b as u32;
        for _ in 0..8 {
            let take = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & take);
        }
    }
    !crc
}

/// SHA-256, for the half of the comparison that is supposed to resist this.
pub fn sha256(bytes: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(bytes);
    h.finalize().into()
}

/// Change the four bytes at `offset` so that `crc32(image)` equals `target`.
///
/// Returns `true` on success. It fails only if the four bytes cannot span the
/// space of CRC values — which for CRC32 and four independent bytes does not
/// happen, and the failure path exists for honesty rather than because it is
/// reached.
///
/// The image keeps its length and every other byte. That is the property that
/// makes this a forgery a loader would accept, rather than a corruption a
/// loader would notice.
pub fn forge_crc32(image: &mut [u8], offset: usize, target: u32) -> bool {
    assert!(offset + 4 <= image.len(), "the four-byte window is off the end");

    // Zero the window, and measure the CRC of everything else. Every bit we
    // set from here contributes linearly on top of this baseline.
    for b in &mut image[offset..offset + 4] {
        *b = 0;
    }
    let base = crc32(image);

    // The effect of each of the 32 window bits, one at a time: set it, see how
    // the CRC moves from the baseline, put it back. `delta[i]` is that move.
    let mut delta = [0u32; 32];
    for bit in 0..32 {
        flip(image, offset, bit);
        delta[bit] = crc32(image) ^ base;
        flip(image, offset, bit);
    }

    // Solve  XOR of chosen deltas = target ^ base  over GF(2), remembering
    // which input bits each basis vector was built from.
    let Some(solution) = solve(&delta, target ^ base) else {
        return false;
    };

    for bit in 0..32 {
        if solution & (1 << bit) != 0 {
            flip(image, offset, bit);
        }
    }
    crc32(image) == target
}

/// Run the exact same attack against SHA-256, and return the four bytes it
/// produces — which will not work.
///
/// This is not a real attack and makes no attempt to be. It builds the same
/// 32×32 matrix `forge_crc32` builds, from the same per-bit measurements, and
/// solves it the same way. The point is *where* it goes wrong: the matrix is a
/// lie, because a hash's response to a flipped bit is not fixed. The four
/// bytes come back, you write them in, and the hash is not the target — which
/// is what the caller asserts.
///
/// Returns the forged window bytes, for the caller to apply and check.
pub fn forge_hash_the_same_way(image: &mut [u8], offset: usize, target: &[u8; 32]) -> [u8; 4] {
    assert!(offset + 4 <= image.len());

    // Take the low 32 bits of the hash as the "value" to solve for — the same
    // width CRC works in. Any 32 bits would do; the attack fails on all of
    // them, and picking a slice keeps the linear-algebra machinery identical.
    let target32 = u32::from_le_bytes([target[0], target[1], target[2], target[3]]);

    for b in &mut image[offset..offset + 4] {
        *b = 0;
    }
    let base = low32(&sha256(image));

    let mut delta = [0u32; 32];
    for bit in 0..32 {
        flip(image, offset, bit);
        delta[bit] = low32(&sha256(image)) ^ base;
        flip(image, offset, bit);
    }

    let solution = solve(&delta, target32 ^ base).unwrap_or(0);

    let mut window = [0u8; 4];
    for bit in 0..32 {
        if solution & (1 << bit) != 0 {
            window[bit / 8] ^= 1 << (bit % 8);
        }
    }
    window
}

/// Flip one bit of the four-byte window.
fn flip(image: &mut [u8], offset: usize, bit: usize) {
    image[offset + bit / 8] ^= 1 << (bit % 8);
}

/// The low 32 bits of a hash, little-endian.
fn low32(h: &[u8; 32]) -> u32 {
    u32::from_le_bytes([h[0], h[1], h[2], h[3]])
}

/// Solve `XOR of chosen delta[i] == goal` over GF(2), returning the chosen set
/// of `i`s as a bitmask, or `None` if no combination reaches `goal`.
///
/// A linear basis with provenance: each basis vector remembers which input
/// bits it was assembled from, so once `goal` is reduced to zero the
/// accumulated provenance *is* the answer.
fn solve(delta: &[u32; 32], goal: u32) -> Option<u32> {
    // basis[p] is a vector whose highest set bit is p (or 0 if that pivot is
    // empty); prov[p] is the set of input bits that XOR to basis[p].
    let mut basis = [0u32; 32];
    let mut prov = [0u32; 32];

    for (i, &d) in delta.iter().enumerate() {
        let mut v = d;
        let mut m = 1u32 << i;
        for p in (0..32).rev() {
            if (v >> p) & 1 == 0 {
                continue;
            }
            if basis[p] == 0 {
                basis[p] = v;
                prov[p] = m;
                break;
            }
            v ^= basis[p];
            m ^= prov[p];
        }
    }

    let mut g = goal;
    let mut answer = 0u32;
    for p in (0..32).rev() {
        if (g >> p) & 1 == 1 {
            if basis[p] == 0 {
                return None;
            }
            g ^= basis[p];
            answer ^= prov[p];
        }
    }
    Some(answer)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A pretend firmware image, deterministic so the numbers are stable.
    ///
    /// A plain LCG, the same one exp136 uses, so anyone can regenerate it. The
    /// last sixteen bytes are zeroed to stand in for padding — the spare room a
    /// forgery hides in, which every real image has.
    fn image(seed: u32, len: usize) -> Vec<u8> {
        let mut s = seed;
        let mut out: Vec<u8> = (0..len)
            .map(|_| {
                s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (s >> 24) as u8
            })
            .collect();
        let n = out.len();
        out[n - 16..].fill(0);
        out
    }

    #[test]
    fn crc32_matches_the_reference_vector() {
        // The check value everyone uses, from the CRC catalogue.
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
    }

    /// The forgery, end to end.
    ///
    /// `good` is your firmware; `target` is the CRC you would check an update
    /// against. `evil` is somebody else's image — real content, different from
    /// yours — and after forging four bytes of its padding it carries your CRC.
    #[test]
    fn a_forged_image_passes_the_crc_check() {
        let good = image(0x0000_1000, 512);
        let target = crc32(&good);

        let mut evil = image(0xDEAD_BEEF, 512);
        assert_ne!(crc32(&evil), target, "the two images differ to begin with");

        let padding = evil.len() - 16;
        assert!(forge_crc32(&mut evil, padding, target));

        // It passes the check...
        assert_eq!(crc32(&evil), target);
        // ...and it is still a different image from the one whose CRC it wears.
        assert_ne!(evil, good);
        // ...at exactly the same size.
        assert_eq!(evil.len(), good.len());
    }

    #[test]
    fn only_the_four_bytes_moved() {
        let mut evil = image(0xDEAD_BEEF, 512);
        let before = evil.clone();
        let padding = evil.len() - 16;
        forge_crc32(&mut evil, padding, 0x1234_5678);

        let changed: usize = before
            .iter()
            .zip(&evil)
            .filter(|(a, b)| a != b)
            .count();
        assert!(changed <= 4, "a forgery must not disturb the rest of the image");
    }

    /// The same attack, against a hash, failing.
    ///
    /// This is the experiment's whole point stated as an assertion: the
    /// identical linear method that forges a CRC produces four bytes that do
    /// not make SHA-256 come out to the target. Not "harder" — the method does
    /// not apply, because the matrix it depends on does not exist for a hash.
    #[test]
    fn the_same_attack_does_not_forge_a_hash() {
        let good = image(0x0000_1000, 512);
        let target = sha256(&good);

        let mut evil = image(0xDEAD_BEEF, 512);
        let padding = evil.len() - 16;

        let window = forge_hash_the_same_way(&mut evil, padding, &target);
        // Apply what the linear method proposed.
        for (i, w) in window.iter().enumerate() {
            evil[padding + i] = *w;
        }

        // The whole hash is wrong. Even the 32 bits the method tried to fix
        // are, overwhelmingly, wrong — the point is not that it missed by a
        // little, it is that there was nothing to solve.
        assert_ne!(sha256(&evil), target);
    }

    /// A hash *can* be made to match — by the only method left when the linear
    /// one is gone: try inputs until one hashes right. Here, over a tiny space
    /// so the test finishes, to show what forging a hash actually costs.
    #[test]
    fn forging_a_hash_means_searching_and_that_is_the_cost() {
        // A four-bit target: find a two-byte suffix whose hash starts with a
        // chosen nibble. Trivial here; the real thing is 256 bits.
        let want_first_nibble = 0x0a;
        let mut found = None;
        for candidate in 0u16..=u16::MAX {
            let h = sha256(&candidate.to_le_bytes());
            if h[0] >> 4 == want_first_nibble {
                found = Some(candidate);
                break;
            }
        }
        // It exists, and it was found by *searching*, not solving — which is
        // the entire difference. Scale the four bits to 256 and the search
        // stops finishing.
        assert!(found.is_some());
    }
}
