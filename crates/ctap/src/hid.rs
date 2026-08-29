// SPDX-License-Identifier: Apache-2.0
//! CTAPHID: the transport, and the state machine that reassembles it.
//!
//! A CTAPHID report is 64 bytes. An **initialisation** packet carries
//! `CID(4) + CMD(1) + BCNT(2)` and 57 bytes of payload; everything after it
//! arrives in **continuation** packets of `CID(4) + SEQ(1) + 59`. So a message
//! longer than 57 bytes is a reassembly problem, at a layer where the
//! specification says what the right answer is — which means the failures can
//! be graded, and [exp168] graded twelve of them.
//!
//! [`Channel::feed`] is that grading, as a pure function of bytes. It reads a
//! packet, writes into a buffer the caller owns, and returns what the firmware
//! should do next. It touches no USB, allocates nothing, and every case
//! [exp168] drove by hand against a board is a test below that needs none.
//!
//! [exp168]: ../../../experiments/exp168-a-security-key-that-knows-nothing/

/// **The FIDO HID report descriptor, by hand.** Thirty-four bytes, fixed by the
/// CTAP specification, and the reason a host's FIDO tooling looks at a device
/// at all: `libfido2` finds authenticators by usage page `0xF1D0`, not by
/// vendor or product ID.
///
/// Two reports, both 64 bytes of raw data with no report ID: one IN and one
/// OUT. A security key's whole transport is those two.
#[rustfmt::skip]
pub const REPORT_DESCRIPTOR: &[u8] = &[
    0x06, 0xd0, 0xf1, // USAGE_PAGE (FIDO Alliance)
    0x09, 0x01,       // USAGE (U2F HID Authenticator Device)
    0xa1, 0x01,       // COLLECTION (Application)
    0x09, 0x20,       //   USAGE (Data In)
    0x15, 0x00,       //   LOGICAL_MINIMUM (0)
    0x26, 0xff, 0x00, //   LOGICAL_MAXIMUM (255)
    0x75, 0x08,       //   REPORT_SIZE (8)
    0x95, 0x40,       //   REPORT_COUNT (64)
    0x81, 0x02,       //   INPUT (Data,Var,Abs)
    0x09, 0x21,       //   USAGE (Data Out)
    0x15, 0x00,       //   LOGICAL_MINIMUM (0)
    0x26, 0xff, 0x00, //   LOGICAL_MAXIMUM (255)
    0x75, 0x08,       //   REPORT_SIZE (8)
    0x95, 0x40,       //   REPORT_COUNT (64)
    0x91, 0x02,       //   OUTPUT (Data,Var,Abs)
    0xc0,             // END_COLLECTION
];

/// What `CTAPHID_INIT` tells every host this device can do.
///
/// `CAPABILITY_CBOR | CAPABILITY_NMSG`. **`0x08` alone is a different sentence**
/// — it is exp168's deliberate *this device has no CBOR*, and a full
/// authenticator that sends it is telling every `libfido2` client not to ask.
/// exp183 did exactly that under a comment saying `CBOR`, and it hid a crash
/// for the life of the experiment.
///
/// `CAPABILITY_NMSG` stays set because CTAP1/U2F really is not implemented.
pub const CAPABILITIES: u8 = 0x04 | 0x08;

pub const PACKET: usize = 64;
pub const INIT_HEADER: usize = 7;
pub const CONT_HEADER: usize = 5;
/// 57.
pub const INIT_PAYLOAD: usize = PACKET - INIT_HEADER;
/// 59.
pub const CONT_PAYLOAD: usize = PACKET - CONT_HEADER;
/// The largest message this transport will reassemble, and the number a device
/// must report as `maxMsgSize` — a device whose declared limit differs from its
/// enforced one has arbitrary refusals.
pub const MAX_MESSAGE: usize = 1024;

pub const CMD_PING: u8 = 0x01;
pub const CMD_MSG: u8 = 0x03;
pub const CMD_INIT: u8 = 0x06;
pub const CMD_CBOR: u8 = 0x10;
pub const CMD_CANCEL: u8 = 0x11;
pub const CMD_KEEPALIVE: u8 = 0x3b;
pub const CMD_ERROR: u8 = 0x3f;

