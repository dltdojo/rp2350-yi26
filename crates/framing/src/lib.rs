//! Where a message boundary comes from, once you stop asking the transport
//! for one.
//!
//! [exp128](../../../experiments/exp128-reassemble-by-hand/) put the boundary
//! back by hand from USB's own short packet, and
//! [exp135](../../../experiments/exp135-a-packet-with-no-bytes/) paid what a
//! transport-level boundary costs: one unterminated message silently swallows
//! the next, and no terminator on the later message undoes it. So the boundary
//! moves up, into the bytes themselves.
//!
//! Two ways to do that, and this crate implements both:
//!
//! - [`length_prefix`] — a magic byte, then how many bytes follow. What real
//!   protocols on this ground ship, including a signed-transaction wallet whose
//!   frames were byte-identical over CDC and over a vendor interface.
//! - [`cobs`] — reserve one byte value as the delimiter and make it impossible
//!   for the payload to contain it. Consistent Overhead Byte Stuffing, 1999.
//!
//! # The one question they are judged on
//!
//! Not overhead, and not speed. **Join the stream halfway and see which one
//! can find the next boundary.**
//!
//! That is not a contrived test. A log page opened after the board has been
//! talking for a minute, a `yi26` that attaches mid-message, a cable pushed
//! back in — every one of them starts reading at a byte nobody chose. A
//! decoder that only works from the first byte of the stream works exactly
//! once.
//!
//! The two answers are structurally different, and the difference is the whole
//! point of the comparison:
//!
//! - Length-prefix resynchronises **by luck**. It hunts for the magic byte,
//!   and the magic byte can occur inside a payload. When it does, the decoder
//!   locks onto a header that is not one, reads a length that is not one, and
//!   spends that many bytes ignoring the real boundary inside them.
//! - COBS resynchronises **by construction**. The delimiter cannot appear in
//!   encoded data — that is the entire trick — so the next delimiter is always
//!   the next real boundary, whatever you were in the middle of.
//!
//! [`resync`] measures that rather than asserting it: it cuts an encoded
//! stream at every offset and reports what each decoder made of the tail.
//!
//! # What this crate does not claim
//!
//! It is not a framing layer you should adopt. It has no checksum, no version
//! byte, no command space, and no opinion about what a payload means — and a
//! frame layer without a checksum cannot tell a corrupted payload from a real
//! one, which matters more than resynchronisation in most protocols. The
//! comparison here is narrow on purpose.

#![cfg_attr(not(test), no_std)]

/// The longest payload either scheme will carry here.
///
/// 128 rather than 64: it has to be longer than a USB bulk packet, or every
/// message would fit in one packet and the reassembly this crate exists on top
/// of would never happen. exp128 uses the same number for the same reason.
pub const MAX_PAYLOAD: usize = 128;

/// What went wrong encoding a frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    /// The payload is longer than [`MAX_PAYLOAD`].
    PayloadTooLarge,
    /// The output buffer cannot hold the encoded frame.
    BufferTooSmall,
}

/// A decoder that is fed one byte at a time and says when a message ended.
///
/// One byte at a time, rather than one packet at a time, because the caller
/// does not get to choose where packets end — that is the lesson exp128 paid
/// for. A decoder that takes a packet is a decoder that believes in packets.
pub trait Deframer {
    /// Feed one byte. Returns the payload length when this byte completed a
    /// message; the bytes are then in [`payload`](Self::payload) until the
    /// next message starts.
    fn feed(&mut self, byte: u8) -> Option<usize>;

    /// The payload of the message just completed.
    fn payload(&self) -> &[u8];

    /// Bytes thrown away since the last complete message: everything the
    /// decoder read while it did not know where it was.
    ///
    /// This is the number that says how expensive joining halfway was, and it
    /// is why it is on the trait rather than in a test.
    fn discarded(&self) -> usize;
}

/// How a decoder is started, which turns out to be where the two schemes
/// differ before a single byte has been read.
pub trait Start: Deframer + Sized {
    /// Reading a stream from its first byte.
    fn fresh() -> Self;

