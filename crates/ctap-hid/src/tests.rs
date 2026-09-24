// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 rp2350-yi26 contributors
//
//! The twelve cases exp194 asks six boards, asked here with no board.
//!
//! Each test's name is the case name in
//! [`tools/ctaphid/`](../../../tools/ctaphid/ctaphid.py), and each asserts the
//! same answer the specification requires. Two witnesses for one contract: if
//! these pass and the hardware suite fails, the fault is in the USB half; if
//! both fail, it is here.

// `no_std` in the library, `std` here. The tests want a growable buffer to
// build a 1024-byte message with; the crate itself never allocates.
extern crate std;
use std::vec::Vec;

use super::*;

const NONCE: [u8; 8] = [1, 2, 3, 4, 5, 6, 7, 8];
const A: Cid = [0, 0, 0, 1];
const B: Cid = [0, 0, 0, 2];

/// One initialisation packet.
fn init_pkt(cid: Cid, cmd: u8, bcnt: usize, payload: &[u8]) -> [u8; PACKET] {
    let mut p = [0u8; PACKET];
    p[..4].copy_from_slice(&cid);
    p[4] = 0x80 | cmd;
    p[5] = (bcnt >> 8) as u8;
    p[6] = bcnt as u8;
    let n = payload.len().min(INIT_PAYLOAD);
    p[INIT_HEADER..INIT_HEADER + n].copy_from_slice(&payload[..n]);
    p
}

/// One continuation packet.
fn cont_pkt(cid: Cid, seq: u8, payload: &[u8]) -> [u8; PACKET] {
    let mut p = [0u8; PACKET];
    p[..4].copy_from_slice(&cid);
    p[4] = seq;
    let n = payload.len().min(CONT_PAYLOAD);
    p[CONT_HEADER..CONT_HEADER + n].copy_from_slice(&payload[..n]);
    p
}

// -- init -----------------------------------------------------------------

#[test]
fn init_is_answered_with_its_nonce_and_never_enters_the_buffer() {
    let mut t = Transaction::new();
    assert_eq!(t.feed(&init_pkt(BROADCAST, CTAPHID_INIT, 8, &NONCE), 0), Action::Init(BROADCAST, NONCE));
    assert!(!t.busy(), "an INIT is one packet and holds nothing");
}

#[test]
fn init_reply_is_seventeen_bytes_and_echoes_the_nonce() {
    let r = init_reply(&NONCE, A, 0x08);
    assert_eq!(r.len(), 17);
    assert_eq!(&r[..8], &NONCE);
    assert_eq!(&r[8..12], &A);
    assert_eq!(r[12], 2, "CTAPHID protocol version");
    assert_eq!(r[16], 0x08);
}

#[test]
fn init_with_a_byte_count_that_is_not_eight_is_refused() {
    let mut t = Transaction::new();
    assert_eq!(
        t.feed(&init_pkt(BROADCAST, CTAPHID_INIT, 9, &NONCE), 0),
        Action::Error(BROADCAST, ERR_INVALID_LEN)
    );
}

#[test]
fn allocated_channels_are_never_reserved_or_broadcast() {
    let mut counter = u32::MAX - 2;
    for _ in 0..8 {
        let cid = next_cid(&mut counter);
        assert_ne!(cid, RESERVED);
        assert_ne!(cid, BROADCAST);
    }
}

// -- ping -----------------------------------------------------------------

#[test]
fn ping_57_is_one_packet() {
    let mut t = Transaction::new();
    let payload: Vec<u8> = (0..57).map(|i| (i * 7 + 3) as u8).collect();
    assert_eq!(t.feed(&init_pkt(A, CTAPHID_PING, 57, &payload), 0), Action::Complete);
    assert_eq!(t.message().2, &payload[..]);
}

