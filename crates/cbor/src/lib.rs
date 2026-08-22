//! A canonical CBOR writer, for the subset CTAP2 asks for.
//!
//! # What this is not
//!
//! It is **not a CBOR implementation**. There is no reader, no tagging, no
//! floats, no indefinite lengths, no negative integers and no nesting depth
//! tracking. It writes the six things an `authenticatorGetInfo` response is
//! made of — unsigned integers, byte strings, text strings, arrays, maps and
//! booleans — and refuses everything else by not having it.
//!
//! [`framing`](../../framing/) says the same kind of thing about itself and for
//! the same reason: a crate that is honest about its subset is one a reader can
//! finish, and one whose tests mean something.
//!
//! # Why *canonical* is the whole point
//!
//! CTAP2 does not merely accept CBOR; it requires the **canonical** form:
//!
//! - every integer in its shortest encoding,
//! - definite lengths everywhere,
//! - and map keys **sorted**, shorter encodings first and then bytewise.
//!
//! Two encoders that disagree about any of those produce different bytes for
//! the same data, and a host that hashes or compares a response will call one
//! of them wrong. So this crate does not merely *allow* canonical output — it
//! **refuses to produce anything else**: [`Writer::key`] returns
//! [`Error::KeyOutOfOrder`] if a map key does not follow the last one, so a
//! response that would have been quietly non-canonical is a compile-run-fail
//! instead of a bug a host reports as "invalid CBOR".
//!
//! That is the only opinion in here, and it is the reason the crate exists
//! rather than the encoding being written inline.

#![cfg_attr(not(test), no_std)]

/// What went wrong. Every one of these is a thing that would have produced
/// bytes some other CBOR implementation reads differently.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    /// The buffer the caller supplied is not big enough for what was asked.
    OutOfSpace,
    /// A map key that does not sort after the one before it. Canonical CBOR
    /// says keys ascend; this is the check that makes that true rather than
    /// hoped for.
    KeyOutOfOrder,
    /// More or fewer items were written than the map or array header promised.
    /// Checked at [`Writer::finish`], because a container whose length lies is
    /// the one CBOR error a reader cannot recover from.
    WrongItemCount,
}

const MT_UINT: u8 = 0 << 5;
const MT_NINT: u8 = 1 << 5;
const MT_BYTES: u8 = 2 << 5;
const MT_TEXT: u8 = 3 << 5;
const MT_ARRAY: u8 = 4 << 5;
const MT_MAP: u8 = 5 << 5;
const SIMPLE_FALSE: u8 = 0xf4;
const SIMPLE_TRUE: u8 = 0xf5;

/// The longest map key this writer will hold for comparison. Long enough for
/// COSE's text keys; a key longer than this is refused rather than compared
/// against a truncated copy of itself.
const MAX_KEY_LEN: usize = 24;

/// One open container: how many items it promised and how many it has had.
#[derive(Clone, Copy)]
struct Open {
    remaining: u32,
    /// Maps count a key and a value as one item, and hold the last key so the
    /// next one can be checked against it.
    is_map: bool,
    /// **The last key as it was encoded, not as a number.** Canonical CBOR
    /// orders keys by their encoded bytes — shorter first, then bytewise — and
    /// COSE mixes positive integers, negative integers and text in one map. `1`
    /// encodes as `0x01`, `-1` as `0x20` and `"alg"` as `0x63 61 6c 67`, so the
    /// order is 1, 3, -1, -2, -3, "alg", "sig", and comparing the *numbers*
    /// would get that wrong in two different directions.
    last_key: Option<([u8; MAX_KEY_LEN], usize)>,
    expecting_value: bool,
}

/// Canonical order between two encoded keys: shorter first, then bytewise.
fn key_follows(prev: &[u8], next: &[u8]) -> bool {
    match next.len().cmp(&prev.len()) {
        core::cmp::Ordering::Less => false,
        core::cmp::Ordering::Greater => true,
        core::cmp::Ordering::Equal => next > prev,
    }
}