    /// Reading a stream from somewhere in the middle, with no idea what came
    /// before.
    ///
    /// For [`cobs`] this is a different decoder: it knows it may be standing
    /// inside somebody else's message and refuses to emit whatever it
    /// assembles before the first delimiter. For [`length_prefix`] it is the
    /// same decoder, **because there is nothing it could usefully do
    /// differently** — hunting for a magic byte is all it ever does, and it
    /// cannot tell a real header from a payload that looks like one. That the
    /// two implementations of this function differ is the finding, not an
    /// implementation detail.
    fn joined() -> Self;
}

// ---------------------------------------------------------------------------

/// A magic byte, a length, and the payload.
///
/// ```text
/// ┌──────┬─────────┬─────────┬───────────────┐
/// │ 0xA5 │ len lo  │ len hi  │ payload …     │
/// └──────┴─────────┴─────────┴───────────────┘
/// ```
///
/// The length is little-endian and two bytes wide even though [`MAX_PAYLOAD`]
/// needs one, because that is what protocols actually ship and because the
/// second byte is where the interesting failure lives: a length field can
/// express 65535, so a decoder that trusts it can be sent past every boundary
/// in its buffer. The check against `MAX_PAYLOAD` is what stops that, and it
/// is also the only thing that makes resynchronisation possible at all.
pub mod length_prefix {
    use super::{Error, MAX_PAYLOAD};

    /// First byte of every frame. `0xA5` is the traditional choice — an
    /// alternating bit pattern is unlikely in text and visible in a hex dump —
    /// and being traditional does not make it absent from payloads.
    pub const MAGIC: u8 = 0xA5;

    /// Magic plus the two length bytes.
    pub const HEADER: usize = 3;

    /// Encode `payload` into `out`, returning the encoded length.
    pub fn encode(payload: &[u8], out: &mut [u8]) -> Result<usize, Error> {
        if payload.len() > MAX_PAYLOAD {
            return Err(Error::PayloadTooLarge);
        }
        let n = HEADER + payload.len();
        if out.len() < n {
            return Err(Error::BufferTooSmall);
        }
        out[0] = MAGIC;
        out[1] = payload.len() as u8;
        out[2] = (payload.len() >> 8) as u8;
        out[HEADER..n].copy_from_slice(payload);
        Ok(n)
    }

    /// Bytes an encoded frame costs beyond its payload. Always [`HEADER`].
    pub const fn overhead(_payload_len: usize) -> usize {
        HEADER
    }

    #[derive(Clone, Copy, PartialEq, Eq)]
    enum State {
        /// Hunting for the magic byte. Everything read here is discarded.
        Hunting,
        /// Magic seen; collecting the two length bytes.
        Length(u8),
        /// Header accepted; collecting `need` payload bytes.
        Body,
    }

    /// Byte-fed decoder for [`length_prefix`](self) frames.
    pub struct Deframer {
        buf: [u8; MAX_PAYLOAD],
        have: usize,
        need: usize,
        state: State,
        discarded: usize,
        len_lo: u8,
    }

    impl Deframer {
        pub const fn new() -> Self {
            Self {
                buf: [0; MAX_PAYLOAD],
                have: 0,
                need: 0,
                state: State::Hunting,
                discarded: 0,
                len_lo: 0,
            }
        }
    }

    impl Default for Deframer {
        fn default() -> Self {
            Self::new()
        }
    }

    impl super::Deframer for Deframer {
        fn feed(&mut self, byte: u8) -> Option<usize> {
            match self.state {
                State::Hunting => {
                    if byte == MAGIC {
                        self.state = State::Length(0);
                    } else {
                        // Not a boundary and not payload: a byte read while
                        // the decoder did not know where it was.
                        self.discarded += 1;
                    }
                    None
                }
                State::Length(0) => {
                    self.len_lo = byte;
                    self.state = State::Length(1);
                    None
                }
                State::Length(_) => {
                    let need = self.len_lo as usize | ((byte as usize) << 8);
                    if need == 0 || need > MAX_PAYLOAD {
                        // A length this decoder cannot honour. The three
                        // header bytes were not a header, so they were
                        // discarded — and the hunt restarts *after* them,
                        // which is the subtle part: a real magic byte inside
                        // those three is gone with them.
                        self.discarded += HEADER;
                        self.state = State::Hunting;
                    } else {
                        self.need = need;
                        self.have = 0;
                        self.state = State::Body;
                    }
                    None
                }
                State::Body => {
                    self.buf[self.have] = byte;
                    self.have += 1;
                    if self.have == self.need {
                        self.state = State::Hunting;
                        Some(self.need)
                    } else {
                        None
                    }
                }
            }
        }

