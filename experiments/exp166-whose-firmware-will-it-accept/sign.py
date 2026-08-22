#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build one signed (or deliberately broken) request for exp166's board.

    python3 sign.py <image.uf2> <mode> [seed]

Modes, and what each one is for:

    good           a correct signature by the trusted key, over a region
                   chosen at random from this run's seed
    flip-sig       the same request with one bit of the signature flipped
    wrong-key      the same region, signed by a second test key the board
                   has never heard of
    wrong-region   a *valid* signature by the trusted key, over a different
                   region than the one the frame names.  This is the case a
                   verifier that checks "is this a signature by the key"
                   rather than "is this a signature over these bytes" gets
                   wrong, and nothing else here catches it.
    truncated      the frame cut short, to see whether the board refuses it
                   or reads past the end of it

Prints a JSON object on stdout: the escape string for `yi26 send`, and the
digest this script computed, so the caller can compare it with the digest the
board prints.  **That comparison is the point** — a verifier that only reports
pass/fail can be trusted but not checked.

The private keys below are test keys and are published on purpose.  Nothing
signed by them means anything, and the README says so where somebody deciding
whether to trust this board can see it.
"""

import json
import random
import sys

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

# The key the firmware carries.  Published: this is a test key.
TRUSTED_PRIV = 0xA7C08E6335CC688CED091DA7F381971AEE587D3783F9924233D85E488A034FE0
# A second key, to stand for anybody else.  Also published, also worthless.
OTHER_PRIV = 0xA03A8C8CD7659136F840EA68AE7005C25C5A84D3A236EFD557ECF4EB6086F174

CMD_VERIFY = 1
FRAME_LEN = 73
UF2_MAGIC0 = 0x0A324655
UF2_MAGIC1 = 0x9E5D5157


def uf2_image(path):
    """The flat bytes a UF2 puts in flash, and the address it puts them at.

    Only the contiguous run starting at the lowest address is returned.  A gap
    would mean a region descriptor could name flash this file says nothing
    about, and signing bytes nobody can predict is not a test of anything.
    """
    blocks = []
    with open(path, "rb") as f:
        raw = f.read()
    for i in range(0, len(raw), 512):
        b = raw[i : i + 512]
        if len(b) < 512:
            break
        m0 = int.from_bytes(b[0:4], "little")
        m1 = int.from_bytes(b[4:8], "little")
        if m0 != UF2_MAGIC0 or m1 != UF2_MAGIC1:
            continue
        addr = int.from_bytes(b[12:16], "little")
        size = int.from_bytes(b[16:20], "little")
        blocks.append((addr, b[32 : 32 + size]))
    if not blocks:
        raise SystemExit(f"{path}: no UF2 blocks")
    blocks.sort()
    base = blocks[0][0]
    out = bytearray()
    want = base
    for addr, data in blocks:
        if addr != want:
            break  # stop at the first gap rather than pretending it is filled
        out += data
        want += len(data)
    return base, bytes(out)


def raw_signature(priv_int, message):
    """A 64-byte r||s signature, which is what `p256::ecdsa` expects.

    `cryptography` emits DER, and handing DER to a verifier that wants fixed
    width is a plumbing failure that looks exactly like a cryptographic one.
    """
    key = ec.derive_private_key(priv_int, ec.SECP256R1())
    der = key.sign(message, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def cobs_encode(payload):
    """Standard COBS with a trailing zero delimiter — `crates/framing`'s wire
    format, written again here rather than shared, so a bug in one does not
    hide in the other."""
    out = bytearray()
    code_at = 0
    out.append(0)
    code = 1
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

    base, image = uf2_image(path)
    rng = random.Random(seed)

    # The region is chosen here, now, from a seed the firmware has never seen.
    # exp159's bar for a signer was a challenge it could not have known at
    # build time; this is the same bar pointed the other way.
    if len(image) < 4096:
        raise SystemExit(f"{path}: image is only {len(image)} bytes")
    length = rng.randrange(1024, min(len(image), 32768))
    offset = rng.randrange(0, len(image) - length)

    named_offset, named_len = offset, length
    signed = image[offset : offset + length]

    if mode == "wrong-region":
        # Sign one region, name another.  Both are real, both are inside the
        # image, and only a verifier that binds the signature to the bytes it
        # names will notice.
        other_len = rng.randrange(1024, min(len(image), 32768))
        other_off = rng.randrange(0, len(image) - other_len)
        while other_off == offset and other_len == length:
            other_off = rng.randrange(0, len(image) - other_len)
        named_offset, named_len = other_off, other_len

    priv = OTHER_PRIV if mode == "wrong-key" else TRUSTED_PRIV
    sig = bytearray(raw_signature(priv, signed))
    if mode == "flip-sig":
        sig[0] ^= 0x01

    frame = bytearray()
    frame.append(CMD_VERIFY)
    frame += named_offset.to_bytes(4, "little")
    frame += named_len.to_bytes(4, "little")
    frame += sig
    assert len(frame) == FRAME_LEN, len(frame)

    if mode == "truncated":
        frame = frame[: FRAME_LEN - 20]

    digest = hashes.Hash(hashes.SHA256())
    digest.update(image[named_offset : named_offset + named_len])
    named_digest = digest.finalize().hex()

    # A leading delimiter, because the board's decoder is `joined`: it will not
    # emit anything assembled before the first one.  One byte, and it is the
    # difference between a first frame that arrives and one that does not.
    wire = b"\x00" + cobs_encode(bytes(frame))

    print(
        json.dumps(
            {
                "mode": mode,
                "seed": seed,
                "base": base,
                "image_len": len(image),
                "named_offset": named_offset,
                "named_len": named_len,
                "signed_offset": offset,
                "signed_len": length,
                "expect": "REFUSED" if mode != "good" else "ACCEPTED",
                "named_sha256": named_digest,
                "wire_len": len(wire),
                "escaped": escape(wire),
            }
        )
    )


if __name__ == "__main__":
    main()