/// Writes canonical CBOR into a caller-supplied buffer.
pub struct Writer<'a> {
    buf: &'a mut [u8],
    at: usize,
    stack: [Option<Open>; MAX_DEPTH],
    depth: usize,
    error: Option<Error>,
}

/// Deep enough for a `getInfo` response, which nests a map inside a map inside
/// nothing. A fixed depth rather than a growable one, because this crate has no
/// allocator and a CTAP2 response that needs more than this is a response that
/// should be looked at rather than accommodated.
pub const MAX_DEPTH: usize = 4;

impl<'a> Writer<'a> {
    pub fn new(buf: &'a mut [u8]) -> Self {
        Self { buf, at: 0, stack: [None; MAX_DEPTH], depth: 0, error: None }
    }

    /// The first error, if there was one. Errors are **latched** rather than
    /// returned from every call: a caller building a fixed response should be
    /// able to write it as a sequence of statements and ask once at the end,
    /// and an encoder that has already gone wrong must not produce half a
    /// message that looks complete.
    pub fn error(&self) -> Option<Error> {
        self.error
    }

    fn fail(&mut self, e: Error) {
        if self.error.is_none() {
            self.error = Some(e);
        }
    }

    fn raw(&mut self, b: u8) {
        if self.error.is_some() {
            return;
        }
        if self.at >= self.buf.len() {
            self.fail(Error::OutOfSpace);
            return;
        }
        self.buf[self.at] = b;
        self.at += 1;
    }

    /// A major type and an argument, in the **shortest** encoding that holds
    /// it. This one function is most of what "canonical" means: writing 1 as
    /// `0x19 0x00 0x01` is legal CBOR and is not canonical CBOR.
    fn head(&mut self, mt: u8, arg: u64) {
        match arg {
            0..=23 => self.raw(mt | arg as u8),
            24..=0xff => {
                self.raw(mt | 24);
                self.raw(arg as u8);
            }
            0x100..=0xffff => {
                self.raw(mt | 25);
                for s in [8, 0] {
                    self.raw((arg >> s) as u8);
                }
            }
            0x1_0000..=0xffff_ffff => {
                self.raw(mt | 26);
                for s in [24, 16, 8, 0] {
                    self.raw((arg >> s) as u8);
                }
            }
            _ => {
                self.raw(mt | 27);
                for s in [56, 48, 40, 32, 24, 16, 8, 0] {
                    self.raw((arg >> s) as u8);
                }
            }
        }
    }

    /// Count one item against the innermost open container.
    fn item(&mut self) {
        if self.error.is_some() || self.depth == 0 {
            return;
        }
        let top = self.depth - 1;
        if let Some(o) = self.stack[top].as_mut() {
            if o.is_map && o.expecting_value {
                // The value half of a pair. The pair was already counted when
                // its key was written.
                o.expecting_value = false;
                return;
            }
            if o.remaining == 0 {
                self.fail(Error::WrongItemCount);
                return;
            }
            o.remaining -= 1;
            if o.is_map {
                o.expecting_value = true;
            }
        }
    }

    fn push(&mut self, is_map: bool, n: u32) {
        if self.depth >= MAX_DEPTH {
            self.fail(Error::OutOfSpace);
            return;
        }
        self.stack[self.depth] =
            Some(Open { remaining: n, is_map, last_key: None, expecting_value: false });
        self.depth += 1;
    }

    /// Open a map of exactly `n` pairs. Keys must be written with [`key`](Self::key).
    pub fn map(&mut self, n: u32) -> &mut Self {
        self.item();
        self.head(MT_MAP, n as u64);
        self.push(true, n);
        self
    }

    /// Open an array of exactly `n` items.
    pub fn array(&mut self, n: u32) -> &mut Self {
        self.item();
        self.head(MT_ARRAY, n as u64);
        self.push(false, n);
        self
    }