        fn payload(&self) -> &[u8] {
            &self.buf[..self.have]
        }

        fn discarded(&self) -> usize {
            self.discarded
        }
    }

    impl super::Start for Deframer {
        fn fresh() -> Self {
            Self::new()
        }
        /// The same decoder. See [`Start::joined`](super::Start::joined).
        fn joined() -> Self {
            Self::new()
        }
    }

    /// Decode a whole stream, for tests and for the host side of the
    /// experiment. Returns the payloads in order.
    #[cfg(test)]
    pub fn decode_all(stream: &[u8]) -> alloc::vec::Vec<alloc::vec::Vec<u8>> {
        use super::Deframer as _;
        let mut d = Deframer::new();
        let mut out = alloc::vec::Vec::new();
        for &b in stream {
            if d.feed(b).is_some() {
                out.push(d.payload().to_vec());
            }
        }
        out
    }
}

// ---------------------------------------------------------------------------

/// Reserve a byte value, and make the payload unable to contain it.
///
/// Consistent Overhead Byte Stuffing (Cheshire & Baker, 1999). Zero is the
/// delimiter; the encoder replaces every zero in the payload with the distance
/// to the next one, and writes a leading code byte holding the distance to the
/// first. The decoder walks that chain back.
///
/// The property being bought is not compactness. It is that **a delimiter in
/// the stream is always a real boundary**, which is exactly what a
/// length-prefixed frame cannot promise.
pub mod cobs {
    use super::{Error, MAX_PAYLOAD};

    /// The reserved byte. Encoded data never contains it.
    pub const DELIMITER: u8 = 0x00;

    /// Encode `payload` into `out` and terminate it with [`DELIMITER`].
    ///
    /// Returns the encoded length including the delimiter.
    pub fn encode(payload: &[u8], out: &mut [u8]) -> Result<usize, Error> {
        if payload.len() > MAX_PAYLOAD {
            return Err(Error::PayloadTooLarge);
        }
        if out.len() < overhead(payload.len()) + payload.len() {
            return Err(Error::BufferTooSmall);
        }

        // `code_at` is where the distance to the next zero gets written once
        // that distance is known, which is only after the bytes have been
        // copied. That backfill is the whole algorithm.
        let mut code_at = 0usize;
        let mut n = 1usize;
        let mut code = 1u8;

        for &b in payload {
            if b == DELIMITER {
                out[code_at] = code;
                code_at = n;
                n += 1;
                code = 1;
            } else {
                out[n] = b;
                n += 1;
                code += 1;
                if code == 0xFF {
                    // A run of 254 non-zero bytes has no zero to point at, so
                    // the chain is broken deliberately and continued.
                    out[code_at] = code;
                    code_at = n;
                    n += 1;
                    code = 1;
                }
            }
        }
        out[code_at] = code;
        out[n] = DELIMITER;
        Ok(n + 1)
    }

    /// Bytes an encoded frame costs beyond its payload: the leading code byte,
    /// the trailing delimiter, and one more for every 254 bytes without a zero.
    pub const fn overhead(payload_len: usize) -> usize {
        2 + payload_len / 254
    }

