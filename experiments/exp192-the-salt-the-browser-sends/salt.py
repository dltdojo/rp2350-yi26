#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""
exp192 — what a browser turns a PRF input into, as candidates rather than as an
assertion.

The whole experiment is one question: **a page hands `prf.eval.first` some
bytes; what arrives at the authenticator as an hmac-secret salt?** If it is the
same bytes, then a CLI and a browser derive the same key from the same input and
exp191's vault opens either way. If the browser derives a salt from the input,
they do not, and a vault sealed by one cannot be opened by the other — which
would present as the board being broken, and would not be.

This file does not answer that. It writes down the candidates so the board's own
log can be compared against them, which is the only way this repository allows
the question to be settled. `--selftest` runs on nothing but these bytes.
"""

import hashlib
import sys

# The WebAuthn spec's own construction for the prf extension. If this is what
# happens, the string and the zero byte below are the whole reason a browser and
# a CLI disagree.
PRF_PREFIX = b"WebAuthn PRF\x00"


def candidates(prf_input: bytes) -> "dict[str, bytes]":
    """Every salt a browser could plausibly be sending, named."""
    return {
        # The input, sent unchanged. This is what a reader of the CTAP2 spec
        # alone would expect, and what `fido2-assert` does with its salt line.
        "raw": prf_input,
        # The input, hashed with the spec's prefix.
        "prf-prefixed-sha256": hashlib.sha256(PRF_PREFIX + prf_input).digest(),
        # The input hashed with no prefix, which is what a client that only
        # needed *some* 32 bytes might do.
        "plain-sha256": hashlib.sha256(prf_input).digest(),
    }


def name_for(observed_hex: str, prf_input: bytes) -> str:
    """Which candidate the board actually received, or 'unmatched'.

    A short reading is named with the count it was named on, never silently. The
    board's log ring truncated the first capture at 28 of 32 bytes; 28 bytes
    identify a salt past any argument (a coincidence is 2**-224) and are still
    not the salt, so a run that only has a prefix says which it is and how much
    of it there was.
    """
    observed_hex = observed_hex.strip()
    # An odd length is a line the ring cut in the middle of a byte — 28 bytes
    # and one nibble, in the capture that found this. The half byte is dropped
    # and the count is reported, because "unreadable" would throw away a reading
    # that identifies the salt past any argument.
    truncated_mid_byte = len(observed_hex) % 2 == 1
    if truncated_mid_byte:
        observed_hex = observed_hex[:-1]
    if not observed_hex:
        return "unmatched"
    observed = bytes.fromhex(observed_hex)
    for name, value in candidates(prf_input).items():
        if value == observed:
            return name
    for name, value in candidates(prf_input).items():
        if len(observed) < len(value) and value.startswith(observed):
            how = f"first {len(observed)} of {len(value)} bytes"
            if truncated_mid_byte:
                how += ", the log cut mid-byte"
            return f"{name} ({how})"
    return "unmatched"


def _selftest() -> int:
    i = b"exp192 prf input"
    c = candidates(i)
    assert c["raw"] == i
    assert len(c["prf-prefixed-sha256"]) == 32
    assert len(c["plain-sha256"]) == 32
    # The three must be distinguishable, or observing one proves nothing.
    assert len({bytes(v) for v in c.values()}) == 3, "two candidates collide"
    # A 32-byte input makes `raw` the same length as the others, which is the
    # case that matters: a length check cannot tell them apart, only the bytes.
    i32 = hashlib.sha256(b"exp192").digest()
    c32 = candidates(i32)
    assert all(len(v) == 32 for v in c32.values())
    assert len({bytes(v) for v in c32.values()}) == 3
    assert name_for(c32["prf-prefixed-sha256"].hex(), i32) == "prf-prefixed-sha256"
    assert name_for(c32["raw"].hex(), i32) == "raw"
    assert name_for("00" * 32, i32) == "unmatched"
    # A prefix is named as a prefix, and a prefix of nothing is still unmatched.
    part = c32["prf-prefixed-sha256"].hex()[:56]
    assert name_for(part, i32) == "prf-prefixed-sha256 (first 28 of 32 bytes)"
    assert name_for(part + "a", i32) == \
        "prf-prefixed-sha256 (first 28 of 32 bytes, the log cut mid-byte)"
    assert name_for("11" * 28, i32) == "unmatched"
    # The prefix is exactly what the spec writes: the ASCII name and one zero.
    assert PRF_PREFIX == b"WebAuthn PRF" + bytes([0])
    print("PASS  salt.py selftest: 12 assertions")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    if len(sys.argv) == 2:
        for n, v in candidates(sys.argv[1].encode()).items():
            print(f"{n:24s} {v.hex()}")
    elif len(sys.argv) == 3:
        print(name_for(sys.argv[2], sys.argv[1].encode()))
    else:
        print("usage: salt.py PRF_INPUT [OBSERVED_SALT_HEX] | --selftest", file=sys.stderr)
        raise SystemExit(64)