pub const ERR_INVALID_CMD: u8 = 0x01;
pub const ERR_INVALID_PAR: u8 = 0x02;
pub const ERR_INVALID_LEN: u8 = 0x03;
pub const ERR_INVALID_SEQ: u8 = 0x04;
pub const ERR_MSG_TIMEOUT: u8 = 0x05;
pub const ERR_CHANNEL_BUSY: u8 = 0x06;
pub const ERR_LOCK_REQUIRED: u8 = 0x0a;
pub const ERR_INVALID_CHANNEL: u8 = 0x0b;
pub const ERR_OTHER: u8 = 0x7f;

pub const BROADCAST: u32 = 0xffff_ffff;
pub const RESERVED: u32 = 0x0000_0000;

/// `KEEPALIVE`'s status byte for *waiting for a person*.
pub const STATUS_UPNEEDED: u8 = 0x02;

/// What the firmware should do about the packet it just handed over.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    /// Nothing yet — a continuation was taken and more is expected.
    Idle,
    /// The packet was declined **without an answer**, and this is why.
    ///
    /// Silence is a deliberate reply here: [exp168] drove the case where a
    /// continuation arrives for a transaction nobody started, precisely because
    /// answering it would let anybody make the device talk. The reason is
    /// carried so a firmware can still say what it saw — the authenticator
    /// road's own rule is that the log is not optional, and collapsing this
    /// into `Idle` would have quietly deleted a line exp188 was printing.
    Ignored(&'static str),
    /// A `CTAPHID_INIT`. Allocate a channel and answer with the nonce.
    Init { cid: u32, nonce: [u8; 8] },
    /// A whole message. Its payload is in the caller's buffer, `len` bytes.
    Message { cid: u32, cmd: u8, len: usize },
    /// Answer `CTAPHID_ERROR` with this code on this channel.
    Error { cid: u32, code: u8 },
    /// The host asked to stop. Only meaningful while something is waiting.
    Cancel { cid: u32 },
}

/// One channel's worth of reassembly state.
///
/// A single channel, because that is what these firmwares build: a second
/// channel interrupting a transaction gets `ERR_CHANNEL_BUSY`, which is one of
/// the twelve cases exp168 drove.
#[derive(Debug, Clone, Copy)]
pub struct Channel {
    cid: u32,
    cmd: u8,
    want: usize,
    have: usize,
    next_seq: u8,
    busy: bool,
}

impl Default for Channel {
    fn default() -> Self {
        Self::new()
    }
}

impl Channel {
    pub const fn new() -> Self {
        Self { cid: 0, cmd: 0, want: 0, have: 0, next_seq: 0, busy: false }
    }

    /// Is a transaction in progress?
    pub fn busy(&self) -> bool {
        self.busy
    }

    /// The channel a transaction in progress belongs to.
    pub fn cid(&self) -> u32 {
        self.cid
    }

    /// How far a transaction in progress has got, for a log line worth reading.
    pub fn progress(&self) -> (usize, usize) {
        (self.have, self.want)
    }

    /// Abandon a transaction — a deadline expired, or the host cancelled.
    pub fn clear(&mut self) {
        self.busy = false;
        self.have = 0;
        self.want = 0;
        self.next_seq = 0;
    }