#[test]
fn ping_1024_reassembles_across_continuations() {
    let mut t = Transaction::new();
    let payload: Vec<u8> = (0..MAX_MESSAGE).map(|i| (i * 7 + 3) as u8).collect();
    assert_eq!(t.feed(&init_pkt(A, CTAPHID_PING, MAX_MESSAGE, &payload), 0), Action::More);
    let mut sent = INIT_PAYLOAD;
    let mut seq = 0u8;
    while sent < MAX_MESSAGE {
        let n = (MAX_MESSAGE - sent).min(CONT_PAYLOAD);
        let a = t.feed(&cont_pkt(A, seq, &payload[sent..sent + n]), 0);
        sent += n;
        seq += 1;
        if sent >= MAX_MESSAGE {
            assert_eq!(a, Action::Complete);
        } else {
            assert_eq!(a, Action::More);
        }
    }
    assert_eq!(t.message().2, &payload[..], "every byte came back");
}

#[test]
fn ping_1025_is_refused_and_not_truncated() {
    let mut t = Transaction::new();
    assert_eq!(
        t.feed(&init_pkt(A, CTAPHID_PING, MAX_MESSAGE + 1, &[0xaa; 57]), 0),
        Action::Error(A, ERR_INVALID_LEN)
    );
    assert!(!t.busy(), "a refused message must not hold the channel");
}

// -- bad-seq --------------------------------------------------------------

#[test]
fn a_sequence_number_out_of_order_is_err_invalid_seq() {
    let mut t = Transaction::new();
    assert_eq!(t.feed(&init_pkt(A, CTAPHID_PING, 200, &[0; 57]), 0), Action::More);
    assert_eq!(t.feed(&cont_pkt(A, 3, &[0; 59]), 0), Action::Error(A, ERR_INVALID_SEQ));
    assert!(!t.busy(), "and the transaction is dropped, not left half-built");
}

// -- busy -----------------------------------------------------------------

#[test]
fn a_second_channel_during_a_transaction_is_err_channel_busy() {
    let mut t = Transaction::new();
    assert_eq!(t.feed(&init_pkt(A, CTAPHID_PING, 200, &[0; 57]), 0), Action::More);
    assert_eq!(
        t.feed(&init_pkt(B, CTAPHID_PING, 8, &[0; 8]), 0),
        Action::Error(B, ERR_CHANNEL_BUSY)
    );
    assert_eq!(t.cid(), A, "and A still owns the transaction");
}

// -- busy-recovers --------------------------------------------------------
//
// The case exp189 fails. A client that has lost track sends a broadcast INIT,
// and CTAP-HID has the device answer it whatever else is going on: it is the
// only way back.

#[test]
fn broadcast_init_is_answered_while_another_channel_is_busy() {
    let mut t = Transaction::new();
    assert_eq!(t.feed(&init_pkt(A, CTAPHID_PING, 200, &[0; 57]), 0), Action::More);
    assert_eq!(
        t.feed(&init_pkt(BROADCAST, CTAPHID_INIT, 8, &NONCE), 10),
        Action::Init(BROADCAST, NONCE),
        "a broadcast INIT during a busy transaction must be answered, not refused"
    );
    assert!(t.busy() && t.cid() == A, "and answering it costs A nothing");
}

// -- exp196's H2 ----------------------------------------------------------
//
// TLC's counterexample, replayed: A sends the first packet of a message,
// another client enumerates with a broadcast INIT, A sends the rest. Before
// exp196 the INIT went through the message buffer and cleared it, and A's
// continuation packets were ignored in silence.

#[test]
fn another_clients_init_does_not_silently_eat_a_message_in_flight() {
    let payload: Vec<u8> = (0..200u32).map(|i| (i * 7) as u8).collect();
    let mut packets: Vec<[u8; PACKET]> = Vec::new();
    fragment(A, CTAPHID_PING, &payload, |p| packets.push(*p));

    let mut t = Transaction::new();
    assert_eq!(t.feed(&packets[0], 0), Action::More);
    assert_eq!(t.feed(&init_pkt(BROADCAST, CTAPHID_INIT, 8, &NONCE), 5), Action::Init(BROADCAST, NONCE));
    let mut last = Action::More;
    for p in &packets[1..] {
        last = t.feed(p, 10);
    }
    assert_eq!(last, Action::Complete, "A's message arrived whole");
    assert_eq!(t.message(), (A, CTAPHID_PING, &payload[..]));
}

