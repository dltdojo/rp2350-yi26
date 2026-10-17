#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Monitors with one thing wrong in them, each of which the suites must catch.

Each variant is `monitor.S` with one change -- a loop a word short, a window a word long, the digest kept on a
failure, a fault that does not scrub memory -- assembled afresh and run through the hostile payloads and through
two of exp223's streams, one that passes and one that is withheld. A variant that gets through all of them is a
hole in the tests, and this exits 1.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import attack_cases
import kernel_cases
import oracle
import harness
from harness import sub

# label, what is wrong, the edit to monitor.S
CONF_SKIP = "    csrr  t0, mcause\n    li    t1, 8\n    bne   t0, t1, scrub_regs\n"
VARIANTS = [
    ("scratch_one_word_short", "the scratch loop stops at +0x3ffc",
     lambda s: sub(s, "    lui   t1, 0x80014\n", "    lui   t1, 0x80014\n    addi  t1, t1, -4\n")),
    ("scratch_one_word_long", "the scratch loop runs on to +0x4004",
     lambda s: sub(s, "    lui   t1, 0x80014\n", "    lui   t1, 0x80014\n    addi  t1, t1, 4\n")),
    ("scratch_starts_late", "the scratch loop starts at +0x2204",
     lambda s: sub(s, "addi  t0, t0, 0x200", "addi  t0, t0, 0x204")),
    ("scratch_starts_early", "the scratch loop starts at +0x21fc",
     lambda s: sub(s, "addi  t0, t0, 0x200", "addi  t0, t0, 0x1fc")),
    ("scratch_every_other_word", "the scratch loop steps eight bytes",
     lambda s: sub(s, "    addi  t0, t0, 4\n    bne   t0, t1, scrub_conf", "    addi  t0, t0, 8\n    bne   t0, t1, scrub_conf")),
    ("scratch_stores_the_address", "the scratch loop stores its pointer, not zero",
     lambda s: sub(s, "sw    zero, 0(t0)\n    addi  t0, t0, 4\n    bne   t0, t1, scrub_conf",
                   "sw    t0, 0(t0)\n    addi  t0, t0, 4\n    bne   t0, t1, scrub_conf")),
    ("scratch_not_scrubbed", "there is no scratch loop",
     lambda s: sub(s, "scrub_conf:\n    sw    zero, 0(t0)\n    addi  t0, t0, 4\n    bne   t0, t1, scrub_conf\n", "")),
    ("fault_skips_memory_scrub", "after a trap that is not an ecall, memory is not scrubbed",
     lambda s: sub(s, "    // The payload's confidential scratch", CONF_SKIP + "    // The payload's confidential scratch")),
    ("halt_with_zero_skips_scratch", "a HALT with 0 leaves the scratch",
     lambda s: sub(s, "    // The payload's confidential scratch", "    beqz  a0, scrub_regs\n    // The payload's confidential scratch")),
    ("digest_kept_on_failure", "the digest window is never zeroed",
     lambda s: sub(s, "    beqz  a0, scrub_regs\n", "    j     scrub_regs\n")),
    ("digest_always_zeroed", "the digest window is zeroed on a HALT with 0 too",
     lambda s: sub(s, "    beqz  a0, scrub_regs\n", "")),
    ("digest_test_inverted", "the digest window is zeroed only on a HALT with 0",
     lambda s: sub(s, "    beqz  a0, scrub_regs\n", "    bnez  a0, scrub_regs\n")),
    ("digest_window_one_word_short", "the digest window is 28 bytes",
     lambda s: sub(s, "addi  t1, t0, 32", "addi  t1, t0, 28")),
    ("digest_window_one_word_long", "the digest window is 36 bytes",
     lambda s: sub(s, "addi  t1, t0, 32", "addi  t1, t0, 36")),
    ("digest_loop_runs_to_scratch_end", "the digest loop keeps the scratch loop's end",
     lambda s: sub(s, "    addi  t1, t0, 32\n", "")),
    ("digest_window_starts_late", "the digest window starts at +0x2144",
     lambda s: sub(s, "addi  t0, t0, 0x140", "addi  t0, t0, 0x144")),
    ("fault_does_not_scrub", "a fault parks without scrubbing anything",
     lambda s: sub(s, "j     scrub_exit", "j     halt_loop")),
    ("scrub_skips_register", "the register scrub forgets x17",
     lambda s: sub(s, "li    x17, 0", "", "last")),
    ("saved_words_stay", "the saved t0 and t1 stay on the stack",
     lambda s: sub(sub(s, "sw    zero, 0(sp)", ""), "sw    zero, 4(sp)", ""))
]


def caught(mon: bytes) -> bool:
    return bool(attack_cases.run_all(mon) or kernel_cases.run_all(mon, names={"random 0", "stuck at 1"}))


def main():
    with open(os.path.join(oracle.EXP239, "monitor.S")) as f:
        src = f.read()
    assert harness.build(src) == oracle.monitor(), "monitor.S does not assemble to monitor.bin"
    miss = [(label, what) for label, what, edit in VARIANTS if not caught(harness.build(edit(src)))]
    for label, what in miss:
        print(f"FAIL  {label}: {what} — and every hostile payload and both streams still passed")
    if miss:
        sys.exit(1)
    print(f"PASS  {len(VARIANTS)} broken monitors, each caught by the hostile payloads and the kernel's streams:")
    for label, what, _ in VARIANTS:
        print(f"      {label:32} {what}")


if __name__ == "__main__":
    main()
