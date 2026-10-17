#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Monitors with one thing wrong in them, each of which the suites must catch.

Each variant is `monitor.S` with one change -- a code entry that can be written, a data entry that can be run, a stack
entry that reaches too far, two entries in the wrong order, a register the scrub forgets -- assembled afresh, and run
through the hostile payloads and through three rounds of exp225's kernel. A variant that gets through both is a hole in
the tests, and this exits 1.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import oracle
import harness
import rounds
import wx_attacks
from harness import sub

CODE_A, DATA_A, STACK_A, CFG = "0x2000400f", "0x200041ff", "0x20007dff", "0x001b1b1d"
LI = "li    t0, "

def swapped(s: str) -> str:
    """monitor.S with the addresses of the code entry and the data entry exchanged."""
    return sub(sub(sub(s, LI + CODE_A, LI + "TMP"), LI + DATA_A, LI + CODE_A), LI + "TMP", LI + DATA_A)


# label, what is wrong, the edit to monitor.S
VARIANTS = [
    ("code_entry_writable", "the code entry is read, write and execute",
     lambda s: sub(s, LI + CFG, LI + "0x001b1b1f")),
    ("data_entry_executable", "the data entry is read, write and execute",
     lambda s: sub(s, LI + CFG, LI + "0x001b1f1d")),
    ("stack_entry_executable", "the stack entry is read, write and execute",
     lambda s: sub(s, LI + CFG, LI + "0x001f1b1d")),
    ("code_entry_off", "the code entry is off",
     lambda s: sub(s, LI + CFG, LI + "0x001b1b00")),
    ("data_entry_off", "the data entry is off",
     lambda s: sub(s, LI + CFG, LI + "0x001b001d")),
    ("stack_entry_off", "the stack entry is off",
     lambda s: sub(s, LI + CFG, LI + "0x00001b1d")),
    ("code_entry_256_bytes", "the code entry is 256 bytes: the data from +0x80 can be run",
     lambda s: sub(s, LI + CODE_A, LI + "0x2000401f")),
    ("code_entry_64_bytes", "the code entry is 64 bytes: the end of the kernel cannot be fetched",
     lambda s: sub(s, LI + CODE_A, LI + "0x20004007")),
    ("data_entry_8_kib", "the data entry is 8 KiB: it reaches 4 KiB into the guard",
     lambda s: sub(s, LI + DATA_A, LI + "0x200043ff")),
    ("data_entry_2_kib", "the data entry is 2 KiB: the top half of the data is not there",
     lambda s: sub(s, LI + DATA_A, LI + "0x200040ff")),
    ("stack_entry_8_kib", "the stack entry is 8 KiB: the guard is 4 KiB short",
     lambda s: sub(s, LI + STACK_A, LI + "0x20007bff")),
    ("stack_entry_32_kib", "the stack entry is 32 KiB: the guard is 28 KiB short",
     lambda s: sub(s, LI + STACK_A, LI + "0x20006fff")),
    ("stack_entry_to_the_monitor", "the stack entry is 256 KiB from the monitor's base",
     lambda s: sub(s, LI + STACK_A, LI + "0x20007fff")),
    ("code_and_data_swapped", "the code entry has the data's address and the data entry the code's",
     lambda s: swapped(s)),
    ("data_tried_before_code", "the data entry is tried first, so it decides a store into the code",
     lambda s: sub(swapped(s), LI + CFG, LI + "0x001b1d1b")),
    ("mret_stays_in_m_mode", "mret returns to M-mode",
     lambda s: sub(s, "csrc  mstatus, t0", "csrs  mstatus, t0")),
    ("boot_leaves_a_register", "boot does not zero x31 before the payload",
     lambda s: sub(s, "li    x31, 0", "", "first")),
    ("payload_sp_wrong", "the payload's sp is the bottom of the stack entry, not the top",
     lambda s: sub(s, "li    sp, 0x80020000", "li    sp, 0x8001f000")),
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


def caught(mon: bytes) -> bool:
    return bool(rounds.run_all(mon, 3)[0] or wx_attacks.run_all(mon, first=True))


def main():
    with open(os.path.join(oracle.EXP240, "monitor.S")) as f:
        src = f.read()
    assert harness.build(src) == oracle.monitor(), "monitor.S does not assemble to monitor.bin"
    miss = [(label, what) for label, what, edit in VARIANTS if not caught(harness.build(edit(src)))]
    for label, what in miss:
        print(f"FAIL  {label}: {what} — and every hostile payload and the rounds still passed")
    if miss:
        sys.exit(1)
    print(f"PASS  {len(VARIANTS)} broken monitors, each caught by the hostile payloads or the rounds of Rule 30:")
    for label, what, _ in VARIANTS:
        print(f"      {label:28} {what}")


if __name__ == "__main__":
    main()
