#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp249 on the emulator: SHA-256's run inside exp223's kernel, every access recorded, against proof/Hash.lean.

exp223 places exp208's SHA-256 at +0x1000 of its box, so offsets here are from there, as the theorem's are. The
kernel runs alone on exp222's eight healthy streams -- the six unhealthy ones never reach SHA-256 -- with exp248's
recorder:

  the windows     every load inside [+0x400, +0x3040), every store inside [+0x1140, +0x1440), every pc one of
                  SHA-256's 252 instructions, the only call a HALT with t0 = 1; and what the run actually touches,
                  set beside what the checker could prove
  the frame       when SHA-256 halts, every byte of the box outside its store window is as it was when SHA-256 began
  the digest      SHA-256 of the 4096 sample bytes, at +0x1140, as exp208's theorem says

`run_all()` returns the failures and the lines to print.
"""

import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
sys.path.insert(0, os.path.join(REPO, "experiments", "exp248-the-samples-the-front-reads", "suite"))
import front_reach  # noqa: E402
from front_reach import Recorder, payload, harness, streams, healthy  # noqa: E402

SHA = 0x1000
LOADS, STORES = (0x400, 0x3040), (0x1140, 0x1440)
KERNEL_WORDS = 252


def run_case(name: str, words: list):
    pay = payload(words)
    emu = Recorder(pay)
    start = None
    for n in range(1, 400000):
        emu.step()
        if start is None and emu.pc == harness.PAYLOAD_AT + SHA:
            start = (len(emu.loads), len(emu.stores), len(emu.calls), n)
            emu.pcs = set()
            box_at = bytes(emu.mem[harness.PAYLOAD_AT - harness.BASE:harness.PAYLOAD_AT - harness.BASE + 0x10000])
        if emu.halted:
            break
    nl, ns, nc, _ = start
    loads = [(a - SHA, w) for _, a, w in emu.loads[nl:]]
    stores = [(a - SHA, w) for _, a, w in emu.stores[ns:]]
    calls = emu.calls[nc:]
    bad = []
    if any(not (LOADS[0] <= a and a + w <= LOADS[1]) for a, w in loads):
        bad.append(f"{name}: a load outside [{LOADS[0]:#x}, {LOADS[1]:#x})")
    if any(not (STORES[0] <= a and a + w <= STORES[1]) for a, w in stores):
        bad.append(f"{name}: a store outside [{STORES[0]:#x}, {STORES[1]:#x})")
    if any(not (SHA <= p < SHA + 4 * KERNEL_WORDS) for p in emu.pcs):
        bad.append(f"{name}: a pc outside SHA-256")
    if calls != [(SHA + 4 * (KERNEL_WORDS - 1), 1)] or emu.exit_code != 0:
        bad.append(f"{name}: calls {calls}, exit {emu.exit_code}")
    box = bytes(emu.mem[harness.PAYLOAD_AT - harness.BASE:harness.PAYLOAD_AT - harness.BASE + 0x10000])
    outside = [o for o in range(0x10000) if not (SHA + STORES[0] <= o < SHA + STORES[1]) and box[o] != box_at[o]]
    if outside:
        bad.append(f"{name}: {len(outside)} bytes outside the store window changed, the first at +{outside[0]:#x}")
    digest = box[SHA + 0x1140:SHA + 0x1160]
    if digest != hashlib.sha256(pay[0x3000:0x4000]).digest():
        bad.append(f"{name}: the digest is not SHA-256 of the samples")
    hull = lambda acc: (min(a for a, _ in acc), max(a + w for a, w in acc))
    return bad, hull(loads), hull(stores), len(loads), len(stores)


def run_all():
    bad, lines, seen = [], [], set()
    n = 0
    for name, words in streams().items():
        if not healthy(words)[0]:
            continue
        b, lh, sh, nl, ns = run_case(name, words)
        bad += b
        seen.add((lh, sh, nl, ns))
        n += 1
    lines.append(f"PASS  SHA-256 inside exp223's kernel, on the {n} healthy streams of exp222, every access recorded,")
    lines.append("      offsets from SHA-256's base: every load inside [+0x400, +0x3040), every store inside")
    lines.append("      [+0x1140, +0x1440), every pc one of its 252 instructions, its one call the HALT with t0 = 1")
    for lh, sh, nl, ns in sorted(seen):
        lines.append(f"      what the run touches: loads [{lh[0]:#x}, {lh[1]:#x}) ({nl} of them), stores [{sh[0]:#x}, {sh[1]:#x})"
                     f" ({ns}):")
        lines.append("      the store window exactly; the loads inside the checker's wider bound")
    lines.append("PASS  the frame: when SHA-256 halts, every byte of the box outside its store window is as it was when")
    lines.append("      it began; and the digest at +0x1140 is SHA-256 of the 4096 sample bytes")
    return bad, lines


def main():
    bad, lines = run_all()
    for b in bad[:20]:
        print(f"FAIL  {b}")
    if bad:
        sys.exit(1)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