    /// Byte-fed decoder for [`cobs`](self) frames.
    ///
    /// Decoding happens as bytes arrive rather than at the delimiter, so a
    /// malformed block is caught where it goes wrong rather than after it has
    /// been copied somewhere.
    pub struct Deframer {
        buf: [u8; MAX_PAYLOAD],
        have: usize,
        /// Bytes left before the next code byte. 0 means the next byte is one.
        run: u8,
        /// Whether the run that just ended stood for a zero in the payload.
        pending_zero: bool,
        /// Set when this block cannot be valid; it is dropped at the delimiter
        /// rather than emitted.
        broken: bool,
        /// A message was just emitted and its bytes are still in `buf`. The
        /// state is cleared when the next byte arrives, not at the delimiter,
        /// so the caller can read the payload it was just handed.
        holding: bool,
        /// True until the first delimiter, i.e. while the decoder may be
        /// standing in the middle of somebody else's message.
        joined_midstream: bool,
        /// Bytes consumed into the block being assembled, code bytes included.
        /// A dropped block is this many bytes thrown away, and counting only
        /// the decoded ones would under-report what a resynchronisation cost.
        block_bytes: usize,
        discarded: usize,
    }

    impl Deframer {
        pub const fn new() -> Self {
            Self {
                buf: [0; MAX_PAYLOAD],
                have: 0,
                run: 0,
                pending_zero: false,
                broken: false,
                holding: false,
                joined_midstream: true,
                block_bytes: 0,
                discarded: 0,
            }
        }

        fn restart(&mut self) {
            self.have = 0;
            self.run = 0;
            self.pending_zero = false;
            self.broken = false;
            self.holding = false;
            self.block_bytes = 0;
        }
    }

    impl Default for Deframer {
        fn default() -> Self {
            Self::new()
        }
    }

    impl super::Deframer for Deframer {
        fn feed(&mut self, byte: u8) -> Option<usize> {
            if self.holding {
                // The previous message stayed readable until now. Its bytes
                // are about to be overwritten, which is the moment to forget
                // it — not the delimiter, which is when the caller was told.
                self.restart();
            }

            self.block_bytes += 1;

            if byte == DELIMITER {
                // A boundary, always — nothing else in the stream can be this
                // byte. What is in hand may still be nonsense, and this is the
                // one place that is decided.
                //
                // `run == 0` means the block ended exactly where its last code
                // byte said it would. A block cut short by the delimiter did
                // not, and that is how a decoder that joined halfway knows the
                // tail it assembled is somebody else's.
                let emit = !self.broken && !self.joined_midstream && self.run == 0;
                let len = self.have;
                self.joined_midstream = false;
                if emit {
                    self.holding = true;
                    return Some(len);
                }
                self.discarded += self.block_bytes;
                self.restart();
                return None;
            }

            if self.run == 0 {
                // A code byte: the distance to the next zero.
                if self.pending_zero {
                    if self.have < MAX_PAYLOAD {
                        self.buf[self.have] = 0;
                        self.have += 1;
                    } else {
                        self.broken = true;
                    }
                }
                self.run = byte - 1;
                self.pending_zero = byte != 0xFF;
                return None;
            }

            if self.have < MAX_PAYLOAD {
                self.buf[self.have] = byte;
                self.have += 1;
            } else {
                self.broken = true;
            }
            self.run -= 1;
            None
        }

        fn payload(&self) -> &[u8] {
            &self.buf[..self.have]
        }

        fn discarded(&self) -> usize {
            self.discarded
        }
    }

    impl super::Start for Deframer {
        /// A decoder reading from the first byte of a stream has not joined
        /// anything, so the block before the first delimiter is a real message.
        fn fresh() -> Self {
            let mut d = Self::new();
            d.joined_midstream = false;
            d
        }
        /// The decoder that knows it might be standing in the middle of a
        /// message, and therefore throws the first block away.
        fn joined() -> Self {
            Self::new()
        }
    }

    #[cfg(test)]
    pub fn decode_all(stream: &[u8]) -> alloc::vec::Vec<alloc::vec::Vec<u8>> {
        use super::{Deframer as _, Start as _};
        let mut d = Deframer::fresh();
        let mut out = alloc::vec::Vec::new();
        for &b in stream {
            if d.feed(b).is_some() {
                out.push(d.payload().to_vec());
            }
        }
        out
    }
}

// ---------------------------------------------------------------------------

/// Which scheme the firmware links, chosen by a cargo feature.
///
/// One const and one type, so `src/main.rs` names neither scheme and the two
/// builds differ by a feature flag rather than by a branch nobody reads.
#[cfg(not(feature = "cobs"))]
pub type Selected = length_prefix::Deframer;
/// See [`Selected`].
#[cfg(feature = "cobs")]
pub type Selected = cobs::Deframer;

