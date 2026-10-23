# exp239 — the scratch the monitor scrubs

<!-- SPDX-License-Identifier: Apache-2.0 -->

**A 156-word, 624-byte RISC-V M-mode monitor (`monitor.bin`) that zeroes the payload's memory on
the way out, and a Lean 4 proof of what its own words do when the privileged model of exp235 runs them.
exp236's monitor scrubs the registers and leaves the payload's SRAM as the payload left it; for an entropy
conditioner that leaves the SHA-256 schedule and the raw samples in memory after it halts. This one zeroes
the confidential scratch, `[+0x2200, +0x4000)` of the payload's 64 KiB box, on every exit, and zeroes the
32-byte digest window, `[+0x2140, +0x2160)`, too on every exit but a `HALT` with `a0 = 0`: a failed health
test (`HALT 1`), any other nonzero `HALT`, a bad `ecall` and every fault leave no digest behind. The proof
covers whatever the payload did: one theorem says the machine parks with the exit code, every other register
zero and memory scrubbed, and a loop lemma says what a 1,920-trip zeroing loop leaves. exp223's NIST SP 800-90B
health tests and SHA-256 conditioner, on exp222's fourteen sample streams, run under the monitor on an
emulator and match the same kernel run with no monitor at all, byte for byte, but for the bytes the monitor
zeroes. Nothing here ran on silicon or on the Hazard3 RTL.**

Needs: **no board**. A sibling of exp238, not a successor: both are exp236's monitor with something added,
and each has its own budget of words. The design is in `docs/micro-monitor/`.

## What the monitor does

`monitor.S`, assembled at `0x80000000`. Words 0–106 — boot, the trap vector, the fault and HALT reports, and the
first three words of `scrub_exit` — and words 120–155 — the register scrub and the park loop — are exp236's, word
for word; thirteen words between them are new, and exp236's theorems are not about the whole.

```
0x80000040  _reset (boot, 53 steps)   as exp236: PMP 64 KiB NAPOT at 0x80010000, MPP <- U, every register
                                      zero but sp, counters on, mret
0x80000114  trap_handler              freeze counters, swap sp with mscratch, save t0 and t1 at
                                      0x80008000/4, read mcause
                                        mcause == 8 and saved t0 == 1  ->  handle_halt: report HALT
                                        anything else                  ->  handle_fault: report FAULT, a0 <- 1
0x800001a0  scrub_exit                clear the two saved words and mscratch  (exp236's)
0x800001ac    scratch                 t0 <- +0x2200, t1 <- +0x4000
0x800001b8    scrub_conf:             sw zero, 0(t0); addi t0, t0, 4; bne t0, t1, scrub_conf     (1,920 trips)
0x800001c4    beqz a0, scrub_regs     a0 = 0: keep the digest window
0x800001c8    digest                  t0 <- +0x2140, t1 <- t0 + 32
0x800001d4    scrub_digest:           the same three words                                          (8 trips)
0x800001e0  scrub_regs                x1..x9, x11..x31 <- 0, write a0 to the exit port, x6 <- 0  (exp236's)
0x80000268  halt_loop                 wfi; j halt_loop
```

The scrub reads `a0` as it is when the report is done: `handle_fault` sets it to 1 and `handle_halt` leaves
the payload's, so *a0 ≠ 0* is exactly "a fault, or a HALT that said so". The two loops use `t0` and `t1`, which
the trap entry saved and the register scrub zeroes after. The reports come first so that words 0–106 stay
exp236's, word for word, and so do their proofs. Where they come does not change what a HALT reports: the first
instruction of `trap_handler` (`csrwi mcountinhibit, 5`) freezes the counters, so neither the reports nor the
scrub are counted, and `minstret` and `mcycle` are the payload's either way. The monitor is 2 counted
instructions on top of the kernel, as in exp238.

The M-mode stores into the box are not refused by the PMP: the entry that fences the payload in is not
locked, so it binds U-mode and leaves M-mode alone (`pmpCheck_mon_in`).

