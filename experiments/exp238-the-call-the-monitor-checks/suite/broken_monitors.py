#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Monitors with one thing wrong in them, each of which the suites must catch.

The attack and kernel suites passing on `monitor.bin` says little if they would also pass on a
monitor that did not do its job. Each variant below is `monitor.S` with one change — a bounds check
left out, a length checked by adding instead of subtracting, a register the return forgets to
restore, a counter released too late — assembled afresh and run through both suites. A variant
that gets through all of them is a hole in the tests, and this exits 1.
"""

import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import host
import attack_cases
import kernel_cases
from host import REPO, EXP238

import asm      # tools/monitor, on the path through host


def sub(src: str, old: str, new: str, which: str = "first") -> str:
    assert old in src, f"{old!r} is not in monitor.S"
    if which == "all":
        return src.replace(old, new)
    i = src.index(old) if which == "first" else src.rindex(old)
    return src[:i] + new + src[i + len(old):]


HASHB_LEN = "    sub   t3, t2, a0\n    bltu  t3, a1, handle_fault\n"
CHK_A0 = "    bltu  a0, t1, handle_fault\n"
CHK_A0_HI = "    bltu  t2, a0, handle_fault\n"

# label, what is wrong, the edit to monitor.S
VARIANTS = [
    ("hashb_input_floor_dropped", "HASHB lets an input start below the box",
     lambda s: sub(s, CHK_A0, "")),
    ("hashb_input_ceiling_dropped", "HASHB lets an input start past the box",
     lambda s: sub(s, CHK_A0_HI, "")),
    ("hashb_length_dropped", "HASHB never checks the length against what is left of the box",
     lambda s: sub(s, HASHB_LEN, "")),
    ("hashb_length_by_addition", "HASHB checks ptr + len <= BOX_HI, and the sum wraps",
     lambda s: sub(s, HASHB_LEN, "    add   t3, a0, a1\n    bltu  t2, t3, handle_fault\n")),
    ("hashb_output_floor_dropped", "HASHB lets the output start below the box",
     lambda s: sub(s, "    bltu  a2, t1, handle_fault\n", "")),
    ("hashb_output_ceiling_dropped", "HASHB lets the output start past the box",
     lambda s: sub(s, "    bltu  t2, a2, handle_fault\n", "")),
    ("hashb_output_room_dropped", "HASHB lets the 32-byte output run off the end of the box",
     lambda s: sub(s, "    sub   t3, t2, a2\n    li    t0, 32\n    bltu  t3, t0, handle_fault\n", "")),
    ("hashb_output_16_bytes", "HASHB checks room for 16 bytes of output, not 32",
     lambda s: sub(s, "    sub   t3, t2, a2\n    li    t0, 32\n", "    sub   t3, t2, a2\n    li    t0, 16\n")),
    ("checksig_key_floor_dropped", "CHECKSIG lets the key start below the box",
     lambda s: sub(s, CHK_A0, "", "last")),
    ("checksig_key_room_dropped", "CHECKSIG lets the 32-byte key run off the end of the box",
     lambda s: sub(s, "    sub   t3, t2, a0\n    li    t0, 32\n    bltu  t3, t0, handle_fault\n", "", "last")),
    ("checksig_signature_floor_dropped", "CHECKSIG lets the signature start below the box",
     lambda s: sub(s, "    bltu  a1, t1, handle_fault\n", "", "last")),
    ("checksig_signature_32_bytes", "CHECKSIG checks room for 32 bytes of signature, not 64",
     lambda s: sub(s, "    li    t0, 64\n", "    li    t0, 32\n")),
    ("checksig_is_hashb", "call 3 is taken for call 2",
     lambda s: sub(s, "    li    t1, 3\n    beq   t0, t1, call_checksig", "    li    t1, 2\n    beq   t0, t1, call_checksig")),
    ("answer_check_dropped", "CHECKSIG returns whatever the host answered, 0 and 1 or not",
     lambda s: sub(s, "    bltu  t1, a0, handle_fault      // anything else is no answer: refused\n", "")),
    ("answer_check_allows_two", "CHECKSIG takes an answer of 2 too",
     lambda s: sub(s, "    li    t1, 1\n    bltu  t1, a0", "    li    t1, 2\n    bltu  t1, a0")),
    ("unknown_call_succeeds", "a call the monitor does not offer returns to the payload",
     lambda s: sub(s, "    beq   t0, t1, call_checksig\n    j     handle_fault", "    beq   t0, t1, call_checksig\n    j     trap_return")),
    ("return_repeats_the_ecall", "the return does not step past the ecall",
     lambda s: sub(s, "    addi  t0, t0, 4\n", "    addi  t0, t0, 0\n")),
    ("return_skips_two_words", "the return steps over the word after the ecall too",
     lambda s: sub(s, "    addi  t0, t0, 4\n", "    addi  t0, t0, 8\n")),
    ("return_leaves_t1", "the return does not put the payload's t1 back",
     lambda s: sub(s, "    lw    t1, 4(sp)\n", "", "last")),
    ("return_leaves_t3", "the return does not put the payload's t3 back",
     lambda s: sub(s, "    lw    t3, 12(sp)\n", "", "last")),
    ("return_keeps_monitor_sp", "the return leaves the monitor's sp in the payload",
     lambda s: sub(s, "    csrrw sp, mscratch, sp\n    // Release", "    // Release")),
    ("counters_not_released", "the return never releases the counters",
     lambda s: sub(s, "    csrwi mcountinhibit, 0\n    mret\n\nhandle_halt", "    mret\n\nhandle_halt")),
    ("counters_released_early", "the return releases the counters two instructions sooner",
     lambda s: sub(sub(s, "    csrwi mcountinhibit, 0\n    mret\n\nhandle_halt", "    mret\n\nhandle_halt"),
                   "    csrr  t0, mepc\n    addi  t0, t0, 4\n", "    csrwi mcountinhibit, 0\n    csrr  t0, mepc\n    addi  t0, t0, 4\n")),
    ("extra_instruction_counted", "the return spends one more counted instruction",
     lambda s: sub(s, "    csrwi mcountinhibit, 0\n    mret\n\nhandle_halt", "    csrwi mcountinhibit, 0\n    nop\n    mret\n\nhandle_halt")),
    ("scrub_keeps_saved_t2", "the scrub leaves the saved t2 on the M-mode stack",
     lambda s: sub(s, "    sw    zero, 8(sp)\n", "")),
    ("scrub_keeps_saved_t3", "the scrub leaves the saved t3 on the M-mode stack",
     lambda s: sub(s, "    sw    zero, 12(sp)\n", "")),
    ("fault_does_not_scrub", "a fault parks without scrubbing",
     lambda s: sub(s, "    li    a0, 1\n    j     scrub_exit", "    li    a0, 1\n    j     halt_loop")),
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
    with open(os.path.join(EXP238, "monitor.S")) as f:
        src = f.read()
    good = build(src)
    with open(os.path.join(EXP238, "monitor.bin"), "rb") as f:
        assert good == f.read(), "monitor.S does not assemble to monitor.bin"
    host.MAX_STEPS = 12000      # the slowest honest case is a few thousand instructions; a loop need not run on
    miss = []
    for label, what, edit in VARIANTS:
        mon = build(edit(src))
        failures = attack_cases.run_all(mon) + kernel_cases.run_all(mon, fuzz=0)
        if not failures:
            miss.append((label, what))
    for label, what in miss:
        print(f"FAIL  {label}: {what} — and every attack and kernel case still passed")
    if miss:
        sys.exit(1)
    print(f"PASS  {len(VARIANTS)} broken monitors, each caught by the attack and kernel suites:")
    for label, what, _ in VARIANTS:
        print(f"      {label:34} {what}")


if __name__ == "__main__":
    main()
