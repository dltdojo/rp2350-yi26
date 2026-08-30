// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 rp2350-yi26 contributors

//! The CTAP-HID transport, as a decision rather than a task.
//!
//! # What this is extracted from, and what decided its shape
//!
//! `ctaphid_task` is defined in **fourteen experiments here as thirteen
//! different functions** — 110 lines at
//! [exp168](../../experiments/exp168-a-security-key-that-knows-nothing/) and 959
//! at [exp189](../../experiments/exp189-the-same-salt-twice/), with exp184
//! forked from a state before the two above it. That is not a component that
//! grew; it is fourteen forks.
//!
//! **A crate copied out of one fork inherits that fork's bugs.**
//! [exp194](../../experiments/exp194-the-transport-that-drifted/) asked six of
//! them the same twelve questions — every one a case where CTAP-HID says what
//! the right answer is — and found that ten of the twelve are answered
//! identically, and that the two exceptions are both at the head of the chain:
//!
//! ```text
//!   bad-cid        exp189 answers ERR_INVALID_PAR where the spec names ERR_INVALID_CHANNEL
//!   busy-recovers  exp189 refuses the broadcast INIT that is a client's only way back
//! ```
//!
//! So this is not exp189's transport tidied up. It is the behaviour five
//! firmwares agreed on and the specification requires, and every one of those
//! twelve answers is a test below.
//!
//! # Two halves, and only one of them needs a board
//!
//! Everything in this file is a decision over bytes and one clock reading, and
//! [`mod tests`](tests) asks it every question the hardware suite asks.
//! [`board`] is the other half: a read with a deadline, and the transport
//! answering by itself the parts that are its own — `INIT`, every error, and the
//! expiry that frees a channel. What is left for a caller is which commands it
//! implements, which is the only part that was ever the experiment's.
//!
//! # Why there is no `async` in the deciding
//!
//! Deciding what an arriving packet means needs no board: it is a state machine
//! over 64-byte reports and one clock reading. [`Transaction::feed`] takes the
//! time as a `u64` of milliseconds rather than reaching for `Instant`, which is
//! the single decision that lets `cargo test` ask a timeout question on a
//! machine with no hardware.
//!
//! That is this repository's existing split, applied again: `log-policy` and
//! `log-ring` have tests where `usb-log` cannot, and `lifeline`'s give-up rule
//! is arithmetic where `lifeline::board` is not. The USB half is
//! [`crates/ctap-hid`'s caller](../../experiments/exp194-the-transport-that-drifted/),
//! and it is thin on purpose.
//!
//! # What it deliberately does not do
//!
//! - **It does not track which channels are open.** A message on a channel this
//!   device never allocated — other than the two the specification reserves — is
//!   accepted. Every firmware here behaves this way and exp194 measured no
//!   disagreement about it, so changing it would be a new behaviour rather than
//!   an extracted one. [`Transaction::feed`] rejects [`BROADCAST`] used for
//!   anything but `INIT`, and [`RESERVED`] for anything at all.
//! - **It knows no commands but `INIT`.** `PING`, `CBOR`, `MSG` and `CANCEL`
//!   are the caller's, because what an authenticator does above the transport is
//!   each experiment's own subject. `INIT` is here because it is not a message
//!   to an application: it is the transport's own bookkeeping.

#![no_std]

/// A channel identifier. Four bytes, big-endian on the wire.
pub type Cid = [u8; 4];

/// One HID report. Fixed by CTAP-HID, not a choice.
pub const PACKET: usize = 64;

/// `CID(4) + CMD(1) + BCNT(2)`, then payload.
pub const INIT_HEADER: usize = 7;
/// `CID(4) + SEQ(1)`, then payload.
pub const CONT_HEADER: usize = 5;
/// 57 bytes in the first packet of a message.
pub const INIT_PAYLOAD: usize = PACKET - INIT_HEADER;
/// 59 bytes in every packet after it.
pub const CONT_PAYLOAD: usize = PACKET - CONT_HEADER;