    /// Close the innermost container, and check it got what it promised.
    pub fn end(&mut self) -> &mut Self {
        if self.depth == 0 {
            self.fail(Error::WrongItemCount);
            return self;
        }
        self.depth -= 1;
        if let Some(o) = self.stack[self.depth].take() {
            if o.remaining != 0 || o.expecting_value {
                self.fail(Error::WrongItemCount);
            }
        }
        self
    }

    /// Encode a key into a scratch buffer so it can be compared before it is
    /// written. The one place the three kinds of key meet.
    fn encode_key(mt: u8, arg: u64, text: Option<&str>, out: &mut [u8; MAX_KEY_LEN]) -> usize {
        let mut n = 0usize;
        let mut put = |b: u8, n: &mut usize| {
            if *n < MAX_KEY_LEN {
                out[*n] = b;
            }
            *n += 1;
        };
        match arg {
            0..=23 => put(mt | arg as u8, &mut n),
            24..=0xff => {
                put(mt | 24, &mut n);
                put(arg as u8, &mut n);
            }
            0x100..=0xffff => {
                put(mt | 25, &mut n);
                put((arg >> 8) as u8, &mut n);
                put(arg as u8, &mut n);
            }
            _ => {
                put(mt | 26, &mut n);
                for s in [24, 16, 8, 0] {
                    put((arg >> s) as u8, &mut n);
                }
            }
        }
        if let Some(t) = text {
            for b in t.as_bytes() {
                put(*b, &mut n);
            }
        }
        n
    }

    fn key_common(&mut self, mt: u8, arg: u64, text: Option<&str>) -> &mut Self {
        if self.depth == 0 {
            self.fail(Error::WrongItemCount);
            return self;
        }
        let mut enc = [0u8; MAX_KEY_LEN];
        let len = Self::encode_key(mt, arg, text, &mut enc);
        if len > MAX_KEY_LEN {
            self.fail(Error::OutOfSpace);
            return self;
        }
        let top = self.depth - 1;
        match self.stack[top].as_ref() {
            Some(o) if o.is_map => {
                if let Some((prev, plen)) = o.last_key {
                    if !key_follows(&prev[..plen], &enc[..len]) {
                        self.fail(Error::KeyOutOfOrder);
                        return self;
                    }
                }
            }
            _ => {
                self.fail(Error::WrongItemCount);
                return self;
            }
        }
        self.item();
        if let Some(o) = self.stack[top].as_mut() {
            o.last_key = Some((enc, len));
        }
        for b in &enc[..len] {
            self.raw(*b);
        }
        self
    }

    /// An unsigned-integer map key, checked against the one before it.
    pub fn key(&mut self, k: u64) -> &mut Self {
        self.key_common(MT_UINT, k, None)
    }

    /// A negative-integer map key. COSE labels its curve and coordinates with
    /// these, and they sort **after** every positive one because `0x20` is
    /// bigger than `0x01`.
    pub fn key_nint(&mut self, k: i64) -> &mut Self {
        if k >= 0 {
            self.fail(Error::KeyOutOfOrder);
            return self;
        }
        self.key_common(MT_NINT, (-1 - k) as u64, None)
    }

    /// A text map key. CTAP2's attestation statement uses these, and they sort
    /// after every integer one.
    pub fn key_text(&mut self, k: &str) -> &mut Self {
        self.key_common(MT_TEXT, k.len() as u64, Some(k))
    }

    pub fn uint(&mut self, v: u64) -> &mut Self {
        self.item();
        self.head(MT_UINT, v);
        self
    }

    /// A negative integer. CBOR stores `-1 - n`.
    pub fn nint(&mut self, v: i64) -> &mut Self {
        if v >= 0 {
            self.fail(Error::KeyOutOfOrder);
            return self;
        }
        self.item();
        self.head(MT_NINT, (-1 - v) as u64);
        self
    }

    pub fn bool(&mut self, v: bool) -> &mut Self {
        self.item();
        self.raw(if v { SIMPLE_TRUE } else { SIMPLE_FALSE });
        self
    }

