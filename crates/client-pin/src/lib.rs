// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 rp2350-yi26 contributors

//! CTAP 2.1 clientPIN's retry counter, as a decision rather than as code
//! scattered through a command handler.
//!
//! # What this is extracted from, and what it corrects
//!
//! exp186 through exp189 each carried their own `PinState` and their own
//! `setPIN`, `changePIN` and `getPinToken`, and all four made the same five
//! mistakes, because each was copied from the one before it.
//! [exp197](../../experiments/exp197-the-counter-that-forgets/) read them
//! against CTAP 2.1 and modelled the counter; every rule below quotes the
//! sentence it comes from.
//!
//! 1. **`setPIN` overwrote a PIN that was already set.** §6.5.5.5: "If a PIN
//!    has already been set, authenticator returns CTAP2_ERR_PIN_AUTH_INVALID
//!    error." Without it, anything on the host could replace the owner's PIN —
//!    no power cycle, no old PIN — and reset the counter while it was at it.
//! 2. **The counter was decremented after the compare, and only on a
//!    mismatch.** The specification's order is "Authenticator decrements the
//!    pinRetries counter by 1" *and then* "decrypts pinHashEnc … and verifies".
//!    Decrementing first means the guess is paid for before its answer exists;
//!    comparing first means an attacker who can cut the power between the
//!    compare and the decrement learns the answer for free. [`Attempt`] makes
//!    the order the only one there is.
//! 3. **Three consecutive mismatches did nothing.** "If the authenticator sees
//!    3 consecutive mismatches, it returns CTAP2_ERR_PIN_AUTH_BLOCKED,
//!    indicating that power cycling is needed for further operations. This is
//!    done so that malware running on the platform should not be able to block
//!    the device without user interaction." Without it, malware could spend all
//!    eight retries and lock the owner out.
//! 4. **Three error codes were wrong** in all four copies: `PIN_BLOCKED` was
//!    `0x34` (the specification's `PIN_AUTH_BLOCKED`), `PIN_AUTH_BLOCKED` was
//!    `0x36` (`PUAT_REQUIRED`), `PIN_AUTH_INVALID` was `0x32` (`PIN_BLOCKED`).
//!    The table is in [`code`].
//! 5. **Everything lives in RAM**, which this crate does not fix and says so:
//!    see [the next section](#the-part-this-crate-cannot-fix).
//!
//! # The part this crate cannot fix
//!
//! `PinState` is a value, and every firmware here keeps it in RAM. A power
//! cycle therefore forgets the PIN itself, and after it anyone can `setPIN` a
//! PIN of their own and be issued a token. exp197's model states it plainly:
//! with RAM storage, "the owner's PIN cannot be replaced" is violated by
//! unplugging the board. Closing it means persisting the PIN and the counter
//! in flash, which is its own experiment.
//!
//! What this crate does instead is make persistence impossible to get wrong in
//! the order that matters. [`PinState::begin`] decrements and hands back an
//! [`Attempt`] whose [`Attempt::retries_to_persist`] is what must be written
//! down **before** [`Attempt::judge`] looks at the PIN — the "write the counter,
//! then compare" order a power-cut attacker cannot get around. Today the
//! firmware writes nothing, and the order is kept anyway, so that adding flash
//! later cannot put it back the wrong way round.
//!
//! The consecutive-mismatch count is meant to be RAM, and is: the specification
//! makes a power cycle — a person — the thing that clears it.

#![no_std]

/// The most attempts a PIN gets. "pinRetries … Maximum value 8".
pub const MAX_RETRIES: u8 = 8;

/// Mismatches in a row before a power cycle is needed.
pub const MAX_CONSECUTIVE: u8 = 3;

/// `LEFT(SHA-256(pin), 16)` — what an authenticator stores, and what a
/// platform sends encrypted.
pub type PinHash = [u8; 16];

/// A token issued by `getPinToken`.
pub type Token = [u8; 32];

/// CTAP 2.1's status codes for clientPIN, from the specification's table.
pub mod code {
    pub const PIN_INVALID: u8 = 0x31;
    pub const PIN_BLOCKED: u8 = 0x32;
    pub const PIN_AUTH_INVALID: u8 = 0x33;
    pub const PIN_AUTH_BLOCKED: u8 = 0x34;
    pub const PIN_NOT_SET: u8 = 0x35;
}

/// Why an attempt was refused before any PIN was looked at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refused {
    /// No PIN is set.
    NotSet,
    /// The counter is at zero; only `authenticatorReset` brings it back.
    Blocked,
    /// Three mismatches in a row; only a power cycle brings it back.
    AuthBlocked,
}

impl Refused {
    /// The CTAP2 status byte to answer with.
    pub const fn code(self) -> u8 {
        match self {
            Refused::NotSet => code::PIN_NOT_SET,
            Refused::Blocked => code::PIN_BLOCKED,
            Refused::AuthBlocked => code::PIN_AUTH_BLOCKED,
        }
    }
}

/// What a judged attempt came to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// The PIN matched. The counter is back at [`MAX_RETRIES`].
    Correct,
    /// It did not, and there are attempts left.
    Invalid,
    /// It did not, and that was the last one.
    Blocked,
    /// It did not, three times in a row.
    AuthBlocked,
}