#[test]
fn an_init_on_another_allocated_channel_leaves_the_message_alone_too() {
    let mut t = Transaction::new();
    assert_eq!(t.feed(&init_pkt(A, CTAPHID_PING, 200, &[0; 57]), 0), Action::More);
    // §11.2.5.3 aborts a transaction on the SAME channel id. B's resync is
    // B's business.
    assert_eq!(t.feed(&init_pkt(B, CTAPHID_INIT, 8, &NONCE), 5), Action::Init(B, NONCE));
    assert!(t.busy() && t.cid() == A);
}

// -- truncated ------------------------------------------------------------

#[test]
fn an_abandoned_transaction_expires_on_the_clock_alone() {
    let mut t = Transaction::new();
    assert_eq!(t.feed(&init_pkt(A, CTAPHID_PING, 200, &[0; 57]), 1_000), Action::More);
    assert_eq!(t.expire(1_000 + TRANSACTION_TIMEOUT_MS - 1), None, "not yet");
    assert_eq!(t.expire(1_000 + TRANSACTION_TIMEOUT_MS), Some(A), "and then it does");
    assert!(!t.busy());
}

#[test]
fn the_deadline_shrinks_as_the_clock_runs() {
    let mut t = Transaction::new();
    assert_eq!(t.deadline_ms(0), None, "nothing in flight, nothing to wait for");
    t.feed(&init_pkt(A, CTAPHID_PING, 200, &[0; 57]), 100);
    assert_eq!(t.deadline_ms(100), Some(TRANSACTION_TIMEOUT_MS));
    assert_eq!(t.deadline_ms(100 + 700), Some(50));
    assert_eq!(t.deadline_ms(100 + 5_000), Some(0), "past due, never negative");
}

#[test]
fn a_packet_arriving_after_the_deadline_is_told_it_timed_out() {
    let mut t = Transaction::new();
    t.feed(&init_pkt(A, CTAPHID_PING, 200, &[0; 57]), 0);
    // Its own channel gets an answer: the host that is late deserves to know
    // its message expired, rather than to be met with silence and left waiting
    // for a reply that is never coming.
    assert_eq!(
        t.feed(&cont_pkt(A, 0, &[0; 59]), TRANSACTION_TIMEOUT_MS + 1),
        Action::Error(A, ERR_MSG_TIMEOUT),
    );
    assert!(!t.busy());
}

#[test]
fn another_channel_arriving_after_the_deadline_gets_the_free_channel() {
    let mut t = Transaction::new();
    t.feed(&init_pkt(A, CTAPHID_PING, 200, &[0; 57]), 0);
    // B is not told about A's expiry — that is A's business — and finds the
    // device free rather than busy, which is the whole reason expiry runs
    // before the packet is judged.
    assert_eq!(
        t.feed(&init_pkt(B, CTAPHID_PING, 8, &[7; 8]), TRANSACTION_TIMEOUT_MS + 1),
        Action::Complete,
    );
    assert_eq!(t.message().0, B);
}

// -- exp196's H1 ----------------------------------------------------------
//
// The test above said "that is A's business" — and before exp196 nobody
// minded it: the expiry was computed, and the channel owed ERR_MSG_TIMEOUT was
// dropped. The board's timer did not send it either, because by the time the
// timer looked the transaction was already gone.

#[test]
fn an_expiry_decided_by_another_channels_packet_is_still_owed_to_its_channel() {
    let mut t = Transaction::new();
    t.feed(&init_pkt(A, CTAPHID_PING, 200, &[0; 57]), 0);
    t.feed(&init_pkt(B, CTAPHID_PING, 8, &[7; 8]), TRANSACTION_TIMEOUT_MS);
    assert_eq!(t.take_expired(), Some(A), "A is owed ERR_MSG_TIMEOUT");
    assert_eq!(t.take_expired(), None, "once");
    assert_eq!(t.expire(TRANSACTION_TIMEOUT_MS * 2), None, "and the timer has nothing left to find");
}

