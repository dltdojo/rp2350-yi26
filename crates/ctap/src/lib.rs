// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 rp2350-yi26 contributors
//! The part of an authenticator that is the same in every one of them.
//!
//! # Why this exists, in numbers
//!
//! By exp189 the authenticator road had **fifteen firmwares and 24,507 lines**,
//! and each new one began as a copy of the last. exp189's `main.rs` differs
//! from exp188's in 610 of 2,771 lines; exp182's from exp174's in 352. The
//! 34-byte report descriptor the CTAP specification fixes exists **fifteen
//! times**, `parse_make_credential` twelve, `derive_key` eleven.
//!
//! What that cost is not hypothetical, and one round of it is written up in
//! [`docs/2026-08-29-1034-exp189-round-briefing-zh-tw.md`][briefing]:
//!
//! - **exp183** rewrote the CTAPHID layer by hand and answered `CTAPHID_INIT`
//!   with `0x08` under a comment saying `CBOR`. `0x08` is `CAPABILITY_NMSG`.
//!   Every `libfido2` client read it as *no CBOR* and asked nothing — which hid
//!   a crash that took the board off the bus on the **second** CBOR command of
//!   any boot, for the entire life of the experiment.
//! - **exp188** read `makeCredential`'s key `0x06` as `pinUvAuthParam`. It is
//!   `extensions`; `0x06` is pinUvAuthParam in *getAssertion*. Every
//!   `makeCredential` carrying any extension was refused.
//! - **exp189** was a copy of exp188 and inherited that one unchanged.
//!
//! Three defects, all in code that fifteen firmwares each keep their own copy
//! of, none of them findable by any test this repository could run — because a
//! copy can only ever be tested on hardware, and hardware costs somebody a walk
//! to a bench.
//!
//! # What is here, and what is deliberately not
//!
//! **Here:** the bytes and rules the specification fixes. The report
//! descriptor, the capability byte, packet geometry, the channel state machine
//! that reassembles a message out of an initialisation packet and its
//! continuations, the framing that takes a reply apart again, and the parsers
//! for the two requests whose lengths an attacker chooses.
//!
//! **Not here:** anything that is a firmware's own decision. No USB types, no
//! `embassy` anything, no cryptography, no key, no policy about what to
//! announce, and nothing that reads a button. An experiment keeps every line
//! that is the thing it demonstrates — which is the whole reason
//! [exp168](../../experiments/exp168-a-security-key-that-knows-nothing/) still
//! writes those 34 bytes out by hand, and must go on doing so.
//!
//! **Everything here runs on a host with no board.** That is the only thing a
//! crate gives that a copy cannot.
//!
//! # Which experiments use it
//!
//! Forward, not back. exp168 through exp187 are verified work whose copies are
//! part of what they demonstrate, and they keep them — the same ruling
//! `experiments/cbor.py` records for the four host-side CBOR readers. What
//! changed here is only what was already proven wrong and had to be re-verified
//! anyway: exp183, exp188, and exp189.
//!
//! [briefing]: ../../docs/2026-08-29-1034-exp189-round-briefing-zh-tw.md

#![cfg_attr(not(test), no_std)]

pub mod ctap2;
pub mod hid;
