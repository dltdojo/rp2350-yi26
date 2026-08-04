//! A tiny host program that forges a CRC on a real artifact and shows the
//! contrast with a hash, so `run.sh` and `check.sh` demonstrate the point
//! against this repository's own output rather than a synthetic buffer.
//!
//! Usage: forge <image-file>
//!
//! It reads the file, treats it as "somebody else's image", forges four bytes
//! of its tail so the CRC32 matches a target taken from a different image, and
//! prints what moved. It writes nothing back — the forgery lives in memory,
//! because the point is that it *would* pass, not to leave one lying around.

use std::fs;

// This file is compiled with `--extern image_integrity=<rlib>` by check.sh and
// run.sh, which build the crate first. It is not a member of the crate.
use image_integrity::{crc32, forge_crc32, sha256};

fn main() {
    let path = std::env::args().nth(1).expect("usage: forge <image-file>");
    let real = fs::read(&path).expect("read image");

    // The "good" image is this artifact; the "evil" one is the same bytes with
    // its first 64 bytes changed, standing in for a different build. Its CRC
    // starts out different, and we forge it back.
    let target = crc32(&real);
    let mut evil = real.clone();
    for b in &mut evil[..64] {
        *b ^= 0xFF;
    }

    println!("artifact:        {} ({} bytes)", path, real.len());
    println!("good CRC32:      {:#010x}", target);
    println!("evil CRC32:      {:#010x}  (before forging)", crc32(&evil));

    let window = evil.len() - 4;
    assert!(forge_crc32(&mut evil, window, target), "forge failed");

    println!("evil CRC32:      {:#010x}  (after forging four bytes at {})", crc32(&evil), window);
    println!("  -> the CRC check PASSES on an image that is not the one it checked against");

    let gh = sha256(&real);
    let eh = sha256(&evil);
    println!("good SHA-256:    {}", hex(&gh[..8]));
    println!("evil SHA-256:    {}", hex(&eh[..8]));
    println!("  -> the hashes differ, and no four bytes make them agree");
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect::<String>() + "..."
}
