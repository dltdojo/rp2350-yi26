// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 rp2350-yi26 contributors

//! The half that needs a board: one loop, so nobody writes it a fifteenth time.
//!
//! [exp194](../../../experiments/exp194-the-transport-that-drifted/) first
//! wrote this as a 97-line task in its own `src/main.rs`, which was already ten
//! times smaller than the 959 lines it replaced — and `experiments/duplication.sh`
//! failed it anyway, because a fifteenth `ctaphid_task` is a fifteenth
//! `ctaphid_task`. The ratchet was right: a loop small enough to feel harmless
//! is exactly the kind that gets copied.
//!
//! So the loop is here, and what stays in an experiment is the only part that
//! was ever its own — **which commands it answers**:
//!
//! ```ignore
//! loop {
//!     let (cid, cmd, n) = wire.next(&mut buf).await;
//!     match cmd {
//!         ctap_hid::CTAPHID_PING => wire.reply(cid, cmd, &buf[..n]).await,
//!         _ => wire.error(cid, ctap_hid::ERR_INVALID_CMD).await,
//!     }
//! }
//! ```

use embassy_futures::select::{select, Either};
use embassy_time::{Duration, Instant, Timer};
use embassy_usb::class::hid::{HidReader, HidWriter};
use embassy_usb::driver::Driver;

use super::{Action, Cid, Transaction, BROADCAST, PACKET, RESERVED};

/// The largest number of packets a [`MAX_MESSAGE`](super::MAX_MESSAGE) reply
/// takes: 57 bytes in the first, 59 in each of the rest.
const MAX_PACKETS: usize = 1 + (super::MAX_MESSAGE - super::INIT_PAYLOAD).div_ceil(super::CONT_PAYLOAD);

/// The transport, running.
///
/// Owns the reassembly state, the channel counter and both ends of the HID
/// interface. [`next`](Self::next) answers everything the transport owns and
/// returns only what it does not.
pub struct Wire<'d, D: Driver<'d>> {
    reader: HidReader<'d, D, PACKET>,
    writer: HidWriter<'d, D, PACKET>,
    transaction: Transaction,
    next_cid: u32,
    capabilities: u8,
}

impl<'d, D: Driver<'d>> Wire<'d, D> {
    /// `capabilities` is the byte an `INIT` reply advertises. exp169 measured
    /// what claiming one a build does not have costs, so it is a parameter
    /// rather than a constant: a firmware with no CBOR must not say it has any.
    pub fn new(
        reader: HidReader<'d, D, PACKET>,
        writer: HidWriter<'d, D, PACKET>,
        capabilities: u8,
    ) -> Self {
        Self { reader, writer, transaction: Transaction::new(), next_cid: 0, capabilities }
    }

    /// Send a message, fragmented.
    pub async fn reply(&mut self, cid: Cid, cmd: u8, data: &[u8]) -> usize {
        // Staged in an array because `fragment`'s closure is not `async` and
        // `write` is. The `min` is not defensive noise: it is what makes a
        // larger `MAX_MESSAGE` one day a truncated reply rather than a panic.
        let mut out = [[0u8; PACKET]; MAX_PACKETS];
        let mut i = 0usize;
        let n = super::fragment(cid, cmd, data, |p| {
            if i < out.len() {
                out[i] = *p;
                i += 1;
            }
        });
        for p in out.iter().take(n.min(out.len())) {
            let _ = self.writer.write(p).await;
        }
        n
    }

    /// Send one of the errors the specification names.
    pub async fn error(&mut self, cid: Cid, code: u8) {
        self.reply(cid, super::CTAPHID_ERROR, &[code]).await;
    }

    /// The next message this device has to decide something about.
    ///
    /// Never returns `INIT`, an error, or an expiry — those are the transport's
    /// own and are answered here. Returns `(channel, command, length)`, with the
    /// payload written into `out`.
    ///
    /// **The deadline is the part that must not be dropped.** A host that
    /// abandons a message is exactly the host that will not send another one, so
    /// waiting only for the next packet leaves the channel held — and while it
    /// is held, every other channel and the broadcast channel are refused.
    /// exp194 measured a firmware doing that for four seconds against a
    /// specified 750 ms.
    pub async fn next(&mut self, out: &mut [u8]) -> (Cid, u8, usize) {
        let mut pkt = [0u8; PACKET];
        loop {
            let now = Instant::now().as_millis();
            let wait = self
                .transaction
                .deadline_ms(now)
                .map(Duration::from_millis)
                .unwrap_or(Duration::from_secs(3600));

            let got = match select(self.reader.read(&mut pkt), Timer::after(wait)).await {
                Either::First(Ok(n)) => n,
                Either::First(Err(_)) => continue,
                Either::Second(()) => {
                    let now = Instant::now().as_millis();
                    if let Some(cid) = self.transaction.expire(now) {
                        self.error(cid, super::ERR_MSG_TIMEOUT).await;
                    }
                    continue;
                }
            };

            let now = Instant::now().as_millis();
            match self.transaction.feed(&pkt[..got], now) {
                Action::Ignore(_) | Action::More => continue,
                Action::Error(cid, code) => self.error(cid, code).await,
                Action::Complete => {
                    let (cid, cmd, data) = self.transaction.message();
                    if cmd == super::CTAPHID_INIT {
                        let new = super::next_cid(&mut self.next_cid);
                        let r = super::init_reply(data, new, self.capabilities);
                        self.transaction.clear();
                        self.reply(cid, super::CTAPHID_INIT, &r).await;
                        continue;
                    }
                    let n = data.len().min(out.len());
                    out[..n].copy_from_slice(&data[..n]);
                    self.transaction.clear();
                    return (cid, cmd, n);
                }
            }
        }
    }
}