    /// Take one 64-byte packet.
    ///
    /// `buf` is the caller's message buffer and must be at least
    /// [`MAX_MESSAGE`] bytes. Nothing is allocated and nothing is retained: on
    /// [`Event::Message`] the payload is `buf[..len]`.
    pub fn feed(&mut self, pkt: &[u8], buf: &mut [u8]) -> Event {
        if pkt.len() < CONT_HEADER {
            return Event::Ignored("packet shorter than a header");
        }
        let cid = u32::from_be_bytes([pkt[0], pkt[1], pkt[2], pkt[3]]);
        let is_init = pkt[4] & 0x80 != 0;

        if is_init {
            let cmd = pkt[4] & 0x7f;
            if pkt.len() < INIT_HEADER {
                return Event::Error { cid, code: ERR_INVALID_LEN };
            }
            let bcnt = ((pkt[5] as usize) << 8) | pkt[6] as usize;

            // The broadcast channel carries INIT and nothing else.
            if cid == BROADCAST && cmd != CMD_INIT {
                return Event::Error { cid, code: ERR_INVALID_CHANNEL };
            }
            if cid == RESERVED {
                return Event::Error { cid, code: ERR_INVALID_CHANNEL };
            }

            if cmd == CMD_INIT {
                if bcnt != 8 {
                    return Event::Error { cid, code: ERR_INVALID_LEN };
                }
                let mut nonce = [0u8; 8];
                nonce.copy_from_slice(&pkt[INIT_HEADER..INIT_HEADER + 8]);
                // INIT on an allocated channel is not a new transaction: it
                // resets one. On the broadcast channel it asks for a channel.
                self.clear();
                return Event::Init { cid, nonce };
            }

            if cmd == CMD_CANCEL {
                if self.busy && self.cid == cid {
                    self.clear();
                }
                return Event::Cancel { cid };
            }

            // A second channel interrupting a transaction is refused, and the
            // one in progress is left alone.
            if self.busy && self.cid != cid {
                return Event::Error { cid, code: ERR_CHANNEL_BUSY };
            }
            if bcnt > MAX_MESSAGE || bcnt > buf.len() {
                return Event::Error { cid, code: ERR_INVALID_LEN };
            }

            let first = bcnt.min(INIT_PAYLOAD).min(pkt.len() - INIT_HEADER);
            buf[..first].copy_from_slice(&pkt[INIT_HEADER..INIT_HEADER + first]);
            self.cid = cid;
            self.cmd = cmd;
            self.want = bcnt;
            self.have = first;
            self.next_seq = 0;
            if self.have >= self.want {
                self.busy = false;
                return Event::Message { cid, cmd, len: self.want };
            }
            self.busy = true;
            Event::Idle
        } else {
            let seq = pkt[4] & 0x7f;
            // A continuation for a transaction nobody started is not an error
            // to answer; answering would let anybody make this device talk.
            if !self.busy {
                return Event::Ignored("continuation with no transaction");
            }
            if self.cid != cid {
                return Event::Ignored("continuation on another channel");
            }
            if seq != self.next_seq {
                self.clear();
                return Event::Error { cid, code: ERR_INVALID_SEQ };
            }
            self.next_seq = self.next_seq.wrapping_add(1) & 0x7f;
            let room = self.want - self.have;
            let take = room.min(CONT_PAYLOAD).min(pkt.len() - CONT_HEADER);
            buf[self.have..self.have + take]
                .copy_from_slice(&pkt[CONT_HEADER..CONT_HEADER + take]);
            self.have += take;
            if self.have >= self.want {
                self.busy = false;
                return Event::Message { cid, cmd: self.cmd, len: self.want };
            }
            Event::Idle
        }
    }
}

/// Take a reply apart into packets.
///
/// Yields the initialisation packet and then continuations, each exactly
/// [`PACKET`] bytes. A caller writes each one to the interrupt IN endpoint in
/// order and does nothing else.
pub struct Frames<'a> {
    cid: u32,
    cmd: u8,
    data: &'a [u8],
    sent: usize,
    seq: u8,
    first: bool,
}

/// Frame `data` as `cmd` on `cid`.
pub fn frame(cid: u32, cmd: u8, data: &[u8]) -> Frames<'_> {
    Frames { cid, cmd, data, sent: 0, seq: 0, first: true }
}

impl Iterator for Frames<'_> {
    type Item = [u8; PACKET];

    fn next(&mut self) -> Option<[u8; PACKET]> {
        if !self.first && self.sent >= self.data.len() {
            return None;
        }
        let mut pkt = [0u8; PACKET];
        pkt[..4].copy_from_slice(&self.cid.to_be_bytes());
        if self.first {
            self.first = false;
            pkt[4] = 0x80 | self.cmd;
            pkt[5] = (self.data.len() >> 8) as u8;
            pkt[6] = self.data.len() as u8;
            let n = self.data.len().min(INIT_PAYLOAD);
            pkt[INIT_HEADER..INIT_HEADER + n].copy_from_slice(&self.data[..n]);
            self.sent = n;
        } else {
            pkt[4] = self.seq;
            self.seq = self.seq.wrapping_add(1) & 0x7f;
            let n = (self.data.len() - self.sent).min(CONT_PAYLOAD);
            pkt[CONT_HEADER..CONT_HEADER + n]
                .copy_from_slice(&self.data[self.sent..self.sent + n]);
            self.sent += n;
        }
        Some(pkt)
    }
}