impl Verdict {
    /// The CTAP2 status byte to answer a mismatch with. `None` for
    /// [`Verdict::Correct`], which the caller answers with its own success.
    pub const fn code(self) -> Option<u8> {
        match self {
            Verdict::Correct => None,
            Verdict::Invalid => Some(code::PIN_INVALID),
            Verdict::Blocked => Some(code::PIN_BLOCKED),
            Verdict::AuthBlocked => Some(code::PIN_AUTH_BLOCKED),
        }
    }
}

/// `setPIN` was refused: a PIN is already set, and changing it is
/// `changePIN`'s job, which needs the old one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AlreadySet;

impl AlreadySet {
    /// "If a PIN has already been set, authenticator returns
    /// CTAP2_ERR_PIN_AUTH_INVALID error."
    pub const fn code(self) -> u8 {
        code::PIN_AUTH_INVALID
    }
}

/// The PIN, its counter, and the token it last issued.
pub struct PinState {
    set: bool,
    hash: PinHash,
    retries: u8,
    consecutive: u8,
    /// The token `getPinToken` issued last, if any. Kept here because a reset
    /// or a new PIN has to forget it along with everything else.
    pub active_token: Option<Token>,
}

impl Default for PinState {
    fn default() -> Self {
        Self::new()
    }
}

impl PinState {
    /// No PIN, a full counter, no token — what `authenticatorReset` leaves.
    pub const fn new() -> Self {
        Self { set: false, hash: [0; 16], retries: MAX_RETRIES, consecutive: 0, active_token: None }
    }

    /// `authenticatorReset`: forget the PIN, refill the counter, drop the token.
    pub fn reset(&mut self) {
        *self = Self::new();
    }

    /// `clientPin` in `authenticatorGetInfo`.
    pub fn is_set(&self) -> bool {
        self.set
    }

    /// `pinRetries`, for `getPINRetries`.
    pub fn retries(&self) -> u8 {
        self.retries
    }

    /// What a power cycle does to a state that survives it: the
    /// consecutive-mismatch count is RAM by design, and a person unplugging the
    /// board is the one thing the specification lets clear it. With the state
    /// itself in RAM, as today, a power cycle is [`PinState::new`] instead.
    pub fn power_cycle(&mut self) {
        self.consecutive = 0;
        self.active_token = None;
    }

    /// `setPIN`. Refused if a PIN is already set.
    pub fn set_pin(&mut self, hash: &PinHash) -> Result<(), AlreadySet> {
        if self.set {
            return Err(AlreadySet);
        }
        self.set = true;
        self.hash = *hash;
        self.retries = MAX_RETRIES;
        self.consecutive = 0;
        self.active_token = None;
        Ok(())
    }

    /// Begin a PIN attempt — `getPinToken`, or `changePIN`'s check of the old
    /// PIN — and pay for it.
    ///
    /// Refuses without touching anything when no PIN is set, when the counter
    /// is at zero, or after three consecutive mismatches. Otherwise the counter
    /// is **already decremented** when this returns: persist
    /// [`Attempt::retries_to_persist`] if the counter is persisted, and only
    /// then [`Attempt::judge`].
    pub fn begin(&mut self) -> Result<Attempt<'_>, Refused> {
        if !self.set {
            return Err(Refused::NotSet);
        }
        if self.retries == 0 {
            return Err(Refused::Blocked);
        }
        if self.consecutive >= MAX_CONSECUTIVE {
            return Err(Refused::AuthBlocked);
        }
        self.retries -= 1;
        Ok(Attempt { state: self })
    }
}

/// A paid-for PIN attempt, not yet judged.
///
/// Dropping it without judging is allowed and costs the attempt: the counter
/// stays decremented, exactly as it would if the power went at this point.
#[must_use = "an attempt is paid for; judge it, or accept that it was spent"]
pub struct Attempt<'a> {
    state: &'a mut PinState,
}

impl Attempt<'_> {
    /// What the counter now holds. Write this down before judging.
    pub fn retries_to_persist(&self) -> u8 {
        self.state.retries
    }

    /// Compare the presented PIN hash with the stored one, in constant time.
    pub fn judge(self, presented: &PinHash) -> Verdict {
        judge(self.state, presented)
    }

    /// The presented PIN could not even be decrypted. "If an error results, or
    /// a mismatch is detected" — the specification counts it as a mismatch,
    /// and so does this.
    pub fn mismatch(self) -> Verdict {
        miss(self.state)
    }

    /// `changePIN`: judge the old PIN and, only if it matched, store the new
    /// one and forget the old token.
    pub fn judge_and_change(self, presented: &PinHash, new: &PinHash) -> Verdict {
        let verdict = judge(self.state, presented);
        if verdict == Verdict::Correct {
            self.state.hash = *new;
            self.state.active_token = None;
        }
        verdict
    }
}

fn judge(state: &mut PinState, presented: &PinHash) -> Verdict {
    if ct_eq(presented, &state.hash) {
        state.retries = MAX_RETRIES;
        state.consecutive = 0;
        return Verdict::Correct;
    }
    miss(state)
}

fn miss(state: &mut PinState) -> Verdict {
    state.consecutive = state.consecutive.saturating_add(1);
    // The specification's order of conditions: zero first, then three in a
    // row, then an ordinary mismatch.
    if state.retries == 0 {
        Verdict::Blocked
    } else if state.consecutive >= MAX_CONSECUTIVE {
        Verdict::AuthBlocked
    } else {
        Verdict::Invalid
    }
}

/// Equality that takes the same time whichever byte differs.
fn ct_eq(a: &PinHash, b: &PinHash) -> bool {
    let mut diff = 0u8;
    for i in 0..a.len() {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

#[cfg(test)]
mod tests;