    pub fn text(&mut self, s: &str) -> &mut Self {
        self.item();
        self.head(MT_TEXT, s.len() as u64);
        for b in s.as_bytes() {
            self.raw(*b);
        }
        self
    }

    pub fn bytes(&mut self, b: &[u8]) -> &mut Self {
        self.item();
        self.head(MT_BYTES, b.len() as u64);
        for x in b {
            self.raw(*x);
        }
        self
    }

    /// The bytes written, or the first error. **A container left open is an
    /// error**, not a truncation: a map header that promised three pairs and a
    /// buffer holding two is the one shape a reader cannot tell from a
    /// transport failure.
    pub fn finish(self) -> Result<&'a [u8], Error> {
        if let Some(e) = self.error {
            return Err(e);
        }
        if self.depth != 0 {
            return Err(Error::WrongItemCount);
        }
        Ok(&self.buf[..self.at])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn enc(f: impl FnOnce(&mut Writer)) -> Result<alloc::vec::Vec<u8>, Error> {
        let mut buf = [0u8; 512];
        let mut w = Writer::new(&mut buf);
        f(&mut w);
        w.finish().map(|b| b.to_vec())
    }
    extern crate alloc;

    #[test]
    fn integers_use_the_shortest_encoding() {
        // The whole of "canonical", in the one place it is easiest to get wrong.
        assert_eq!(enc(|w| { w.uint(0); }).unwrap(), [0x00]);
        assert_eq!(enc(|w| { w.uint(23); }).unwrap(), [0x17]);
        assert_eq!(enc(|w| { w.uint(24); }).unwrap(), [0x18, 0x18]);
        assert_eq!(enc(|w| { w.uint(255); }).unwrap(), [0x18, 0xff]);
        assert_eq!(enc(|w| { w.uint(256); }).unwrap(), [0x19, 0x01, 0x00]);
        assert_eq!(enc(|w| { w.uint(65535); }).unwrap(), [0x19, 0xff, 0xff]);
        assert_eq!(enc(|w| { w.uint(65536); }).unwrap(), [0x1a, 0x00, 0x01, 0x00, 0x00]);
    }

    #[test]
    fn rfc_8949_examples() {
        // Straight from the specification's own table, so this crate is checked
        // against something other than its author's understanding of it.
        assert_eq!(enc(|w| { w.text("a"); }).unwrap(), [0x61, 0x61]);
        assert_eq!(enc(|w| { w.text("IETF"); }).unwrap(), [0x64, 0x49, 0x45, 0x54, 0x46]);
        assert_eq!(enc(|w| { w.bytes(&[1, 2, 3, 4]); }).unwrap(), [0x44, 1, 2, 3, 4]);
        assert_eq!(enc(|w| { w.array(0); w.end(); }).unwrap(), [0x80]);
        assert_eq!(enc(|w| { w.map(0); w.end(); }).unwrap(), [0xa0]);
        assert_eq!(
            enc(|w| { w.array(3); w.uint(1); w.uint(2); w.uint(3); w.end(); }).unwrap(),
            [0x83, 0x01, 0x02, 0x03]
        );
        assert_eq!(enc(|w| { w.bool(false); }).unwrap(), [0xf4]);
        assert_eq!(enc(|w| { w.bool(true); }).unwrap(), [0xf5]);
    }

    #[test]
    fn a_key_out_of_order_is_refused_rather_than_written() {
        let e = enc(|w| {
            w.map(2);
            w.key(3);
            w.uint(1);
            w.key(1); // 1 does not follow 3
            w.uint(2);
            w.end();
        });
        assert_eq!(e, Err(Error::KeyOutOfOrder));
    }

    #[test]
    fn a_repeated_key_is_refused_too() {
        // Duplicate keys are invalid CBOR quite apart from canonical ordering,
        // and "strictly increasing" catches both with one comparison.
        let e = enc(|w| {
            w.map(2);
            w.key(1);
            w.uint(1);
            w.key(1);
            w.uint(2);
            w.end();
        });
        assert_eq!(e, Err(Error::KeyOutOfOrder));
    }