## What is proved (`proof/Scrub.lean`)

All on Lean's own axioms. They are about `PrivMachine` fetching and executing `monitorCode` — the words of
`monitor.bin`, which `check.sh` holds against `monitor.S` assembled afresh.

| theorem | says |
| :--- | :--- |
| `monitor_boot` | exp236's, for these words: 53 steps from reset give `UBoxed 0x80010000 0x80020000` at `0x80010000`, every register zero but `sp` |
| `zloop_conf`, `zloop_dig` | **the loop lemma.** From the store, with `t0 = A` and `t1 = E` four-aligned, `A + 4(k + 1) = E` and `[A, E)` in the box: after `3(k + 1)` steps the machine is at the instruction after the branch, every byte of `[A, E)` is 0, no other byte of memory has changed, and `t0 = E`. Induction on `k`; each trip is three one-instruction theorems (`zstore`, `zadd`, `zbne`) and `zloop_iter`. The two loops are one template at two addresses |
| `monitor_scrub` | from the word after `mscratch` is zero, whatever `a0` is: the machine parks (`pc` at the `wfi`) with `a0` as it was and every other register zero, the monitor's words in place, and `Scrubbed a0`: the scratch zero; the digest window zero if `a0 ≠ 0` and **the payload's own 32 bytes** if `a0 = 0`; every other byte, bar the monitor's stack and report words, as it was. 5,798 steps for `a0 = 0` (`monitor_scrub_pass`), 5,825 otherwise (`monitor_scrub_fail`) |
| `monitor_halt_pre`, `monitor_fault_cause_pre`, `monitor_fault_syscall_pre` | the three ways in, from the trap vector to the word before the scrub of memory: 23, 25 and 28 steps, the report made — the words the host heard, in order —, the saved words and `mscratch` zero, the box untouched |
| `monitor_scrubs` | **whatever trapped** — an `ecall` for HALT, an `ecall` for anything else, a fault — the machine parks with `exitCode u` (the payload's `a0` for a HALT, 1 for the rest), every other register zero, and `Scrubbed (exitCode u)` of the memory the payload left; the host has heard `trapIo u`, the report for the way it trapped and then the exit code |
| `monitor_fail_closed_scrub` | **a failed run leaves no digest.** Unless the trap is an `ecall` with `t0 = 1` and `a0 = 0`: the scratch and the digest window are both zero, and every other byte, bar the monitor's stack and report words, is the payload's |
| `monitor_pass_digest_kept` | **only a clean HALT keeps its digest.** An `ecall` with `t0 = 1` and `a0 = 0`: the scratch is zero, the 32 bytes of the digest window are exactly the payload's, everything else is the payload's but for the monitor's stack and report words |
| `exitCode_zero_iff` | the exit code is 0 only for a HALT with `a0 = 0` |
| `monitor_end_to_end` | from reset, boot (53 steps), then up to `n` payload steps: it is still running, boxed, in U-mode with the monitor's words in place — or it trapped, and the machine parks with `Scrubbed` of the memory at the trap, the host having heard `trapIo u` |

Each short run is one theorem — a chunk, a few instructions — with one statement and one proof, written by
`tools/monitor/chunks.py` from the table in `proof/gen.py`, which exp238's generator also uses now (its
`Calls.lean` is byte for byte what it was). What is new is the loop: 1,920 trips cannot be run one step at
a time, so the proof is the induction above, and the facts the chunks carry are joined with
`Zeroed lo hi m m'` (the range is zero, the rest is as it was). `proof/defs.lean` has the definitions and the
lemmas that join them; `proof/tail.lean` the headline theorems; `check.sh` fails if `Scrub.lean` is not what
the generator writes.

## What is not proved, and what it rests on

- **The monitor does not know a digest from any other bytes.** It keeps the 32 bytes at `+0x2140` when the
  payload says `HALT 0`, and zeroes them otherwise. That a `HALT 0` means the health tests passed, and the 32
  bytes are SHA-256 of the samples, is exp223's theorem about its kernel. A payload that writes junk there
  and halts with 0 leaves junk there. What the monitor adds is the other direction: it does not rely on the
  payload having left the window empty on a failure.
