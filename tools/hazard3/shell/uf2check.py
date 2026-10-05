#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""tools/hazard3/shell — a shell's UF2, read back independently of the tool
that wrote it.

  uf2check.py UF2 BIN START [FLASH]    PASS/FAIL lines; exit 0 = as claimed

START is _start's address from the ELF's symbol table; FLASH is how many bytes
from 0x10000000 the image may use, 4096 (flash sector 0) unless given. The
claims: every block is family `absolute` and lies in those bytes, together
they are exactly BIN,
the image starts with a jump to START, and the IMAGE_DEF block after it is the
eight words start_chip.S documents — with START as its entry point and the
region's base as its stack.
"""
import struct
import sys

ABSOLUTE, FLASH = 0xE48BFF57, 0x10000000
MSTACK = 0x20070000


def blocks(uf2):
    for o in range(0, len(uf2), 512):
        b = uf2[o:o + 512]
        m0, m1, flags, addr, size, no, total, family = struct.unpack_from("<8I", b)
        end = struct.unpack_from("<I", b, 508)[0]
        if (m0, m1, end) != (0x0A324655, 0x9E5D5157, 0x0AB16F30):
            raise ValueError(f"block {o // 512} is not a UF2 block")
        yield flags, addr, size, no, total, family, b[32:32 + size]


def main():
    uf2, image, start = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read(), int(sys.argv[3], 16)
    limit = int(sys.argv[4], 0) if len(sys.argv) > 4 else 4096
    where = "flash sector 0" if limit == 4096 else f"the first {limit // 1024} KiB of flash"
    bad = 0

    def check(ok, what):
        nonlocal bad
        print(("PASS  " if ok else "FAIL  ") + what)
        bad |= not ok

    bs = list(blocks(uf2))
    check(all(f == 0x2000 and fam == ABSOLUTE for f, _, _, _, _, fam, _ in bs),
          f"all {len(bs)} blocks carry family {ABSOLUTE:#010x}, absolute")
    check(all(FLASH <= a and a + s <= FLASH + limit for _, a, s, _, _, _, _ in bs),
          f"every block lies in {where}, {FLASH:#x}..{FLASH + limit:#x}")
    flat = bytearray()
    for _, a, s, no, total, _, data in bs:
        flat[a - FLASH:a - FLASH + s] = data
    check(bytes(flat[:len(image)]) == image and not any(flat[len(image):]),
          f"together they are exactly the {len(image)}-byte image")
    # j _start: a JAL x0 with the offset to START.
    off = start - FLASH
    jal = (((off >> 20) & 1) << 31) | (((off >> 1) & 0x3FF) << 21) | (((off >> 11) & 1) << 20) \
        | (((off >> 12) & 0xFF) << 12) | 0x6F
    words = struct.unpack_from("<9I", image, 0)
    check(words[0] == jal, f"the image starts with a jump to _start at {start:#010x}")
    want = (0xFFFFDED3, 0x11010142, 0x00000344, start, MSTACK, 0x000004FF, 0, 0xAB123579)
    check(words[1:] == want, "the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000")
    return bad


if __name__ == "__main__":
    sys.exit(main())