    #[test]
    fn a_container_that_lies_about_its_length_is_an_error() {
        assert_eq!(
            enc(|w| { w.array(3); w.uint(1); w.end(); }),
            Err(Error::WrongItemCount)
        );
        assert_eq!(
            enc(|w| { w.array(1); w.uint(1); w.uint(2); w.end(); }),
            Err(Error::WrongItemCount)
        );
    }

    #[test]
    fn a_container_left_open_is_an_error_not_a_truncation() {
        assert_eq!(enc(|w| { w.map(1); w.key(1); w.uint(0); }), Err(Error::WrongItemCount));
    }

    #[test]
    fn a_map_missing_a_value_is_caught() {
        assert_eq!(enc(|w| { w.map(1); w.key(1); w.end(); }), Err(Error::WrongItemCount));
    }

    #[test]
    fn running_out_of_buffer_is_an_error_and_not_a_short_message() {
        let mut buf = [0u8; 2];
        let mut w = Writer::new(&mut buf);
        w.text("far too long for two bytes");
        assert_eq!(w.finish(), Err(Error::OutOfSpace));
    }

    #[test]
    fn cose_key_order_is_by_encoded_bytes_not_by_number() {
        // A COSE_Key for ES256: kty, alg, crv, x, y. The labels are 1, 3, -1,
        // -2, -3, and comparing them as numbers would put -3 first. Canonical
        // CBOR compares the encodings — 0x01, 0x03, 0x20, 0x21, 0x22 — so the
        // order is the one below, and it is the order a relying party's own
        // library will expect.
        let out = enc(|w| {
            w.map(5);
            w.key(1);
            w.uint(2);
            w.key(3);
            w.nint(-7);
            w.key_nint(-1);
            w.uint(1);
            w.key_nint(-2);
            w.bytes(&[0xaa; 2]);
            w.key_nint(-3);
            w.bytes(&[0xbb; 2]);
            w.end();
        })
        .unwrap();
        assert_eq!(
            out,
            [0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x42, 0xaa, 0xaa, 0x22, 0x42, 0xbb, 0xbb]
        );
    }

    #[test]
    fn a_negative_key_before_a_positive_one_is_refused() {
        let e = enc(|w| {
            w.map(2);
            w.key_nint(-1);
            w.uint(0);
            w.key(1); // 0x01 does not follow 0x20
            w.uint(0);
            w.end();
        });
        assert_eq!(e, Err(Error::KeyOutOfOrder));
    }

    #[test]
    fn text_keys_sort_after_integers_and_by_length_then_bytes() {
        let out = enc(|w| {
            w.map(2);
            w.key_text("alg");
            w.nint(-7);
            w.key_text("sig");
            w.bytes(&[1]);
            w.end();
        })
        .unwrap();
        assert_eq!(out, [0xa2, 0x63, b'a', b'l', b'g', 0x26, 0x63, b's', b'i', b'g', 0x41, 0x01]);

        // "sig" before "alg" is the same length and the wrong way round.
        assert_eq!(
            enc(|w| {
                w.map(2);
                w.key_text("sig");
                w.uint(0);
                w.key_text("alg");
                w.uint(0);
                w.end();
            }),
            Err(Error::KeyOutOfOrder)
        );
        // A shorter key after a longer one, which sorts before it.
        assert_eq!(
            enc(|w| {
                w.map(2);
                w.key_text("alpha");
                w.uint(0);
                w.key_text("sig");
                w.uint(0);
                w.end();
            }),
            Err(Error::KeyOutOfOrder)
        );
    }

    #[test]
    fn negative_integers_round_trip_through_the_reader() {
        for v in [-1i64, -7, -100, -257, -65536] {
            let out = enc(|w| {
                w.nint(v);
            })
            .unwrap();
            assert_eq!(Reader::new(&out).next(), Ok(Item::Nint(v)), "{v}");
        }
    }