#[test]
fn nothing_is_owed_when_the_late_packet_was_the_stale_channels_own() {
    let mut t = Transaction::new();
    t.feed(&init_pkt(A, CTAPHID_PING, 200, &[0; 57]), 0);
    assert_eq!(t.feed(&cont_pkt(A, 0, &[0; 59]), TRANSACTION_TIMEOUT_MS), Action::Error(A, ERR_MSG_TIMEOUT));
    assert_eq!(t.take_expired(), None, "it was told in the return value, not twice");
}

// -- unknown, bad-cid, stray-cont, init-resets ----------------------------

#[test]
fn the_reserved_channel_is_err_invalid_channel() {
    let mut t = Transaction::new();
    assert_eq!(
        t.feed(&init_pkt(RESERVED, CTAPHID_PING, 4, &[1, 2, 3, 4]), 0),
        Action::Error(RESERVED, ERR_INVALID_CHANNEL),
        "exp189 answers ERR_INVALID_PAR here; five firmwares before it do not"
    );
}

#[test]
fn the_broadcast_channel_carries_nothing_but_init() {
    let mut t = Transaction::new();
    assert_eq!(
        t.feed(&init_pkt(BROADCAST, CTAPHID_PING, 4, &[1, 2, 3, 4]), 0),
        Action::Error(BROADCAST, ERR_INVALID_CHANNEL)
    );
}

#[test]
fn a_stray_continuation_packet_is_ignored_in_silence() {
    let mut t = Transaction::new();
    match t.feed(&cont_pkt(A, 0, &[0; 59]), 0) {
        Action::Ignore(_) => {}
        other => panic!("answering a stray packet tells a stranger the device is here: {other:?}"),
    }
}

#[test]
fn a_continuation_packet_from_another_channel_is_ignored() {
    let mut t = Transaction::new();
    t.feed(&init_pkt(A, CTAPHID_PING, 200, &[0; 57]), 0);
    match t.feed(&cont_pkt(B, 0, &[0; 59]), 0) {
        Action::Ignore(_) => {}
        other => panic!("expected silence, got {other:?}"),
    }
    assert!(t.busy(), "and A's transaction survives it");
}

#[test]
fn init_on_a_busy_channel_resets_it_rather_than_refusing() {
    let mut t = Transaction::new();
    t.feed(&init_pkt(A, CTAPHID_PING, 200, &[0; 57]), 0);
    assert_eq!(
        t.feed(&init_pkt(A, CTAPHID_INIT, 8, &NONCE), 0),
        Action::Init(A, NONCE),
        "answered with the new nonce, not the abandoned PING"
    );
    assert!(!t.busy(), "and its own INIT aborts its own transaction (§11.2.5.3)");
}

// -- fragmentation, which is the other half of reassembly -----------------

#[test]
fn fragment_and_feed_are_inverses() {
    for len in [0usize, 1, 56, 57, 58, 116, 1024] {
        let payload: Vec<u8> = (0..len).map(|i| (i * 13 + 5) as u8).collect();
        let mut packets: Vec<[u8; PACKET]> = Vec::new();
        let n = fragment(A, CTAPHID_PING, &payload, |p| packets.push(*p));
        assert_eq!(n, packets.len());

        let mut t = Transaction::new();
        let mut last = Action::More;
        for p in &packets {
            last = t.feed(p, 0);
        }
        assert_eq!(last, Action::Complete, "len {len}");
        assert_eq!(t.message().2, &payload[..], "len {len}");
    }
}

#[test]
fn a_1024_byte_message_takes_eighteen_packets() {
    let payload = [0u8; MAX_MESSAGE];
    let mut n = 0;
    let packets = fragment(A, CTAPHID_PING, &payload, |_| n += 1);
    assert_eq!(packets, 18);
    assert_eq!(n, 18);
}

#[test]
fn a_short_report_is_ignored_rather_than_read_past() {
    let mut t = Transaction::new();
    match t.feed(&[0u8; 8], 0) {
        Action::Ignore(_) => {}
        other => panic!("expected a short report to be ignored, got {other:?}"),
    }
}