/// The channel a host uses before it has one of its own. `INIT` and nothing
/// else.
pub const BROADCAST: Cid = [0xff, 0xff, 0xff, 0xff];
/// Never a valid channel, in either direction.
pub const RESERVED: Cid = [0x00, 0x00, 0x00, 0x00];

/// How long a promised-but-unfinished message may sit before it expires.
///
/// **750 ms is the specification's number**, and it is worth stating why it is
/// short. The channel is held for the whole of it, so every millisecond here is
/// a millisecond in which a second client is told the device is busy. exp194
/// measured exp189 taking about four seconds and refusing the recovery path for
/// all of it.
pub const TRANSACTION_TIMEOUT_MS: u64 = 750;

/// The longest message this transport will assemble.
///
/// CTAP-HID's `BCNT` is 16 bits and the specification caps a message at 7609
/// bytes; every firmware in this repository caps it at 1024. What matters is not
/// the number but that one byte past it is refused with [`ERR_INVALID_LEN`]
/// rather than truncated — a device that truncates has answered a question
/// nobody asked.
pub const MAX_MESSAGE: usize = 1024;

pub const CTAPHID_PING: u8 = 0x01;
pub const CTAPHID_MSG: u8 = 0x03;
pub const CTAPHID_INIT: u8 = 0x06;
pub const CTAPHID_CBOR: u8 = 0x10;
pub const CTAPHID_CANCEL: u8 = 0x11;
pub const CTAPHID_KEEPALIVE: u8 = 0x3B;
pub const CTAPHID_ERROR: u8 = 0x3F;

pub const ERR_INVALID_CMD: u8 = 0x01;
pub const ERR_INVALID_PAR: u8 = 0x02;
pub const ERR_INVALID_LEN: u8 = 0x03;
pub const ERR_INVALID_SEQ: u8 = 0x04;
pub const ERR_MSG_TIMEOUT: u8 = 0x05;
pub const ERR_CHANNEL_BUSY: u8 = 0x06;
pub const ERR_INVALID_CHANNEL: u8 = 0x0B;
pub const ERR_OTHER: u8 = 0x7F;

/// What the caller should do about the packet it just handed over.
#[derive(Debug, PartialEq, Eq)]
pub enum Action {
    /// Nothing, and say nothing. A packet from a conversation this device is
    /// not having is not an error to report — answering it would tell a
    /// stranger the device is here.
    Ignore(&'static str),
    /// The message is not whole yet.
    More,
    /// Send `CTAPHID_ERROR` with this code, on this channel.
    Error(Cid, u8),
    /// A whole message is in [`Transaction::message`].
    Complete,
}

/// The one message being assembled.
///
/// CTAP-HID allows one transaction at a time across the whole device, which is
/// why [`ERR_CHANNEL_BUSY`] exists at all.
pub struct Transaction {
    cid: Cid,
    cmd: u8,
    want: usize,
    have: usize,
    seq: u8,
    started_ms: u64,
    active: bool,
    buf: [u8; MAX_MESSAGE],
}

impl Default for Transaction {
    fn default() -> Self {
        Self::new()
    }
}

impl Transaction {
    pub const fn new() -> Self {
        Self {
            cid: RESERVED,
            cmd: 0,
            want: 0,
            have: 0,
            seq: 0,
            started_ms: 0,
            active: false,
            buf: [0; MAX_MESSAGE],
        }
    }

    /// Is a message half-assembled?
    pub fn busy(&self) -> bool {
        self.active
    }

    /// The channel a half-assembled message belongs to.
    pub fn cid(&self) -> Cid {
        self.cid
    }

    /// How long the caller may block before [`expire`](Self::expire) has
    /// something to do, in milliseconds. `None` when nothing is in flight.
    pub fn deadline_ms(&self, now_ms: u64) -> Option<u64> {
        if !self.active {
            return None;
        }
        Some(TRANSACTION_TIMEOUT_MS.saturating_sub(now_ms.saturating_sub(self.started_ms)))
    }

