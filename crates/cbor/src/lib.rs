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
const MT_BYTES: u8 = 2 << 5;
const MT_TEXT: u8 = 3 << 5;
const MT_ARRAY: u8 = 4 << 5;
const MT_MAP: u8 = 5 << 5;
const SIMPLE_FALSE: u8 = 0xf4;
const SIMPLE_TRUE: u8 = 0xf5;

/// One open container: how many items it promised and how many it has had.
#[derive(Clone, Copy)]
struct Open {
    remaining: u32,
    /// Maps count a key and a value as one item, and hold the last key so the
    /// next one can be checked against it.
    is_map: bool,
    last_key: Option<u64>,
    expecting_value: bool,
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

    /// An unsigned-integer map key, checked against the one before it.
    ///
    /// CTAP2's map keys are small unsigned integers, so "sorted" is numeric
    /// order and this check is exact. A crate that accepted a key out of order
    /// would produce bytes that are valid CBOR, are not canonical CBOR, and
    /// fail somewhere a long way from here.
    pub fn key(&mut self, k: u64) -> &mut Self {
        if self.depth == 0 {
            self.fail(Error::WrongItemCount);
            return self;
        }
        let top = self.depth - 1;
        match self.stack[top].as_ref() {
            Some(o) if o.is_map => {
                if let Some(last) = o.last_key {
                    if k <= last {
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
            o.last_key = Some(k);
        }
        self.head(MT_UINT, k);
        self
    }

    pub fn uint(&mut self, v: u64) -> &mut Self {
        self.item();
        self.head(MT_UINT, v);
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
