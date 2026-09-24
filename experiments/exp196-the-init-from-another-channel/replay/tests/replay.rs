// SPDX-License-Identifier: Apache-2.0
//
// TLC's two counterexamples from model/CtapHid.tla, replayed through the real
// Transaction::feed — once against the crate before exp196, once after.

const A: [u8; 4] = [0, 0, 0, 1];
const B: [u8; 4] = [0, 0, 0, 2];
const NONCE: [u8; 8] = *b"exp196!!";
const PACKET: usize = 64;

fn init_pkt(cid: [u8; 4], cmd: u8, bcnt: u16, payload: &[u8]) -> [u8; PACKET] {
    let mut p = [0u8; PACKET];
    p[..4].copy_from_slice(&cid);
    p[4] = 0x80 | cmd;
    p[5] = (bcnt >> 8) as u8;
    p[6] = bcnt as u8;
    p[7..7 + payload.len()].copy_from_slice(payload);
    p
}

/// A's 200-byte PING, as the packets a host would send.
fn a_message() -> (Vec<u8>, Vec<[u8; PACKET]>) {
    let payload: Vec<u8> = (0..200u32).map(|i| (i * 7) as u8).collect();
    let mut packets = Vec::new();
    after::fragment(A, after::CTAPHID_PING, &payload, |p| packets.push(*p));
    (payload, packets)
}

// --- H2: ASendInit -> BBcastInit, then A's continuation packets ------------

#[test]
fn h2_before_exp196_another_clients_init_ate_the_message_in_silence() {
    use before::*;
    let (_, packets) = a_message();
    let mut t = Transaction::new();
    assert_eq!(t.feed(&packets[0], 0), Action::More);
    assert_eq!(t.feed(&init_pkt(BROADCAST, CTAPHID_INIT, 8, &NONCE), 5), Action::Complete);
    t.clear(); // what the board did after answering the INIT
    for p in &packets[1..] {
        assert_eq!(
            t.feed(p, 10),
            Action::Ignore("a continuation packet with no transaction"),
            "reproduced: A's continuation packets are ignored, and A is told nothing"
        );
    }
}

#[test]
fn h2_after_exp196_the_message_arrives_whole() {
    use after::*;
    let (payload, packets) = a_message();
    let mut t = Transaction::new();
    assert_eq!(t.feed(&packets[0], 0), Action::More);
    assert_eq!(t.feed(&init_pkt(BROADCAST, CTAPHID_INIT, 8, &NONCE), 5), Action::Init(BROADCAST, NONCE));
    let mut last = Action::More;
    for p in &packets[1..] {
        last = t.feed(p, 10);
    }
    assert_eq!(last, Action::Complete);
    assert_eq!(t.message(), (A, CTAPHID_PING, &payload[..]));
}

// --- H1: ASendInit -> Tick -> Tick -> (another channel's packet) -----------

#[test]
fn h1_before_exp196_the_expiry_was_decided_and_dropped() {
    use before::*;
    let (_, packets) = a_message();
    let mut t = Transaction::new();
    t.feed(&packets[0], 0);
    let got = t.feed(&init_pkt(B, CTAPHID_PING, 8, &[7; 8]), TRANSACTION_TIMEOUT_MS);
    assert_eq!(got, Action::Complete, "B is served");
    assert!(!t.busy(), "A's transaction is gone");
    assert_eq!(t.expire(TRANSACTION_TIMEOUT_MS * 2), None, "reproduced: and the timer has nothing left to tell A");
}

#[test]
fn h1_after_exp196_the_expiry_is_still_owed_to_a() {
    use after::*;
    let (_, packets) = a_message();
    let mut t = Transaction::new();
    t.feed(&packets[0], 0);
    let got = t.feed(&init_pkt(B, CTAPHID_PING, 8, &[7; 8]), TRANSACTION_TIMEOUT_MS);
    assert_eq!(got, Action::Complete, "B is served, as before");
    assert_eq!(t.take_expired(), Some(A), "and A is owed ERR_MSG_TIMEOUT");
}
