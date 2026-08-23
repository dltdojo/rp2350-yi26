#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""A canonical-only CBOR reader, shared by the experiments that came after it.

**Why this file exists.** Four experiments here carry their own host-side CBOR
reader — exp169's, copied forward into exp170, exp171 and exp172, and exp173's —
and both lineages refuse a real authenticator's `authenticatorGetInfo`. exp169's
rejects text map keys; CTAP 2.1 defines `options` and `algorithms` with them.
exp173's has no major type 7, so the first `true` in an options map stops it.
Neither is a bug in what those experiments proved: each reader was written
against the device that experiment measured, and that device never emitted
either. A reader narrower than the protocol is a reader that cannot quietly
accept something wrong, which was the point.

**Why they are not changed.** exp177 and exp178 met the limit on the same day,
against firmware nobody here wrote. The fix went forward, not back: those four
experiments are verified work whose scripts are part of what they demonstrate,
and rewriting them to import this would edit a record to make a later
convenience true. From exp177 on, this is the one to import; before it, each
experiment's own copy stays exactly as it was.

**What it is.** exp169's reader, which refuses everything non-canonical, plus
the two rules it did not need: text map keys, and the ordering CTAP 2.1 gives
them — integers first, then text by length, then text bytewise. It is
deliberately not a general decoder. Every branch a permissive reader would
accept and normalise is a branch where a device could be quietly wrong.

    import importlib.util, os
    spec = importlib.util.spec_from_file_location(
        "yi26_cbor", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cbor.py"))
    cbor = importlib.util.module_from_spec(spec); spec.loader.exec_module(cbor)
    value, at = cbor.decode(body)

`decode` returns `(value, offset)`. A caller that expects to have consumed
everything must check the offset: bytes left over after the top-level item are
not an error to this reader, and are usually an error to the caller.
"""

class NotCanonical(Exception):
    """Valid CBOR that CTAP2 will not accept — a different thing from invalid
    CBOR, and the one a real authenticator could plausibly emit."""


def _key_rank(k):
    """CTAP2's canonical map key order: integers first, then text by length,
    then text bytewise."""
    if isinstance(k, int):
        return (0, k, b"")
    return (1, len(k), k.encode())


def decode(b, at=0, depth=0):
    if at >= len(b):
        raise NotCanonical("ran off the end")
    ib = b[at]
    mt, ai = ib >> 5, ib & 0x1F
    at += 1
    if ai < 24:
        arg = ai
    elif ai == 24:
        arg = b[at]
        if arg < 24:
            raise NotCanonical(f"{arg} written in two bytes; it fits in one")
        at += 1
    elif ai == 25:
        arg = int.from_bytes(b[at:at + 2], "big")
        if arg <= 0xFF:
            raise NotCanonical(f"{arg} written in three bytes; it fits in fewer")
        at += 2
    elif ai == 26:
        arg = int.from_bytes(b[at:at + 4], "big")
        if arg <= 0xFFFF:
            raise NotCanonical(f"{arg} written in five bytes; it fits in fewer")
        at += 4
    elif ai == 27:
        arg = int.from_bytes(b[at:at + 8], "big")
        if arg <= 0xFFFFFFFF:
            raise NotCanonical(f"{arg} written in nine bytes; it fits in fewer")
        at += 8
    elif ai == 31:
        raise NotCanonical("an indefinite length, which CTAP2 forbids")
    else:
        raise NotCanonical(f"reserved additional information {ai}")

    if mt == 0:
        return arg, at
    if mt == 1:
        return -1 - arg, at
    if mt == 2:
        return bytes(b[at:at + arg]), at + arg
    if mt == 3:
        return b[at:at + arg].decode(), at + arg
    if mt == 4:
        out = []
        for _ in range(arg):
            v, at = decode(b, at, depth + 1)
            out.append(v)
        return out, at
    if mt == 5:
        out, last = {}, None
        for _ in range(arg):
            k, at = decode(b, at, depth + 1)
            if not isinstance(k, (int, str)):
                raise NotCanonical("a map key that is neither an integer nor text")
            rank = _key_rank(k)
            if last is not None and rank <= last:
                raise NotCanonical(f"map key {k!r} does not follow the one before it")
            last = rank
            v, at = decode(b, at, depth + 1)
            out[k] = v
        return out, at
    if mt == 7:
        if arg == 20:
            return False, at
        if arg == 21:
            return True, at
        raise NotCanonical(f"simple value {arg}, which this subset does not use")
    raise NotCanonical(f"major type {mt}, which this subset does not use")
