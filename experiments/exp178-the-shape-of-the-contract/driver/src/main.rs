// SPDX-License-Identifier: Apache-2.0
//
// exp178 — the other half of the contract: the engine, running.
//
// ../stub asks what OpenSK demands before it will build. This asks what it
// answers once it is built, and it needs no board, no USB and no stubs: with
// the `std` feature OpenSK ships its own `TestEnv`, which supplies all six
// obligations the stub had to write out by hand. `Ctap::process_hid_packet`
// takes a 64-byte CTAPHID report and returns 64-byte reports, so the whole
// device fits inside a host process and can be spoken to in exactly the bytes
// exp168 put on a wire.
//
// What comes out is fed to closes.py, which checks it against **exp176's own
// list** of the fourteen ways a commercial key differed from this board. Ten of
// those were classified as "code the board could write". This is that code,
// written by somebody else, and the question is how many of the ten it closes.
//
// The packet splitting below is exp128's arithmetic and not a library's: an
// initialisation packet carries 57 bytes of payload and each continuation
// carries 59, and a `makeCredential` request does not fit in one.

use opensk::env::test::TestEnv;
use opensk::{Ctap, Transport};

const BROADCAST: u32 = 0xFFFF_FFFF;
const CTAPHID_INIT: u8 = 0x06;
const CTAPHID_CBOR: u8 = 0x10;

/// Sends one CTAPHID message and reassembles the reply.
///
/// Returns the reply's command byte and its body.
fn message(ctap: &mut Ctap<TestEnv>, cid: u32, cmd: u8, payload: &[u8]) -> (u8, Vec<u8>) {
    let mut replies: Vec<[u8; 64]> = Vec::new();

    let first = payload.len().min(57);
    let mut init = [0u8; 64];
    init[0..4].copy_from_slice(&cid.to_be_bytes());
    init[4] = 0x80 | cmd;
    init[5..7].copy_from_slice(&(payload.len() as u16).to_be_bytes());
    init[7..7 + first].copy_from_slice(&payload[..first]);
    replies.extend(ctap.process_hid_packet(&init, Transport::MainHid));

    let mut sent = first;
    let mut seq = 0u8;
    while sent < payload.len() {
        let n = (payload.len() - sent).min(59);
        let mut cont = [0u8; 64];
        cont[0..4].copy_from_slice(&cid.to_be_bytes());
        cont[4] = seq;
        cont[5..5 + n].copy_from_slice(&payload[sent..sent + n]);
        replies.extend(ctap.process_hid_packet(&cont, Transport::MainHid));
        sent += n;
        seq += 1;
    }

    assert!(!replies.is_empty(), "the engine said nothing at all");
    let head = replies[0];
    let bcnt = u16::from_be_bytes([head[5], head[6]]) as usize;
    let mut body = head[7..].to_vec();
    for packet in &replies[1..] {
        body.extend_from_slice(&packet[5..]);
    }
    body.truncate(bcnt);
    (head[4] & 0x7F, body)
}

/// A canonical `authenticatorMakeCredential` request, written out by hand.
///
/// Hand-written for the same reason exp170's reader is: the lengths in CBOR are
/// input somebody else chose, and a builder that hides them hides the one thing
/// worth looking at. Keys ascend — 1, 2, 3, 4, 7 — because CTAP2 requires it.
fn make_credential(alg: i8, resident: bool) -> Vec<u8> {
    let mut m = vec![0x01]; // authenticatorMakeCredential
    m.push(0xA5); // map of five

    m.push(0x01); // clientDataHash
    m.extend_from_slice(&[0x58, 0x20]);
    m.extend_from_slice(&[0xAB; 32]);

    m.push(0x02); // rp
    m.push(0xA1);
    m.extend_from_slice(&[0x62, b'i', b'd']);
    let rp = b"example.com";
    m.push(0x60 | rp.len() as u8);
    m.extend_from_slice(rp);

    m.push(0x03); // user
    m.push(0xA1);
    m.extend_from_slice(&[0x62, b'i', b'd']);
    m.extend_from_slice(&[0x44, 0xDE, 0xAD, 0xBE, 0xEF]);

    m.push(0x04); // pubKeyCredParams
    m.push(0x81);
    m.push(0xA2);
    m.extend_from_slice(&[0x63, b'a', b'l', b'g']);
    m.push(0x20 | ((-1 - alg as i16) as u8)); // negative integer, shortest form
    m.extend_from_slice(&[0x64, b't', b'y', b'p', b'e']);
    let ty = b"public-key";
    m.push(0x60 | ty.len() as u8);
    m.extend_from_slice(ty);

    m.push(0x07); // options
    m.push(0xA1);
    m.extend_from_slice(&[0x62, b'r', b'k']);
    m.push(if resident { 0xF5 } else { 0xF4 });

    m
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn main() {
    let mut ctap = Ctap::new(TestEnv::default());

    let (_, body) = message(&mut ctap, BROADCAST, CTAPHID_INIT, &[1, 2, 3, 4, 5, 6, 7, 8]);
    let cid = u32::from_be_bytes([body[8], body[9], body[10], body[11]]);
    let caps = body[16];

    let (_, info) = message(&mut ctap, cid, CTAPHID_CBOR, &[0x04]);

    // Announcing a capability and having it are different claims, and exp169
    // is the experiment that made the difference matter. So two of the ten are
    // asked for rather than read off: a resident credential, and a signature
    // algorithm this repository never implemented.
    let (_, rk) = message(&mut ctap, cid, CTAPHID_CBOR, &make_credential(-7, true));
    let (_, eddsa) = message(&mut ctap, cid, CTAPHID_CBOR, &make_credential(-8, false));

    println!("{{");
    println!("  \"engine\": \"opensk\",");
    println!("  \"transport\": \"none — Ctap::process_hid_packet, in this process\",");
    println!("  \"caps\": {caps},");
    println!("  \"getinfo_status\": {},", info[0]);
    println!("  \"getinfo_cbor\": \"{}\",", hex(&info[1..]));
    println!("  \"rk_status\": {},", rk[0]);
    println!("  \"rk_response_bytes\": {},", rk.len().saturating_sub(1));
    println!("  \"eddsa_status\": {},", eddsa[0]);
    println!("  \"eddsa_response_bytes\": {}", eddsa.len().saturating_sub(1));
    println!("}}");
}
