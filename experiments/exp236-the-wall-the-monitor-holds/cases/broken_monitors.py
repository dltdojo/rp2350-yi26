#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Monitors with one thing wrong in them, each of which the suites must catch.

The attack and normal suites passing on `monitor.bin` says little if they would also pass on
a monitor that did not do its job. Each variant below is `monitor.S` with one change — a PMP
window that is too wide, a payload that can write the monitor, a register the scrub forgets —
assembled afresh, and run through both suites. A variant that gets through all of them is a
hole in the tests, and this exits 1.
"""

import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
EXP236 = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(EXP236, "../.."))
sys.path.insert(0, os.path.join(REPO, "tools"))
sys.path.insert(0, os.path.join(REPO, "tools", "monitor"))
sys.path.insert(0, HERE)
import asm
import attack_cases
import normal_cases


def sub(src: str, old: str, new: str, which: str = "first") -> str:
    assert old in src, f"{old!r} is not in monitor.S"
    if which == "all":
        return src.replace(old, new)
    i = src.index(old) if which == "first" else src.rindex(old)
    return src[:i] + new + src[i + len(old):]


# label, what is wrong, the edit to monitor.S
VARIANTS = [
    ("pmp_window_4gib", "the PMP window is the whole address space",
     lambda s: sub(s, "li    t0, 0x20005fff", "li    t0, 0x3fffffff")),
    ("pmp_window_covers_monitor", "the PMP window is 128 KiB from the monitor's base",
     lambda s: sub(s, "li    t0, 0x20005fff", "li    t0, 0x2000ffff")),
    ("pmp_no_execute", "the payload region is read-write but not executable",
     lambda s: sub(s, "li    t0, 0x1f", "li    t0, 0x1b")),
    ("mret_stays_in_m_mode", "mret returns to M-mode",
     lambda s: sub(s, "csrc  mstatus, t0", "csrs  mstatus, t0")),
    ("boot_leaves_a_register", "boot does not zero x31 before the payload",
     lambda s: sub(s, "li    x31, 0", "", "first")),
    ("no_stack_swap", "the trap entry keeps the payload's sp",
     lambda s: sub(s, "csrrw sp, mscratch, sp", "")),
    ("scrub_skips_register", "the scrub forgets x17",
     lambda s: sub(s, "li    x17, 0", "", "last")),
    ("scrub_skips_ra", "the scrub forgets x1",
     lambda s: sub(s, "li    x1, 0", "", "last")),
    ("fault_does_not_scrub", "a fault parks without scrubbing",
     lambda s: sub(s, "j     scrub_exit", "j     halt_loop")),
    ("saved_words_stay", "the saved t0 and t1 stay on the stack",
     lambda s: sub(sub(s, "sw    zero, 0(sp)", ""), "sw    zero, 4(sp)", "")),
    ("mscratch_stays", "mscratch keeps the payload's sp",
     lambda s: sub(s, "csrw  mscratch, zero", "")),
    ("any_syscall_halts", "every ecall is taken for HALT",
     lambda s: sub(s, "bne   t0, t1, handle_fault", "")),
]


def build(src: str) -> bytes:
    with tempfile.TemporaryDirectory() as d:
        s, b = os.path.join(d, "m.S"), os.path.join(d, "m.bin")
        with open(s, "w") as f:
            f.write(src)
        asm.assemble(s, b, 0x80000000)
        with open(b, "rb") as f:
            return f.read()


def main():
    with open(os.path.join(EXP236, "monitor.S")) as f:
        src = f.read()
    good = build(src)
    with open(os.path.join(EXP236, "monitor.bin"), "rb") as f:
        assert good == f.read(), "monitor.S does not assemble to monitor.bin"
    miss = []
    for label, what, edit in VARIANTS:
        mon = build(edit(src))
        failures = attack_cases.run_all(mon) + normal_cases.run_all(mon)
        if not failures:
            miss.append((label, what))
    for label, what in miss:
        print(f"FAIL  {label}: {what} — and every attack and normal case still passed")
    if miss:
        sys.exit(1)
    print(f"PASS  {len(VARIANTS)} broken monitors, each caught by the attack and normal suites:")
    for label, what, _ in VARIANTS:
        print(f"      {label:26} {what}")


if __name__ == "__main__":
    main()