/// The scheme's name, for the boot log — so a capture says which build made it.
#[cfg(not(feature = "cobs"))]
pub const SCHEME: &str = "length-prefix";
/// See [`SCHEME`].
#[cfg(feature = "cobs")]
pub const SCHEME: &str = "cobs";

/// Encode with whichever scheme is selected.
pub fn encode(payload: &[u8], out: &mut [u8]) -> Result<usize, Error> {
    #[cfg(not(feature = "cobs"))]
    return length_prefix::encode(payload, out);
    #[cfg(feature = "cobs")]
    return cobs::encode(payload, out);
}

#[cfg(test)]
extern crate alloc;

#[cfg(test)]
mod resync;

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::vec::Vec;

    fn roundtrip<F, D>(encode: F, decode: fn(&[u8]) -> Vec<Vec<u8>>, payloads: &[&[u8]])
    where
        F: Fn(&[u8], &mut [u8]) -> Result<usize, Error>,
        D: Deframer,
    {
        let mut wire = Vec::new();
        let mut out = [0u8; 2 * MAX_PAYLOAD];
        for p in payloads {
            let n = encode(p, &mut out).unwrap();
            wire.extend_from_slice(&out[..n]);
        }
        let got = decode(&wire);
        let want: Vec<Vec<u8>> = payloads.iter().map(|p| p.to_vec()).collect();
        assert_eq!(got, want);
    }

    const CASES: &[&[u8]] = &[
        b"hello",
        b"",
        &[0x00],
        &[0x00, 0x00, 0x00],
        &[length_prefix::MAGIC],
        &[length_prefix::MAGIC, 0x05, 0x00, b'a', b'b', b'c', b'd', b'e'],
        &[0xFF; MAX_PAYLOAD],
    ];

    #[test]
    fn length_prefix_roundtrips_every_case() {
        for case in CASES {
            if case.is_empty() {
                continue; // a zero-length frame is rejected by design; see below
            }
            roundtrip::<_, length_prefix::Deframer>(
                length_prefix::encode,
                length_prefix::decode_all,
                &[case],
            );
        }
    }

    #[test]
    fn cobs_roundtrips_every_case() {
        for case in CASES {
            roundtrip::<_, cobs::Deframer>(cobs::encode, cobs::decode_all, &[case]);
        }
    }

    #[test]
    fn cobs_encodes_no_delimiter_anywhere() {
        // The entire property, asserted directly: whatever the payload is, the
        // encoded bytes before the terminator contain no zero.
        let mut out = [0u8; 2 * MAX_PAYLOAD];
        for case in CASES {
            let n = cobs::encode(case, &mut out).unwrap();
            assert!(
                !out[..n - 1].contains(&cobs::DELIMITER),
                "encoded {case:?} contains the delimiter"
            );
            assert_eq!(out[n - 1], cobs::DELIMITER);
        }
    }

    #[test]
    fn length_prefix_rejects_an_impossible_length() {
        // 0xFFFF cannot be honoured, so the three bytes are dropped and the
        // hunt restarts. Without this the decoder would wait for 65535 bytes.
        let mut out = [0u8; 64];
        let n = length_prefix::encode(b"ok", &mut out).unwrap();
        let mut wire = alloc::vec![length_prefix::MAGIC, 0xFF, 0xFF];
        wire.extend_from_slice(&out[..n]);
        assert_eq!(length_prefix::decode_all(&wire), alloc::vec![b"ok".to_vec()]);
    }

    #[test]
    fn overheads_are_what_they_claim() {
        let mut out = [0u8; 2 * MAX_PAYLOAD];
        for case in CASES {
            if !case.is_empty() {
                let n = length_prefix::encode(case, &mut out).unwrap();
                assert_eq!(n - case.len(), length_prefix::overhead(case.len()));
            }
            let n = cobs::encode(case, &mut out).unwrap();
            assert_eq!(n - case.len(), cobs::overhead(case.len()));
        }
    }
}