/// The seventeen bytes a `CTAPHID_INIT` is answered with.
///
/// The four version bytes are the **device's own**, not the protocol's — the
/// specification fixes only `CTAPHID protocol version = 2`. Which is why the
/// copies disagreed: exp174 and exp188 sent major 0 / minor 1, exp183 sent
/// major 1 / minor 0, and nothing noticed because nothing depends on them. One
/// number now, so a difference between two firmwares means something.
pub fn init_response(nonce: &[u8; 8], allocated: u32) -> [u8; 17] {
    let mut r = [0u8; 17];
    r[..8].copy_from_slice(nonce);
    r[8..12].copy_from_slice(&allocated.to_be_bytes());
    r[12] = 2; // CTAPHID protocol version
    r[13] = 1; // major
    r[14] = 0; // minor
    r[15] = 0; // build
    r[16] = CAPABILITIES;
    r
}

#[cfg(test)]
mod tests {
    use super::*;

    fn init_pkt(cid: u32, cmd: u8, bcnt: usize, payload: &[u8]) -> [u8; PACKET] {
        let mut p = [0u8; PACKET];
        p[..4].copy_from_slice(&cid.to_be_bytes());
        p[4] = 0x80 | cmd;
        p[5] = (bcnt >> 8) as u8;
        p[6] = bcnt as u8;
        p[INIT_HEADER..INIT_HEADER + payload.len()].copy_from_slice(payload);
        p
    }

    fn cont_pkt(cid: u32, seq: u8, payload: &[u8]) -> [u8; PACKET] {
        let mut p = [0u8; PACKET];
        p[..4].copy_from_slice(&cid.to_be_bytes());
        p[4] = seq;
        p[CONT_HEADER..CONT_HEADER + payload.len()].copy_from_slice(payload);
        p
    }

    /// The 34 bytes are the specification's, and this is the assertion that
    /// says so rather than fifteen copies each hoping.
    #[test]
    fn the_descriptor_is_thirty_four_bytes_starting_with_the_fido_usage_page() {
        assert_eq!(REPORT_DESCRIPTOR.len(), 34);
        assert_eq!(&REPORT_DESCRIPTOR[..3], &[0x06, 0xd0, 0xf1]);
        assert_eq!(*REPORT_DESCRIPTOR.last().unwrap(), 0xc0);
    }

    /// exp183's defect, as a test: 0x08 alone means *no CBOR*.
    #[test]
    fn the_capability_byte_claims_cbor() {
        assert_eq!(CAPABILITIES & 0x04, 0x04, "CAPABILITY_CBOR must be set");
        assert_ne!(CAPABILITIES, 0x08, "0x08 alone is exp168's 'no CBOR at all'");
    }

    #[test]
    fn a_short_message_arrives_in_one_packet() {
        let mut ch = Channel::new();
        let mut buf = [0u8; MAX_MESSAGE];
        let e = ch.feed(&init_pkt(1, CMD_CBOR, 1, &[0x04]), &mut buf);
        assert_eq!(e, Event::Message { cid: 1, cmd: CMD_CBOR, len: 1 });
        assert_eq!(buf[0], 0x04);
        assert!(!ch.busy());
    }

    /// exp168's subject: a 1024-byte PING is eighteen packets.
    #[test]
    fn a_long_message_is_reassembled_out_of_continuations() {
        let mut ch = Channel::new();
        let mut buf = [0u8; MAX_MESSAGE];
        let msg: [u8; 1024] = core::array::from_fn(|i| i as u8);

        assert_eq!(
            ch.feed(&init_pkt(7, CMD_PING, 1024, &msg[..INIT_PAYLOAD]), &mut buf),
            Event::Idle
        );
        let mut sent = INIT_PAYLOAD;
        let mut seq = 0u8;
        let mut last = Event::Idle;
        while sent < 1024 {
            let n = (1024 - sent).min(CONT_PAYLOAD);
            last = ch.feed(&cont_pkt(7, seq, &msg[sent..sent + n]), &mut buf);
            sent += n;
            seq += 1;
        }
        assert_eq!(last, Event::Message { cid: 7, cmd: CMD_PING, len: 1024 });
        assert_eq!(&buf[..1024], &msg[..]);
        assert_eq!(seq, 17, "57 + 17*59 = 1060 >= 1024, so eighteen packets");
    }

    #[test]
    fn a_sequence_number_out_of_order_is_refused_and_frees_the_channel() {
        let mut ch = Channel::new();
        let mut buf = [0u8; MAX_MESSAGE];
        ch.feed(&init_pkt(2, CMD_PING, 200, &[0u8; INIT_PAYLOAD]), &mut buf);
        assert_eq!(
            ch.feed(&cont_pkt(2, 1, &[0u8; CONT_PAYLOAD]), &mut buf),
            Event::Error { cid: 2, code: ERR_INVALID_SEQ }
        );
        assert!(!ch.busy(), "a refused sequence must not hold the channel");
    }