    /// Drop whatever is in flight.
    pub fn clear(&mut self) {
        self.active = false;
        self.have = 0;
        self.want = 0;
        self.seq = 0;
    }

    /// Expire a transaction that has run out of time.
    ///
    /// Returns the channel to send [`ERR_MSG_TIMEOUT`] on. **The caller must
    /// call this on a timer and not only when a packet arrives**, because the
    /// host that abandoned a message is exactly the host that will not send
    /// another one — and until it expires, the device answers every other
    /// channel, and the broadcast channel, with [`ERR_CHANNEL_BUSY`].
    pub fn expire(&mut self, now_ms: u64) -> Option<Cid> {
        if self.active && now_ms.saturating_sub(self.started_ms) >= TRANSACTION_TIMEOUT_MS {
            let cid = self.cid;
            self.clear();
            return Some(cid);
        }
        None
    }

    /// The assembled message: its channel, its command, and its bytes.
    pub fn message(&self) -> (Cid, u8, &[u8]) {
        (self.cid, self.cmd, &self.buf[..self.want])
    }

    /// Judge one 64-byte report.
    pub fn feed(&mut self, pkt: &[u8], now_ms: u64) -> Action {
        if pkt.len() < PACKET {
            return Action::Ignore("a report shorter than 64 bytes");
        }
        let cid: Cid = [pkt[0], pkt[1], pkt[2], pkt[3]];
        let is_init = pkt[4] & 0x80 != 0;

        // Time first. A transaction that has run out is gone before this packet
        // is judged against it, so a slow host is told its message expired
        // rather than being told the channel is busy with its own dead attempt.
        if let Some(stale) = self.expire(now_ms) {
            if cid == stale {
                return Action::Error(stale, ERR_MSG_TIMEOUT);
            }
        }

        if is_init {
            let cmd = pkt[4] & 0x7f;
            let want = ((pkt[5] as usize) << 8) | pkt[6] as usize;

            // The broadcast channel exists for exactly one command, and the
            // reserved one for none.
            if cid == BROADCAST && cmd != CTAPHID_INIT {
                return Action::Error(cid, ERR_INVALID_CHANNEL);
            }
            if cid == RESERVED {
                return Action::Error(cid, ERR_INVALID_CHANNEL);
            }

            // **INIT is not a new transaction, it is a reset.** The
            // specification makes it how a host resynchronises a channel it has
            // lost track of, so it clears whatever was in flight rather than
            // being refused as busy — the opposite of what every other command
            // gets, and the reason this test is above the busy test.
            //
            // exp194 measured what happens when it is not: a device that
            // answers ERR_CHANNEL_BUSY to a broadcast INIT has told the client
            // to go away and left it no way back.
            if cmd == CTAPHID_INIT {
                self.clear();
            } else if self.active && self.cid != cid {
                return Action::Error(cid, ERR_CHANNEL_BUSY);
            }

            if want > MAX_MESSAGE {
                return Action::Error(cid, ERR_INVALID_LEN);
            }
            if cmd == CTAPHID_INIT && want != 8 {
                // An INIT request is a nonce and nothing else.
                return Action::Error(cid, ERR_INVALID_LEN);
            }

            self.cid = cid;
            self.cmd = cmd;
            self.want = want;
            self.seq = 0;
            self.started_ms = now_ms;
            self.active = true;

            let n = want.min(INIT_PAYLOAD);
            self.buf[..n].copy_from_slice(&pkt[INIT_HEADER..INIT_HEADER + n]);
            self.have = n;
        } else {
            if !self.active {
                return Action::Ignore("a continuation packet with no transaction");
            }
            if cid != self.cid {
                return Action::Ignore("a continuation packet from another channel");
            }
            let seq = pkt[4];
            if seq != self.seq {
                let c = self.cid;
                self.clear();
                return Action::Error(c, ERR_INVALID_SEQ);
            }
            self.seq = self.seq.wrapping_add(1);
            let n = (self.want - self.have).min(CONT_PAYLOAD);
            self.buf[self.have..self.have + n].copy_from_slice(&pkt[CONT_HEADER..CONT_HEADER + n]);
            self.have += n;
        }

        if self.have >= self.want {
            self.active = false; // whole: the channel is free again
            Action::Complete
        } else {
            Action::More
        }
    }
}

/// Allocate the next channel identifier, avoiding the two reserved values.
///
/// The caller owns the counter, because a `static` in here would be one counter
/// shared by every user of the crate in a binary — which is right today and is
/// not the crate's business to assume.
pub fn next_cid(counter: &mut u32) -> Cid {
    loop {
        *counter = counter.wrapping_add(1);
        let cid = counter.to_be_bytes();
        if cid != RESERVED && cid != BROADCAST {
            return cid;
        }
    }
}

/// The seventeen bytes an `INIT` is answered with.
///
/// nonce(8) + new channel(4) + protocol(1) + version(3) + capabilities(1). The
/// nonce is echoed so a host can tell its own reply from somebody else's — two
/// clients on one device is the situation the broadcast channel exists for.
pub fn init_reply(nonce: &[u8], new_cid: Cid, capabilities: u8) -> [u8; 17] {
    let mut r = [0u8; 17];
    let n = nonce.len().min(8);
    r[..n].copy_from_slice(&nonce[..n]);
    r[8..12].copy_from_slice(&new_cid);
    r[12] = 2; // CTAPHID protocol version
    r[13] = 0; // device major
    r[14] = 1; // device minor
    r[15] = 0; // device build
    r[16] = capabilities;
    r
}

/// Cut a message into 64-byte reports, calling `out` with each in turn.
///
/// Returns how many packets it took. A closure rather than an iterator because
/// the caller's `write` is `async` and this is not: the caller awaits inside
/// the loop it owns.
pub fn fragment<F: FnMut(&[u8; PACKET])>(cid: Cid, cmd: u8, data: &[u8], mut out: F) -> usize {
    let mut pkt = [0u8; PACKET];
    pkt[..4].copy_from_slice(&cid);
    pkt[4] = 0x80 | cmd;
    pkt[5] = (data.len() >> 8) as u8;
    pkt[6] = data.len() as u8;
    let n = data.len().min(INIT_PAYLOAD);
    pkt[INIT_HEADER..INIT_HEADER + n].copy_from_slice(&data[..n]);
    out(&pkt);

    let mut sent = n;
    let mut seq = 0u8;
    let mut packets = 1;
    while sent < data.len() {
        pkt = [0u8; PACKET];
        pkt[..4].copy_from_slice(&cid);
        pkt[4] = seq;
        let n = (data.len() - sent).min(CONT_PAYLOAD);
        pkt[CONT_HEADER..CONT_HEADER + n].copy_from_slice(&data[sent..sent + n]);
        out(&pkt);
        sent += n;
        seq = seq.wrapping_add(1);
        packets += 1;
    }
    packets
}

/// A human name for a command, for a log.
pub fn cmd_name(cmd: u8) -> &'static str {
    match cmd {
        CTAPHID_PING => "PING",
        CTAPHID_MSG => "MSG",
        CTAPHID_INIT => "INIT",
        CTAPHID_CBOR => "CBOR",
        CTAPHID_CANCEL => "CANCEL",
        CTAPHID_KEEPALIVE => "KEEPALIVE",
        CTAPHID_ERROR => "ERROR",
        _ => "?",
    }
}

/// The board half: the loop, so nobody writes it again.
///
/// Only compiled for the target, so `cargo test` never sees embassy.
#[cfg(target_os = "none")]
pub mod board;

#[cfg(test)]
mod tests;
