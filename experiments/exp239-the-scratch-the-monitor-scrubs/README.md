# exp239 — the scratch the monitor scrubs

<!-- SPDX-License-Identifier: Apache-2.0 -->

**A 156-instruction, 624-byte RISC-V M-mode monitor (`monitor.bin`) that zeroes the payload's memory on
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
the trap entry saved and the register scrub zeroes after. The reports come first, so the `minstret` and `mcycle`
a HALT reports are the payload's, not the scrub's: the monitor is 2 counted instructions on top of the kernel,
as in exp238, and the scrub costs the payload nothing it can count.

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
| `monitor_halt_pre`, `monitor_fault_cause_pre`, `monitor_fault_syscall_pre` | the three ways in, from the trap vector to the word before the scrub of memory: 23, 25 and 28 steps, the report made, the saved words and `mscratch` zero, the box untouched |
| `monitor_scrubs` | **whatever trapped** — an `ecall` for HALT, an `ecall` for anything else, a fault — the machine parks with `exitCode u` (the payload's `a0` for a HALT, 1 for the rest), every other register zero, and `Scrubbed (exitCode u)` of the memory the payload left |
| `monitor_fail_closed_scrub` | **a failed run leaves no digest.** Unless the trap is an `ecall` with `t0 = 1` and `a0 = 0`: the scratch and the digest window are both zero, and every other byte, bar the monitor's stack and report words, is the payload's |
| `monitor_pass_digest_kept` | **only a clean HALT keeps its digest.** An `ecall` with `t0 = 1` and `a0 = 0`: the scratch is zero, the 32 bytes of the digest window are exactly the payload's, everything else is the payload's but for the monitor's stack and report words |
| `exitCode_zero_iff` | the exit code is 0 only for a HALT with `a0 = 0` |
| `monitor_end_to_end` | from reset, boot (53 steps), then up to `n` payload steps: it is still running, boxed, in U-mode with the monitor's words in place — or it trapped, and the machine parks with `Scrubbed` of the memory at the trap |

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
3. **Thirty mutants** (`proof/mutants.txt`), each refused by Lean in the chunk or lemma it breaks.
   Twenty-five change one word of `monitorCode`: the scratch loop's end, start, stride, stored value and
   branch; the digest test removed, inverted, or turned into an unconditional skip; the digest window's length,
   start, store and stride; a fault that jumps past the scrub of memory; a fault that exits with 2; a saved word
   or `mscratch` left behind; a register the scrub forgets, and `a0` zeroed where `x9` should be; and boot and
   handler words, as exp236's. Five change a claim: the digest "survives every exit", the scratch or the window
   one word longer, every trap that is not a HALT "exits with 0", the park loop one word on.
4. `proof/Scrub.lean` is what `proof/gen.py` writes.
5. **exp223's kernel under the monitor** (`suite/kernel_cases.py`): exp222's fourteen sample streams, eight
   that pass exp114's health tests and six that do not (exp223's README says seven and seven; its capture
   says eight and six), each run twice — alone in M-mode with no monitor, and under the monitor — with the
   box seeded with junk in every byte the kernel does not own. The exit code, the instruction count (334,284
   for a pass, 17,425 for a fail, exp223's theorem; +2 for the monitor's framing), and the box when the kernel
   halts must agree between the two runs; the digest of a pass must be SHA-256 of the 4,096 bytes of samples;
   and when the monitor parks, memory over all 256 KiB of the emulator's RAM must be what the kernel left,
   with the scratch zero and, on a fail, the digest window zero (`suite/oracle.py`).
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
(the capture is added by the next commit)
```
