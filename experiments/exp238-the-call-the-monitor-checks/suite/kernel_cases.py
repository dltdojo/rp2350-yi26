#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp228's 34 scripts, run by its proved kernel under exp238's monitor.

For each case the kernel runs three times over:

  1. alone: no monitor, M-mode, `ecall` answered in place (host.reference_run);
  2. under the monitor, where each HASHB and CHECKSIG is a trap, a bounds check, a forward and an `mret`;
  3. in the specification: script.py's verdict, with BIP340 for the signature check.

and what must agree is:

  - the exit code: the specification's, in both runs;
  - the whole 64 KiB box afterwards, byte for byte;
  - minstret, which the monitor must make a constant: the run alone, plus 2 for the monitor's
    framing and 2 for each call (the `csrwi` that releases the counters, the `mret`);
  - the host's requests: the same calls in the same order with the same arguments, each of them
    wholly inside the box;
  - the monitor's own end state: parked, scrubbed, its words and its stack as they should be.

The run alone is also held to the RTL, from exp228's committed round-4 capture of a Pico 2: that board
counted the model's instructions + 4 for its harness + 4 for each call.
"""

import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import host
from script import script_verdict

SPEC = host.script_cases


def board_counts() -> dict:
    """name -> minstret, from the CASE lines of exp228's round-4 capture (a Pico 2, a Pixel 9a)."""
    out = {}
    with open(os.path.join(host.EXP228, "board", "round4-page.txt"), encoding="utf-8") as f:
        for line in f:
            if line.startswith("CASE "):
                w = line.rstrip("\n").split(" ", 8)
                out[w[8]] = int(w[5], 16)
    return out


def payload(script: bytes, stack: list) -> bytes:
    return host.pack(b"", host.BOX_LO, SPEC.region_image(host.kernel(), script, stack))


def run_case(monitor: bytes, name: str, script: bytes, stack: list, board: dict):
    """The failures of one case, and (monitor minstret, calls) for the report."""
    pay = payload(script, stack)
    want = script_verdict(script, stack, sig=SPEC.valid, h=lambda b: hashlib.sha256(b).digest())
    alone = host.reference_run(pay)
    under = host.run(monitor, pay)

    bad = host.check_parked(under, monitor, want)
    if host.TAG_HALT not in under.prints:
        bad.append("no HALT report")
    if alone.exit_code != want:
        bad.append(f"alone: exit {alone.exit_code}, specification {want}")
    if host.box(alone) != host.box(under):
        bad.append("the box differs from the run alone")
    ncalls = len(alone.host.requests)
    reported = under.prints[-2] if len(under.prints) >= 2 else None       # HALT, a0, minstret, mcycle
    if reported != alone.minstret + 2 + 2 * ncalls:
        bad.append(f"minstret {reported}, wanted {alone.minstret} + 2 + 2*{ncalls}")
    if under.host.requests != alone.host.requests:
        bad.append("the host was asked something other than what the run alone asked")
    for r in under.host.requests:
        if not host.boxed(r):
            bad.append(f"the host was asked outside the box: {r}")
    if under.host.valid != alone.host.valid:
        bad.append("the signature checks answered differently")
    if board.get(name) is not None and board[name] != alone.minstret + 4 + 4 * ncalls:
        bad.append(f"the Pico 2 counted {board[name]}, this run alone {alone.minstret} + 4 + 4*{ncalls}")
    return bad, reported, ncalls


FUZZ = 120      # scripts drawn by exp228's cases.fuzz, on top of the 34 by hand


def run_all(monitor: bytes, fuzz: int = FUZZ) -> list:
    board = board_counts()
    failed = []
    for name, (script, stack, _) in SPEC.hand().items():
        bad, _m, _n = run_case(monitor, name, script, stack, board)
        if bad:
            failed.append((name, bad))
    for i, (script, stack) in enumerate(SPEC.fuzz(fuzz)):
        bad, _m, _n = run_case(monitor, f"fuzz {i}", script, stack, board)
        if bad:
            failed.append((f"fuzz {i}", bad))
    return failed


def main():
    with open(os.path.join(host.EXP238, "monitor.bin"), "rb") as f:
        monitor = f.read()
    board = board_counts()
    failed, rows = [], []
    for name, (script, stack, _) in SPEC.hand().items():
        bad, m, n = run_case(monitor, name, script, stack, board)
        rows.append((name, m, n))
        if bad:
            failed.append((name, bad))
    for name, bad in failed:
        print(f"FAIL  {name}: {'; '.join(bad)}")
    if failed:
        sys.exit(1)
    total = sum(n for _, _, n in rows)
    print(f"PASS  {len(rows)} scripts run by exp228's kernel under the monitor: verdict, box and request log as run alone, "
          f"minstret = alone + 2 + 2*calls, {total} calls served, each wholly inside the box")
    print(f"PASS  the run alone counted what the Pico 2 counted ({len(board)} cases, + 4 + 4*calls)")
    fz_calls = 0
    for i, (script, stack) in enumerate(SPEC.fuzz(FUZZ)):
        bad, _m, n = run_case(monitor, f"fuzz {i}", script, stack, board)
        fz_calls += n
        if bad:
            print(f"FAIL  fuzz {i}: {'; '.join(bad)}")
            sys.exit(1)
    print(f"PASS  {FUZZ} fuzzed scripts, the same: {fz_calls} calls served")
    print("      case                          minstret  calls")
    for name, m, n in rows:
        print(f"      {name:28} {m:9} {n:6}")


if __name__ == "__main__":
    main()