/// How a long operation ended.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Waited {
    /// The condition the caller was waiting for came true.
    Ready,
    /// The client sent `CTAPHID_CANCEL` on the channel that owns the operation.
    Cancelled,
    /// Nobody answered in time.
    TimedOut,
}

impl<'d, D: Driver<'d>> Wire<'d, D> {
    /// Hold a channel for an operation that takes a person, saying so.
    ///
    /// Polls `ready` and returns [`Waited::Ready`] as soon as it is true;
    /// returns [`Waited::Cancelled`] on `CTAPHID_CANCEL` from the owning
    /// channel, and [`Waited::TimedOut`] after `timeout`.
    ///
    /// While it waits it does three things, and the third is why this is in the
    /// crate rather than in each experiment:
    ///
    /// 1. **Sends `CTAPHID_KEEPALIVE` every `interval`**, carrying `status`.
    ///    [exp174](../../../experiments/exp174-a-deadline-nobody-mentioned/)
    ///    measured what its absence costs: a browser gave up on a board that
    ///    was working, at twenty-five seconds, and the same board with
    ///    keepalives on was accepted.
    /// 2. **Refuses other allocated channels** with `ERR_CHANNEL_BUSY`, which
    ///    is what a device with one transaction owes a second client.
    /// 3. **Answers a broadcast `INIT`.** This is the part
    ///    [exp194](../../../experiments/exp194-the-transport-that-drifted/)
    ///    measured being got wrong, twice, in one firmware — once after a busy
    ///    refusal and once here. Broadcast `INIT` is a client's only way back
    ///    when it has lost track, and a wait for a person can be thirty
    ///    seconds long. A device that answers `ERR_CHANNEL_BUSY` to it has told
    ///    the client to go away and left it no way to return.
    pub async fn wait_for<F>(
        &mut self,
        cid: Cid,
        status: u8,
        interval: Duration,
        poll: Duration,
        timeout: Duration,
        mut ready: F,
    ) -> Waited
    where
        F: FnMut() -> bool,
    {
        let start = Instant::now();
        let mut next_keepalive = start + interval;
        let mut pkt = [0u8; PACKET];

        loop {
            if ready() {
                return Waited::Ready;
            }
            if start.elapsed() >= timeout {
                return Waited::TimedOut;
            }

            if let Either::First(Ok(n)) =
                select(self.reader.read(&mut pkt), Timer::after(poll)).await
            {
                if n >= 5 && pkt[4] & 0x80 != 0 {
                    let from: Cid = [pkt[0], pkt[1], pkt[2], pkt[3]];
                    let cmd = pkt[4] & 0x7f;
                    if from == cid && cmd == super::CTAPHID_CANCEL {
                        return Waited::Cancelled;
                    }
                    if from == BROADCAST && cmd == super::CTAPHID_INIT {
                        // The way back. Answered here whatever else is going on.
                        let new = super::next_cid(&mut self.next_cid);
                        let r = super::init_reply(
                            &pkt[super::INIT_HEADER..super::INIT_HEADER + 8],
                            new,
                            self.capabilities,
                        );
                        self.reply(BROADCAST, super::CTAPHID_INIT, &r).await;
                    } else if from != cid && from != RESERVED && from != BROADCAST {
                        self.error(from, super::ERR_CHANNEL_BUSY).await;
                    }
                }
            }

            if Instant::now() >= next_keepalive {
                self.reply(cid, super::CTAPHID_KEEPALIVE, &[status]).await;
                next_keepalive = Instant::now() + interval;
            }
        }
    }
}
