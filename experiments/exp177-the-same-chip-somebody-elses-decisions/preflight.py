#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Reads a third-party UF2 before any board is asked to accept it.

This repository has dropped a lot of UF2 files onto a Pico 2, and every one of
them it built itself. This is the first that somebody else built, and the
difference is that nothing about where it intends to land is known in advance.
A UF2 block says which family it belongs to and which address it wants; both
are readable without a board, and reading them costs nothing next to finding
out by watching a board go dark.

What it looks for, in the order that matters:

1. **Blocks that want an address this part does not have.** A Pico 2 has 4 MiB
   of flash at `0x10000000`. A block asking for more is a block whose landing
   place is the bootrom's decision and not the image's.
2. **The families present.** `0xe48bff59` is RP2350 Arm Secure — an image for
   this chip. `0xe48bff57` is `absolute`, which means the address is taken
   literally rather than as an offset into the image.
3. **A boot block at flash offset 0**, which is what `yi26 pflash` refuses an
   image for lacking.
4. **How big it is**, against exp142's sixteen-sector A/B slots.
"""

import json
import os
import struct
import sys

UF2_MAGIC_0, UF2_MAGIC_1, UF2_MAGIC_END = 0x0A324655, 0x9E5D5157, 0x0AB16F30

FAMILIES = {
    0xE48BFF56: "RP2040",
    0xE48BFF57: "absolute",
    0xE48BFF58: "data",
    0xE48BFF59: "RP2350 Arm Secure",
    0xE48BFF5A: "RP2350 RISC-V",
    0xE48BFF5B: "RP2350 Arm Non-secure",
}

XIP_BASE = 0x10000000
PICO2_FLASH = 4 * 1024 * 1024          # what an official Pico 2 actually has
SLOT_BYTES = 16 * 4096                 # exp142's A/B slot, sixteen sectors


def main(path):
    raw = open(path, "rb").read()
    if len(raw) % 512:
        print(f"FAIL  {path} is not a whole number of 512-byte blocks")
        return 1

    blocks, families = [], {}
    for i in range(len(raw) // 512):
        b = raw[i * 512:(i + 1) * 512]
        m0, m1, flags, addr, size, no, total, family = struct.unpack("<8I", b[:32])
        if (m0, m1) != (UF2_MAGIC_0, UF2_MAGIC_1):
            print(f"FAIL  block {i} does not carry the UF2 magic")
            return 1
        if struct.unpack("<I", b[-4:])[0] != UF2_MAGIC_END:
            print(f"FAIL  block {i} does not carry the trailing magic")
            return 1
        blocks.append((addr, size, flags, family, b[32:32 + size]))
        families.setdefault(family, []).append((addr, size))

    report = {"file": os.path.basename(path), "blocks": len(blocks), "families": []}
    print(f"{os.path.basename(path)}: {len(blocks)} blocks")
    for family, items in sorted(families.items()):
        lo = min(a for a, _ in items)
        hi = max(a + s for a, s in items)
        payload = sum(s for _, s in items)
        name = FAMILIES.get(family, "unknown")
        print(f"  family 0x{family:08x}  {name:<22} {len(items):>5} blocks  "
              f"0x{lo:08x}..0x{hi:08x}  {payload} bytes")
        report["families"].append({"id": f"0x{family:08x}", "name": name,
                                   "blocks": len(items), "first": f"0x{lo:08x}",
                                   "last": f"0x{hi:08x}", "payload_bytes": payload})

    # 1. Anything beyond the flash this part has.
    beyond = [(a, s, f) for a, s, f, fam, _ in
              ((a, s, fl, fam, p) for a, s, fl, fam, p in blocks)
              if a >= XIP_BASE + PICO2_FLASH]
    report["beyond_flash"] = [{"addr": f"0x{a:08x}", "bytes": s} for a, s, _ in beyond]
    if beyond:
        print(f"\n  NOTE  {len(beyond)} block(s) ask for an address a 4 MiB Pico 2 does "
              f"not have:")
        for a, s, _ in beyond:
            over = (a - XIP_BASE) // (1024 * 1024)
            print(f"          0x{a:08x}  {s} bytes  — {over} MiB into a 4 MiB part")
        print("        What the bootrom does with those is its decision, not this "
              "image's,\n        and this experiment reports it rather than predicting it.")

    # 2. The image proper: what lands inside real flash.
    inside = [(a, s) for a, s, _, _, _ in blocks if a < XIP_BASE + PICO2_FLASH]
    lo = min(a for a, _ in inside)
    hi = max(a + s for a, s in inside)
    footprint = sum(s for _, s in inside)
    report["image"] = {"first": f"0x{lo:08x}", "last": f"0x{hi:08x}",
                       "payload_bytes": footprint,
                       "slots_of_exp142": round(footprint / SLOT_BYTES, 1)}
    print(f"\n  the image proper: 0x{lo:08x}..0x{hi:08x}, {footprint} bytes "
          f"({footprint / 1024:.1f} KiB)")
    print(f"  that is {footprint / SLOT_BYTES:.1f}× exp142's 64 KiB A/B slot")

    # 3. The boot block, which is what makes it bootable at all.
    at_zero = [p for a, s, _, _, p in blocks if a == XIP_BASE]
    report["has_boot_block_at_offset_0"] = bool(at_zero)
    print(f"  boot block at flash offset 0: {'yes' if at_zero else 'NO'}")

    json.dump(report, open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "preflight.json"), "w"), indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