    #[test]
    fn nesting_counts_the_container_as_one_item_of_its_parent() {
        let out = enc(|w| {
            w.map(1);
            w.key(1);
            w.array(2);
            w.text("a");
            w.text("b");
            w.end();
            w.end();
        })
        .unwrap();
        assert_eq!(out, [0xa1, 0x01, 0x82, 0x61, 0x61, 0x61, 0x62]);
    }
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// One CBOR item, borrowed from the buffer it was read out of.
///
/// There is no owned variant and no allocation: a reader on a device with 520
/// KB of SRAM that copies every string it is handed is a reader an attacker
/// sizes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Item<'a> {
    Uint(u64),
    /// A negative integer. CBOR stores `-1 - n`, so the range is
    /// `-1 ..= -2^64`; this narrows to `i64` and refuses what will not fit,
    /// because COSE's labels are small and a value that needs more is a value
    /// this subset should not silently truncate.
    Nint(i64),
    Bytes(&'a [u8]),
    Text(&'a str),
    /// The header of an array. Its items follow and are read individually.
    Array(u64),
    /// The header of a map. Its pairs follow, key then value.
    Map(u64),
    Bool(bool),
}

/// What went wrong reading. Every one of these is a byte sequence some other
/// CBOR reader would accept, which is exactly why they are named separately.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadError {
    /// The buffer ended in the middle of an item — including when a length
    /// field promised more bytes than the message contains. **This is the one
    /// that matters**: a reader that trusts a length reads past its buffer, and
    /// the length came from whoever sent the message.
    Truncated,
    /// Valid CBOR that CTAP2 does not accept: an over-long integer encoding, an
    /// indefinite length, or map keys out of order.
    NotCanonical,
    /// A major type or simple value this subset does not implement. Refused
    /// rather than skipped, because skipping something unrecognised is how a
    /// parser disagrees with the thing that wrote it.
    Unsupported,
    /// Nesting past [`MAX_DEPTH`]. A limit rather than a stack overflow.
    TooDeep,
    /// A text string that is not UTF-8.
    BadText,
}

/// A cursor over CBOR that **refuses everything non-canonical** and never reads
/// past the buffer it was given.
pub struct Reader<'a> {
    buf: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Self { buf, at: 0 }
    }

    /// How many bytes have been consumed. A caller that has read everything it
    /// wanted checks this against the message length: trailing bytes after a
    /// complete structure are a message two implementations disagree about.
    pub fn position(&self) -> usize {
        self.at
    }

    pub fn is_empty(&self) -> bool {
        self.at >= self.buf.len()
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], ReadError> {
        // The whole of the bounds check, in one place, and every path goes
        // through it. `checked_add` because `at + n` on a length from the wire
        // is where an overflow turns a refusal into a read.
        let end = self.at.checked_add(n).ok_or(ReadError::Truncated)?;
        if end > self.buf.len() {
            return Err(ReadError::Truncated);
        }
        let out = &self.buf[self.at..end];
        self.at = end;
        Ok(out)
    }

    fn head(&mut self) -> Result<(u8, u64), ReadError> {
        let ib = self.take(1)?[0];
        let (mt, ai) = (ib >> 5, ib & 0x1f);
        let arg = match ai {
            0..=23 => ai as u64,
            24 => {
                let v = self.take(1)?[0] as u64;
                if v < 24 {
                    return Err(ReadError::NotCanonical);
                }
                v
            }
            25 => {
                let b = self.take(2)?;
                let v = u16::from_be_bytes([b[0], b[1]]) as u64;
                if v <= 0xff {
                    return Err(ReadError::NotCanonical);
                }
                v
            }
            26 => {
                let b = self.take(4)?;
                let v = u32::from_be_bytes([b[0], b[1], b[2], b[3]]) as u64;
                if v <= 0xffff {
                    return Err(ReadError::NotCanonical);
                }
                v
            }
            27 => {
                let b = self.take(8)?;
                let v = u64::from_be_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]);
                if v <= 0xffff_ffff {
                    return Err(ReadError::NotCanonical);
                }
                v
            }
            31 => return Err(ReadError::NotCanonical), // indefinite length
            _ => return Err(ReadError::Unsupported),
        };
        Ok((mt, arg))
    }

    /// Read the next item.
    pub fn next(&mut self) -> Result<Item<'a>, ReadError> {
        let (mt, arg) = self.head()?;
        Ok(match mt {
            0 => Item::Uint(arg),
            1 => {
                // CBOR stores -1 - n. Anything that will not fit an i64 is
                // refused rather than wrapped.
                let n = i64::try_from(arg).map_err(|_| ReadError::Unsupported)?;
                Item::Nint(-1 - n)
            }
            2 => Item::Bytes(self.take(arg as usize)?),
            3 => {
                let b = self.take(arg as usize)?;
                Item::Text(core::str::from_utf8(b).map_err(|_| ReadError::BadText)?)
            }
            4 => Item::Array(arg),
            5 => Item::Map(arg),
            7 => match arg {
                20 => Item::Bool(false),
                21 => Item::Bool(true),
                _ => return Err(ReadError::Unsupported),
            },
            _ => return Err(ReadError::Unsupported),
        })
    }

    /// Step over the next item, whatever it is, including a whole container.
    ///
    /// Depth-limited rather than recursive without a bound: a map nested a
    /// thousand deep is a message somebody built, and a stack overflow is not
    /// a refusal.
    pub fn skip(&mut self) -> Result<(), ReadError> {
        self.skip_at(0)
    }

    fn skip_at(&mut self, depth: usize) -> Result<(), ReadError> {
        if depth > MAX_DEPTH {
            return Err(ReadError::TooDeep);
        }
        match self.next()? {
            Item::Array(n) => {
                for _ in 0..n {
                    self.skip_at(depth + 1)?;
                }
            }
            Item::Map(n) => {
                // Keys are checked for order here too, because a map somebody
                // skipped past is still a map that has to be canonical for the
                // message to be.
                let mut last: Option<u64> = None;
                for _ in 0..n {
                    match self.next()? {
                        Item::Uint(k) => {
                            if let Some(prev) = last {
                                if k <= prev {
                                    return Err(ReadError::NotCanonical);
                                }
                            }
                            last = Some(k);
                        }
                        // Text keys sort after integer ones and among
                        // themselves by length then bytes. This subset does not
                        // need them, and guessing at the rule would be worse
                        // than refusing.
                        Item::Text(_) => {}
                        _ => return Err(ReadError::NotCanonical),
                    }
                    self.skip_at(depth + 1)?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    /// Read a map header and check it is one. The shape almost every CTAP2
    /// request starts with.
    pub fn map_header(&mut self) -> Result<u64, ReadError> {
        match self.next()? {
            Item::Map(n) => Ok(n),
            _ => Err(ReadError::Unsupported),
        }
    }
}

#[cfg(test)]
mod read_tests {
    use super::*;

    fn r(hex: &str) -> alloc::vec::Vec<u8> {
        (0..hex.len()).step_by(2).map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap()).collect()
    }
    extern crate alloc;

    #[test]
    fn reads_what_the_writer_wrote() {
        let mut buf = [0u8; 128];
        let mut w = Writer::new(&mut buf);
        w.map(2);
        w.key(1);
        w.text("hello");
        w.key(2);
        w.bytes(&[9, 8, 7]);
        w.end();
        let out = w.finish().unwrap();

        let mut rd = Reader::new(out);
        assert_eq!(rd.next(), Ok(Item::Map(2)));
        assert_eq!(rd.next(), Ok(Item::Uint(1)));
        assert_eq!(rd.next(), Ok(Item::Text("hello")));
        assert_eq!(rd.next(), Ok(Item::Uint(2)));
        assert_eq!(rd.next(), Ok(Item::Bytes(&[9, 8, 7])));
        assert!(rd.is_empty());
    }

    #[test]
    fn negative_integers_decode_the_way_cose_needs() {
        // ES256 is alg -7, which is major type 1 with argument 6.
        for (hex, want) in [("26", -7i64), ("20", -1), ("3863", -100)] {
            let bytes = r(hex);
            assert_eq!(Reader::new(&bytes).next(), Ok(Item::Nint(want)), "{hex}");
        }
    }

    #[test]
    fn a_length_longer_than_the_buffer_is_refused_and_not_read() {
        // **The one that matters.** A byte string that says it is 200 bytes in
        // a four-byte message. A reader that trusts the length reads 196 bytes
        // of whatever is next in memory.
        for hex in ["58c8010203", "5b7fffffffffffffff", "79ffff41"] {
            let bytes = r(hex);
            assert_eq!(Reader::new(&bytes).next(), Err(ReadError::Truncated), "{hex}");
        }
    }

    #[test]
    fn a_header_cut_in_half_is_refused() {
        for hex in ["58", "19ff", ""] {
            let bytes = r(hex);
            assert_eq!(Reader::new(&bytes).next(), Err(ReadError::Truncated), "{hex}");
        }
    }

    #[test]
    fn non_canonical_integers_are_refused_rather_than_normalised() {
        // 23 in two bytes, 255 in three, 65535 in five: all legal CBOR, none
        // of it canonical.
        for hex in ["1817", "1900ff", "1a0000ffff"] {
            let bytes = r(hex);
            assert_eq!(Reader::new(&bytes).next(), Err(ReadError::NotCanonical), "{hex}");
        }
    }

    #[test]
    fn indefinite_lengths_are_refused() {
        for hex in ["9f", "bf", "5f"] {
            let bytes = r(hex);
            assert_eq!(Reader::new(&bytes).next(), Err(ReadError::NotCanonical), "{hex}");
        }
    }

    #[test]
    fn skip_steps_over_a_whole_container() {
        // {1: [1,2,3], 2: 9} — skipping the array must land on key 2.
        let bytes = r("a201830102030209");
        let mut rd = Reader::new(&bytes);
        assert_eq!(rd.next(), Ok(Item::Map(2)));
        assert_eq!(rd.next(), Ok(Item::Uint(1)));
        rd.skip().unwrap();
        assert_eq!(rd.next(), Ok(Item::Uint(2)));
        assert_eq!(rd.next(), Ok(Item::Uint(9)));
    }

    #[test]
    fn skipping_a_map_still_checks_its_keys() {
        // {1: {3:0, 1:0}} — the inner keys descend, and skipping must not
        // launder that.
        let bytes = r("a101a2030001000000");
        let mut rd = Reader::new(&bytes);
        assert_eq!(rd.next(), Ok(Item::Map(1)));
        assert_eq!(rd.next(), Ok(Item::Uint(1)));
        assert_eq!(rd.skip(), Err(ReadError::NotCanonical));
    }

    #[test]
    fn a_container_that_promised_more_than_it_holds_is_truncated_not_short() {
        // An array of three with two items. `skip` must say so rather than
        // stopping early and letting a caller read the next message's bytes as
        // the third item.
        let bytes = r("830102");
        assert_eq!(Reader::new(&bytes).skip(), Err(ReadError::Truncated));
    }

    #[test]
    fn nesting_has_a_limit_and_it_is_a_refusal() {
        // Six nested arrays, one deeper than MAX_DEPTH allows.
        let deep = r("8181818181810100");
        assert_eq!(Reader::new(&deep).skip(), Err(ReadError::TooDeep));
    }

    #[test]
    fn text_that_is_not_utf8_is_refused() {
        let bytes = r("62fffe");
        assert_eq!(Reader::new(&bytes).next(), Err(ReadError::BadText));
    }
}