- **The kernel's correctness is not joined to this proof.** exp223's theorems need a 128 KiB region
  (exp208's SHA-256 starts at `0x1000` and its own proof extends to `0x11000`); the monitor's box is 64 KiB.
  The kernel touches nothing above `+0x4000`, so it runs in the box, but its theorems do not apply there. The
  monitor's behaviour is proved here; the kernel's result under it is compared on the emulator, byte for byte,
  with the kernel run with no monitor.
- **The model is not the chip.** As exp236: `Priv.lean` is a reading of the Hazard3 documentation; nothing here
  ran on the RTL or on an RP2350. There is no chip build of this monitor: exp237's `monitor_chip.S` is derived
  from exp236's and unproved, and a port is a later experiment.
- **The reports are proved as words, not as what they mean.** In `Priv.lean` an M-mode word store to a port
  (`0xc0000000..0xc000001f`) is recorded, in order, in `io`, and the theorems say which words the host heard:
  `trapIo u`, the report and then the exit code. The `mtval` a fault reports is 0, because the model's traps
  do not write `mtval`; the emulator's do ([the audit](../../docs/2026-10-23-1116-emulator-verdicts-vs-theorems-audit-zh-tw.md), G3).
- **`env.region`.** Tier 1 checks its own region on every load and store; the handler theorems assume it is
  `monRegion = [0x80000000, 0xC0000100)`, which holds the box. The sandbox theorems hold for any `env`.
- **No interrupts.** The model has none. The monitor never writes `mie`, and relies on it being 0 at reset.
- **The stack words.** Trap entry saves `t0` and `t1` at `0x80008000/4`; the scrub zeroes them. The two words
  after are never written, and the theorems say nothing about them.
- **Reads.** `Scrubbed` is about what the payload can *leave*. That its loads cannot see outside the box
  follows from the PMP check before the load, as in exp236.
- **The park loop's `wfi`** is not an instruction of the model; the theorems end with `pc` at it.
- **The emulator** (`tools/monitor/emulator.py`) is a second reading of the specification by the same author
  as the model.

## The checks

1. `monitor.py --check`: `monitor.S` assembles to `monitor.bin` byte for byte, the SHA-256 matches,
   156 ≤ 200 words, and `monitorCode` in the proof is the binary's words in order.
2. `Scrub.lean` checks, with no errors and no warnings, on Lean's own axioms.
3. **Thirty-seven mutants** (`proof/mutants.txt`), each refused by Lean in the chunk or lemma it breaks.
   Thirty-two change `monitorCode` -- one word, or the scratch loop's three turned into `nop`s: the scratch
   loop's end, start (late or early), stride, stored value and branch, or the whole loop gone; the digest test removed, inverted, or turned into an unconditional skip; the digest window's length
   (short or long), start, store and stride, and a digest loop that keeps the scratch loop's end; a fault that jumps past the scrub of memory; a fault that exits with 2; a saved word
   or `mscratch` left behind; a register the scrub forgets, and `a0` zeroed where `x9` should be; the HALT or
   FAULT tag, or the exit code sent to the print word, which no theorem refused until 2026-10-23; and boot and
   handler words, as exp236's. Five change a claim: the digest "survives every exit", the scratch or the window
   one word longer, every trap that is not a HALT "exits with 0", the park loop one word on.
4. `proof/Scrub.lean` is what `proof/gen.py` writes.
5. **exp223's kernel under the monitor** (`suite/kernel_cases.py`): exp222's fourteen sample streams, eight
   that pass exp114's health tests and six that do not, each run twice — alone in M-mode with no monitor, and
   under the monitor — with the box seeded with junk in every byte the kernel does not own. The exit code, the
   instruction count (334,284 for a pass, 17,425 for a fail, exp223's theorem; +2 for the monitor's framing),
   and the box when the kernel halts must agree between the two runs; the digest of a pass must be SHA-256 of
   the 4,096 bytes of samples; and when the monitor parks, memory over all 256 KiB of the emulator's RAM must
   be what the kernel left, with the scratch zero and, on a fail, the digest window zero (`suite/oracle.py`).
6. **Payloads that leave secrets in memory** (`suite/attack_cases.py`): nineteen payloads that fill
   `[+0x2100, +0x4010)` — the 64 bytes before the window, the window, the 160 bytes between it and the scratch,
   the scratch, 16 bytes past it — and then leave: a HALT with 0, 1, 2 or `0x80000000`, with secrets in
   every register, from the last word of the box; a store into the monitor, a load from system SRAM, an illegal
   word, a CSR read, `ebreak`, an unoffered `ecall`, a jump out of the box; one word on each side of the
   scratch and of the window. Each ends parked and scrubbed with the hardware's cause, and memory as the oracle says.
7. **Nineteen broken monitors** (`suite/broken_monitors.py`): `monitor.S` with one change — a loop a word short
   or long, starting a word early or late, stepping by eight, storing the pointer, the digest kept on a failure,
   zeroed on a pass, the test inverted, the window 28 or 36 bytes, a digest loop that runs to the end of the
   scratch, a fault or a HALT with 0 that skips the scrub, a register forgotten, a saved word left — each must
   fail the attack or the kernel suite.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp239 — the scratch the monitor scrubs ===
recorded at 2026-10-23T04:49:26Z from commit 7d83183

>>> the micro-monitor binary and size budget
PASS  monitor.bin (624 bytes, 156 words) is monitor.S assembled, matches monitor.sha256, is within 200 words, and is proof/Scrub.lean's monitorCode

>>> the formal theorems, and what they rest on
'Exp239.monitorCode_length' does not depend on any axioms
'Exp239.monitor_boot' depends on axioms: [propext, Quot.sound]
'Exp239.zloop_conf' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp239.zloop_dig' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp239.monitor_scrub' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp239.monitor_scrubs' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp239.monitor_fail_closed_scrub' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp239.monitor_pass_digest_kept' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp239.monitor_end_to_end' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong monitors and wrong claims: each must be refused
scratch_ends_early               the scratch loop's end is +0x3000, not +0x4000                     refused in mem_setup
scratch_starts_late              the scratch loop starts at +0x2204                                 refused in mem_setup
scratch_starts_early             the scratch loop starts at +0x21fc                                 refused in mem_setup
scratch_steps_by_eight           the scratch loop steps eight bytes                                 refused in zadd_conf
scratch_stores_the_pointer       the scratch loop stores its pointer, not zero                      refused in zstore_conf
scratch_loop_never_ends          the scratch loop branches on equal, not on not equal               refused in zbne_conf
scratch_not_scrubbed             there is no scratch loop: its three words are nops                 refused in zstore_conf
digest_kept_on_failure           the digest window is never zeroed                                  refused in conf_beq
digest_always_zeroed             the digest window is zeroed on a HALT with 0 too                   refused in conf_beq
digest_test_inverted             the digest window is zeroed only on a HALT with 0                  refused in conf_beq
digest_window_28_bytes           the digest window is 28 bytes                                      refused in dig_setup
digest_window_one_word_long      the digest window is 36 bytes                                      refused in dig_setup
digest_starts_late               the digest window starts at +0x2144                                refused in dig_setup
digest_stores_nothing            the digest loop's store is a no-op                                 refused in zstore_dig
digest_steps_by_eight            the digest loop steps eight bytes                                  refused in zadd_dig
digest_loop_runs_to_scratch_end  the digest loop keeps the scratch loop's end                       refused in dig_setup
fault_skips_the_scrub            a fault jumps past the scrub of memory                             refused in fault_6
fault_exit_code_two              a fault exits with 2                                               refused in fault_6
saved_t0_stays                   the scrub leaves the saved t0 on the M-mode stack                  refused in scrub_1a
mscratch_stays                   the scrub leaves mscratch holding the payload's sp                 refused in scrub_ms
scrub_leaves_x17                 the register scrub loads 1 into x17                                refused in regs_b
scrub_zeroes_a0                  the register scrub zeroes a0 where it should zero x9               refused in regs_a
no_stack_swap                    the handler keeps the payload's sp                                 refused in entry_1
cause_check_dropped              the handler never looks at mcause                                  refused in entry_mcause
syscall_check_dropped            the handler takes every ecall for HALT                             refused in call_is_halt
pmp_window_small                 boot writes a PMP address that fences off 32 bytes, not 64 KiB     refused in monitor_boot_config
pmp_no_execute                   boot makes the payload region read-write but not executable        refused in monitor_boot_config
mret_to_m_mode                   boot sets MPP to M-mode instead of clearing it                     refused in monitor_boot_config
payload_sp_wrong                 boot gives the payload an sp at the bottom of its region           refused in monitor_launch_1
claim_digest_always_kept         the proof claims the digest window survives every exit             refused in scrubbed_pass
claim_scratch_one_word_more      the proof claims the word at +0x4000 is zeroed too                 refused in scrubbed_pass
claim_digest_window_longer       the proof claims the 36 bytes from +0x2140 are the digest window   refused in scrubbed_fail
claim_other_exit_is_0            the proof claims every trap that is not a HALT exits with 0        refused in monitor_scrubs
claim_park_one_word_on           the proof parks the machine one word past the park loop            refused in monitor_scrub_pass

>>> exp223's kernel on fourteen sample streams, alone and under the monitor
PASS  14 streams, exp223's kernel under the monitor and alone: 8 healthy (HALT 0 after 334284, digest kept, scratch zero), 6 withheld (HALT 1 after 17425, digest window and scratch zero); everything else as the kernel left it
      stream                      exit  instructions
      random 0                       0        334284
      random 1                       0        334284
      random 2                       0        334284
      random 3                       0        334284
      random 4                       0        334284
      random 5                       0        334284
      stuck at 1                     1         17425
      stuck at 0                     1         17425
      runs of 20                     0        334284
      runs of 21                     1         17425
      a run of 21 at the end         1         17425
      588 agree                      0        334284
      589 agree                      1         17425
      nine ones then a zero          1         17425

>>> payloads that leave secrets in memory
PASS  19 payloads that leave secrets in memory end parked and scrubbed, the digest window kept only for exit code 0:
      halt  exit=0x0         fills, halts with 0
      halt  exit=0x1         fills, halts with 1
      halt  exit=0x2         fills, halts with 2
      halt  exit=0x80000000  fills, halts with 0x80000000
      halt  exit=0x0         fills, secrets in every register, halts with 0
      halt  exit=0x0         fills, halts with 0 from the last word of the box
      fault mcause=7         fills, stores into the monitor's code
      fault mcause=5         fills, loads from system SRAM
      fault mcause=2         fills, an illegal word
      fault mcause=2         fills, reads a CSR
      fault mcause=3         fills, ebreak
      fault mcause=8         fills, an ecall the monitor does not offer
      fault mcause=1         fills, jumps out of the box
      fault mcause=7         fills, secrets in every register, then faults
      halt  exit=0x0         fills only the scratch, halts with 0
      fault mcause=7         one word on each side of the scratch, a fault
      halt  exit=0x1         one word on each side of the digest window, halts with 1
      halt  exit=0x0         one word on each side of the digest window, halts with 0
      halt  exit=0x0         nothing written, halts with 0

>>> monitors with one thing wrong: each must be caught
PASS  19 broken monitors, each caught by the hostile payloads and the kernel's streams:
      scratch_one_word_short           the scratch loop stops at +0x3ffc
      scratch_one_word_long            the scratch loop runs on to +0x4004
      scratch_starts_late              the scratch loop starts at +0x2204
      scratch_starts_early             the scratch loop starts at +0x21fc
      scratch_every_other_word         the scratch loop steps eight bytes
      scratch_stores_the_address       the scratch loop stores its pointer, not zero
      scratch_not_scrubbed             there is no scratch loop
      fault_skips_memory_scrub         after a trap that is not an ecall, memory is not scrubbed
      halt_with_zero_skips_scratch     a HALT with 0 leaves the scratch
      digest_kept_on_failure           the digest window is never zeroed
      digest_always_zeroed             the digest window is zeroed on a HALT with 0 too
      digest_test_inverted             the digest window is zeroed only on a HALT with 0
      digest_window_one_word_short     the digest window is 28 bytes
      digest_window_one_word_long      the digest window is 36 bytes
      digest_loop_runs_to_scratch_end  the digest loop keeps the scratch loop's end
      digest_window_starts_late        the digest window starts at +0x2144
      fault_does_not_scrub             a fault parks without scrubbing anything
      scrub_skips_register             the register scrub forgets x17
      saved_words_stay                 the saved t0 and t1 stay on the stack

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  monitor.bin (624 bytes, 156 words) is monitor.S assembled, matches monitor.sha256, is within 200 words, and is proof/Scrub.lean's monitorCode
PASS  Scrub.lean checks, with no errors and no warnings
PASS  all 9 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  scratch_ends_early: the proof refuses a version where the scratch loop's end is +0x3000, not +0x4000
PASS  scratch_starts_late: the proof refuses a version where the scratch loop starts at +0x2204
PASS  scratch_starts_early: the proof refuses a version where the scratch loop starts at +0x21fc
PASS  scratch_steps_by_eight: the proof refuses a version where the scratch loop steps eight bytes
PASS  scratch_stores_the_pointer: the proof refuses a version where the scratch loop stores its pointer, not zero
PASS  scratch_loop_never_ends: the proof refuses a version where the scratch loop branches on equal, not on not equal
PASS  scratch_not_scrubbed: the proof refuses a version where there is no scratch loop: its three words are nops
PASS  digest_kept_on_failure: the proof refuses a version where the digest window is never zeroed
PASS  digest_always_zeroed: the proof refuses a version where the digest window is zeroed on a HALT with 0 too
PASS  digest_test_inverted: the proof refuses a version where the digest window is zeroed only on a HALT with 0
PASS  digest_window_28_bytes: the proof refuses a version where the digest window is 28 bytes
PASS  digest_window_one_word_long: the proof refuses a version where the digest window is 36 bytes
PASS  digest_starts_late: the proof refuses a version where the digest window starts at +0x2144
PASS  digest_stores_nothing: the proof refuses a version where the digest loop's store is a no-op
PASS  digest_steps_by_eight: the proof refuses a version where the digest loop steps eight bytes
PASS  digest_loop_runs_to_scratch_end: the proof refuses a version where the digest loop keeps the scratch loop's end
PASS  fault_skips_the_scrub: the proof refuses a version where a fault jumps past the scrub of memory
PASS  fault_exit_code_two: the proof refuses a version where a fault exits with 2
PASS  saved_t0_stays: the proof refuses a version where the scrub leaves the saved t0 on the M-mode stack
PASS  mscratch_stays: the proof refuses a version where the scrub leaves mscratch holding the payload's sp
PASS  scrub_leaves_x17: the proof refuses a version where the register scrub loads 1 into x17
PASS  scrub_zeroes_a0: the proof refuses a version where the register scrub zeroes a0 where it should zero x9
PASS  no_stack_swap: the proof refuses a version where the handler keeps the payload's sp
PASS  cause_check_dropped: the proof refuses a version where the handler never looks at mcause
PASS  syscall_check_dropped: the proof refuses a version where the handler takes every ecall for HALT
PASS  pmp_window_small: the proof refuses a version where boot writes a PMP address that fences off 32 bytes, not 64 KiB
PASS  pmp_no_execute: the proof refuses a version where boot makes the payload region read-write but not executable
PASS  mret_to_m_mode: the proof refuses a version where boot sets MPP to M-mode instead of clearing it
PASS  payload_sp_wrong: the proof refuses a version where boot gives the payload an sp at the bottom of its region
PASS  claim_digest_always_kept: the proof refuses a version where the proof claims the digest window survives every exit
PASS  claim_scratch_one_word_more: the proof refuses a version where the proof claims the word at +0x4000 is zeroed too
PASS  claim_digest_window_longer: the proof refuses a version where the proof claims the 36 bytes from +0x2140 are the digest window
PASS  claim_other_exit_is_0: the proof refuses a version where the proof claims every trap that is not a HALT exits with 0
PASS  claim_park_one_word_on: the proof refuses a version where the proof parks the machine one word past the park loop
PASS  proof/Scrub.lean is what proof/gen.py writes
PASS  14 streams, exp223's kernel under the monitor and alone: 8 healthy (HALT 0 after 334284, digest kept, scratch zero), 6 withheld (HALT 1 after 17425, digest window and scratch zero); everything else as the kernel left it
      stream                      exit  instructions
      random 0                       0        334284
      random 1                       0        334284
      random 2                       0        334284
      random 3                       0        334284
      random 4                       0        334284
      random 5                       0        334284
      stuck at 1                     1         17425
      stuck at 0                     1         17425
      runs of 20                     0        334284
      runs of 21                     1         17425
      a run of 21 at the end         1         17425
      588 agree                      0        334284
      589 agree                      1         17425
      nine ones then a zero          1         17425
PASS  19 payloads that leave secrets in memory end parked and scrubbed, the digest window kept only for exit code 0:
      halt  exit=0x0         fills, halts with 0
      halt  exit=0x1         fills, halts with 1
      halt  exit=0x2         fills, halts with 2
      halt  exit=0x80000000  fills, halts with 0x80000000
      halt  exit=0x0         fills, secrets in every register, halts with 0
      halt  exit=0x0         fills, halts with 0 from the last word of the box
      fault mcause=7         fills, stores into the monitor's code
      fault mcause=5         fills, loads from system SRAM
      fault mcause=2         fills, an illegal word
      fault mcause=2         fills, reads a CSR
      fault mcause=3         fills, ebreak
      fault mcause=8         fills, an ecall the monitor does not offer
      fault mcause=1         fills, jumps out of the box
      fault mcause=7         fills, secrets in every register, then faults
      halt  exit=0x0         fills only the scratch, halts with 0
      fault mcause=7         one word on each side of the scratch, a fault
      halt  exit=0x1         one word on each side of the digest window, halts with 1
      halt  exit=0x0         one word on each side of the digest window, halts with 0
      halt  exit=0x0         nothing written, halts with 0
PASS  19 broken monitors, each caught by the hostile payloads and the kernel's streams:
      scratch_one_word_short           the scratch loop stops at +0x3ffc
      scratch_one_word_long            the scratch loop runs on to +0x4004
      scratch_starts_late              the scratch loop starts at +0x2204
      scratch_starts_early             the scratch loop starts at +0x21fc
      scratch_every_other_word         the scratch loop steps eight bytes
      scratch_stores_the_address       the scratch loop stores its pointer, not zero
      scratch_not_scrubbed             there is no scratch loop
      fault_skips_memory_scrub         after a trap that is not an ecall, memory is not scrubbed
      halt_with_zero_skips_scratch     a HALT with 0 leaves the scratch
      digest_kept_on_failure           the digest window is never zeroed
      digest_always_zeroed             the digest window is zeroed on a HALT with 0 too
      digest_test_inverted             the digest window is zeroed only on a HALT with 0
      digest_window_one_word_short     the digest window is 28 bytes
      digest_window_one_word_long      the digest window is 36 bytes
      digest_loop_runs_to_scratch_end  the digest loop keeps the scratch loop's end
      digest_window_starts_late        the digest window starts at +0x2144
      fault_does_not_scrub             a fault parks without scrubbing anything
      scrub_skips_register             the register scrub forgets x17
      saved_words_stay                 the saved t0 and t1 stay on the stack
```
