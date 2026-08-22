#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build one request for exp167's slot A.

    python3 sign.py <assembled-ab.uf2> <mode> [seed]

exp166 signed bytes at a flash offset and the board read that offset directly.
Here it cannot: **the ROM gives a running image a 64 KiB aperture onto its own
partition and nothing else**, so a virtual offset X in slot A is physical
`0x1000 + X`, and slot B's physical `0x11000` has no virtual address at all.
The `--remap` arithmetic below is that fact, written once.

Modes:

    good          a correct signature by the trusted key, over a region of
                  slot A that the aperture actually reaches
    wrong-key     the same region, signed by a second key the board has
                  never heard of
    flip-sig      the trusted key's signature with one bit turned over
    unreadable    names slot B where it really lives (physical 0x11000).
                  The board refuses this **without dereferencing it**, which
                  is the guard this experiment was wedged into existing
    truncated     the frame cut short

Prints JSON: the escaped wire bytes, and the SHA-256 this script computed, so
the caller can compare it with the digest the board prints.

The private keys are test keys, published in the README, and never on a board.
"""

import json
import random
import sys

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

TRUSTED_PRIV = 0xA7C08E6335CC688CED091DA7F381971AEE587D3783F9924233D85E488A034FE0
OTHER_PRIV = 0xA03A8C8CD7659136F840EA68AE7005C25C5A84D3A236EFD557ECF4EB6086F174

CMD_VERIFY = 1
FRAME_LEN = 73
UF2_MAGIC0 = 0x0A324655
UF2_MAGIC1 = 0x9E5D5157

#: `partimg ab` puts slot A at sector 1 and slot B at sector 17, and the ROM
#: maps slot A's partition to the XIP base. So the board's virtual offset X is
#: this script's physical offset `A_PHYS + X`.
A_PHYS = 0x1000
B_PHYS = 0x11000


def uf2_image(path):
    """The flat flash contents a UF2 produces, gaps filled with 0xFF.

    A gap here is the layout, not damage: the table is at sector 0, slot A at
    sector 1 and slot B at sector 17, with erased flash between. Erased flash
    reads as 0xFF and that is what the board will hash.
    """
    blocks = []
    raw = open(path, "rb").read()
    for i in range(0, len(raw), 512):
        b = raw[i : i + 512]
        if len(b) < 512:
            break
        if int.from_bytes(b[0:4], "little") != UF2_MAGIC0:
            continue
        if int.from_bytes(b[4:8], "little") != UF2_MAGIC1:
            continue
        addr = int.from_bytes(b[12:16], "little")
        size = int.from_bytes(b[16:20], "little")
        blocks.append((addr, b[32 : 32 + size]))
    if not blocks:
        raise SystemExit(f"{path}: no UF2 blocks")
    blocks.sort()
    base = blocks[0][0]
    end = max(a + len(d) for a, d in blocks)
    out = bytearray(b"\xff" * (end - base))
    for addr, data in blocks:
        out[addr - base : addr - base + len(data)] = data
    return base, bytes(out)


def raw_signature(priv_int, message):
    """64 bytes of r||s, which is what `p256::ecdsa` expects. `cryptography`
    emits DER, and handing DER to a fixed-width verifier is a plumbing failure
    that looks exactly like a cryptographic one."""
    key = ec.derive_private_key(priv_int, ec.SECP256R1())
    r, s = decode_dss_signature(key.sign(message, ec.ECDSA(hashes.SHA256())))
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def cobs_encode(payload):
    """`crates/framing`'s wire format, written again here rather than shared,
    so a bug in one does not hide in the other."""
    out = bytearray([0])
    code_at, code = 0, 1
    for b in payload:
        if b == 0:
            out[code_at] = code
            code_at = len(out)
            out.append(0)
            code = 1
        else:
            out.append(b)
            code += 1
            if code == 0xFF:
                out[code_at] = code
                code_at = len(out)
                out.append(0)
                code = 1
    out[code_at] = code
    out.append(0)
    return bytes(out)


def escape(data):
    return "".join(f"\\x{b:02x}" for b in data)


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    path, mode = sys.argv[1], sys.argv[2]
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 0

    _, image = uf2_image(path)
    rng = random.Random(seed)

    if mode == "unreadable":
        # Slot B where it really is. The board cannot reach it, and the point of
        # this request is that it says so instead of dying.
        virt, length = B_PHYS, 0x1000
        signed = image[B_PHYS : B_PHYS + length]
    else:
        # Somewhere inside slot A's 64 KiB aperture, chosen from this run's
        # seed — bytes nobody picked when the firmware was built.
        length = rng.randrange(0x1000, 0x8000) & ~0xFFF
        virt = rng.randrange(0, 0x10000 - length) & ~0xFFF
        signed = image[A_PHYS + virt : A_PHYS + virt + length]

    priv = OTHER_PRIV if mode == "wrong-key" else TRUSTED_PRIV
    sig = bytearray(raw_signature(priv, signed))
    if mode == "flip-sig":
        sig[0] ^= 0x01

    frame = bytearray([CMD_VERIFY])
    frame += virt.to_bytes(4, "little")
    frame += length.to_bytes(4, "little")
    frame += sig
    assert len(frame) == FRAME_LEN, len(frame)
    if mode == "truncated":
        frame = frame[: FRAME_LEN - 20]

    d = hashes.Hash(hashes.SHA256())
    d.update(signed)

    print(
        json.dumps(
            {
                "mode": mode,
                "seed": seed,
                "virtual_offset": virt,
                "length": length,
                "physical": (B_PHYS if mode == "unreadable" else A_PHYS + virt),
                "expect": "ACCEPTED" if mode == "good" else "REFUSED",
                "starts_trial": mode == "good",
                "sha256": d.finalize().hex(),
                "escaped": escape(b"\x00" + cobs_encode(bytes(frame))),
            }
        )
    )


if __name__ == "__main__":
    main()