    #[test]
    fn a_second_channel_interrupting_is_told_it_is_busy() {
        let mut ch = Channel::new();
        let mut buf = [0u8; MAX_MESSAGE];
        ch.feed(&init_pkt(3, CMD_PING, 200, &[0u8; INIT_PAYLOAD]), &mut buf);
        assert_eq!(
            ch.feed(&init_pkt(4, CMD_PING, 1, &[9]), &mut buf),
            Event::Error { cid: 4, code: ERR_CHANNEL_BUSY }
        );
        assert!(ch.busy(), "and the transaction in progress is left alone");
        assert_eq!(ch.cid(), 3);
    }

    /// A continuation for a transaction nobody started draws **silence**. exp168
    /// drove this case against a board specifically because answering it would
    /// let anybody make the device talk.
    #[test]
    fn a_stray_continuation_draws_silence() {
        let mut ch = Channel::new();
        let mut buf = [0u8; MAX_MESSAGE];
        assert_eq!(
            ch.feed(&cont_pkt(5, 0, &[1, 2, 3]), &mut buf),
            Event::Ignored("continuation with no transaction")
        );
    }

    #[test]
    fn a_byte_count_past_the_maximum_is_refused() {
        let mut ch = Channel::new();
        let mut buf = [0u8; MAX_MESSAGE];
        assert_eq!(
            ch.feed(&init_pkt(6, CMD_PING, MAX_MESSAGE + 1, &[0u8; INIT_PAYLOAD]), &mut buf),
            Event::Error { cid: 6, code: ERR_INVALID_LEN }
        );
    }

    #[test]
    fn the_broadcast_channel_carries_init_and_nothing_else() {
        let mut ch = Channel::new();
        let mut buf = [0u8; MAX_MESSAGE];
        assert_eq!(
            ch.feed(&init_pkt(BROADCAST, CMD_CBOR, 1, &[4]), &mut buf),
            Event::Error { cid: BROADCAST, code: ERR_INVALID_CHANNEL }
        );
        assert_eq!(
            ch.feed(&init_pkt(BROADCAST, CMD_INIT, 8, &[1, 2, 3, 4, 5, 6, 7, 8]), &mut buf),
            Event::Init { cid: BROADCAST, nonce: [1, 2, 3, 4, 5, 6, 7, 8] }
        );
    }

    #[test]
    fn cancel_abandons_a_transaction_on_its_own_channel() {
        let mut ch = Channel::new();
        let mut buf = [0u8; MAX_MESSAGE];
        ch.feed(&init_pkt(8, CMD_PING, 200, &[0u8; INIT_PAYLOAD]), &mut buf);
        assert_eq!(ch.feed(&init_pkt(8, CMD_CANCEL, 0, &[]), &mut buf), Event::Cancel { cid: 8 });
        assert!(!ch.busy());
    }

    /// Framing and reassembly are each other's inverse, which is the cheapest
    /// property either of them has and the one no copy has ever been checked on.
    #[test]
    fn framing_round_trips_through_reassembly() {
        for len in [0usize, 1, 57, 58, 116, 1024] {
            let msg: Vec<u8> = (0..len).map(|i| (i * 7 + 3) as u8).collect();
            let msg: &[u8] = &msg;
            let mut ch = Channel::new();
            let mut buf = [0u8; MAX_MESSAGE];
            let mut last = Event::Idle;
            for pkt in frame(42, CMD_CBOR, msg) {
                last = ch.feed(&pkt, &mut buf);
            }
            assert_eq!(
                last,
                Event::Message { cid: 42, cmd: CMD_CBOR, len },
                "len {len}"
            );
            assert_eq!(&buf[..len], msg, "len {len}");
        }
    }

    #[test]
    fn an_init_response_is_seventeen_bytes_and_names_the_channel() {
        let r = init_response(&[1, 2, 3, 4, 5, 6, 7, 8], 0x0000_002a);
        assert_eq!(r.len(), 17);
        assert_eq!(&r[..8], &[1, 2, 3, 4, 5, 6, 7, 8]);
        assert_eq!(&r[8..12], &42u32.to_be_bytes());
        assert_eq!(r[16], CAPABILITIES);
    }
}
