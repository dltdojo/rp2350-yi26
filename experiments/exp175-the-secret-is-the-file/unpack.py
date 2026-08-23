#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Turn a .uf2 back into the flat flash image it describes, and find a secret in it.

    python3 unpack.py firmware.uf2 [needle]

A UF2 is not the image. It is 512-byte blocks, each carrying 256 bytes of
payload behind a 32-byte header, so a plain `grep` for a 32-byte secret finds
nothing even when the secret is right there — a block boundary can fall in the
middle of it. **That failure is a lesson, not a safeguard**: a student who
greps the file, sees nothing, and concludes the key is hidden has learned the
opposite of the truth. This reassembles the payload the way the bootrom does
and searches *that*.

With no needle it prints the image's extent. With one, it prints every flash
address the needle occurs at — which is how the device secret is located
before forge.py uses it.
"""
import struct
import sys

UF2_MAGIC0 = 0x0A324655
UF2_MAGIC1 = 0x9E5D5157
UF2_MAGIC_END = 0x0AB16F30


def load(path):
    """Return (base_address, bytes) for the flat image a .uf2 describes."""
    raw = open(path, "rb").read()
    if len(raw) % 512 != 0:
        raise SystemExit("%s is not a whole number of 512-byte UF2 blocks" % path)
    chunks = {}
    for off in range(0, len(raw), 512):
        b = raw[off:off + 512]
        m0, m1, flags, addr, plen, blk, nblk, fam = struct.unpack("<8I", b[:32])
        end = struct.unpack("<I", b[508:512])[0]
        if m0 != UF2_MAGIC0 or m1 != UF2_MAGIC1 or end != UF2_MAGIC_END:
            raise SystemExit("block at %#x is not a UF2 block" % off)
        if plen > 476:
            raise SystemExit("block at %#x claims %d payload bytes" % (off, plen))
        chunks[addr] = b[32:32 + plen]
    if not chunks:
        raise SystemExit("%s has no blocks" % path)
    base = min(chunks)
    img = bytearray()
    for a in sorted(chunks):
        gap = a - base - len(img)
        if gap > 0:
            img.extend(b"\xff" * gap)  # unwritten flash reads as 0xFF
        img.extend(chunks[a])
    return base, bytes(img)


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    base, img = load(sys.argv[1])
    print("image base %#x, %d bytes of payload reassembled from UF2 blocks"
          % (base, len(img)))
    if len(sys.argv) < 3:
        return
    needle = sys.argv[2].encode()
    hits = []
    i = img.find(needle)
    while i >= 0:
        hits.append(base + i)
        i = img.find(needle, i + 1)
    if not hits:
        # And say why this is not good news.
        raw = open(sys.argv[1], "rb").read()
        in_file = raw.find(needle) >= 0
        print("not found in the reassembled image")
        if not in_file:
            print("  (nor in the raw .uf2 — but a raw grep would miss a secret "
                  "split across a 256-byte block boundary; absence here is real, "
                  "absence from a grep is not)")
        return
    for a in hits:
        print("found %r at flash address %#x" % (sys.argv[2], a))


if __name__ == "__main__":
    main()
