# exp236 — the wall the monitor holds

<!-- SPDX-License-Identifier: Apache-2.0 -->

**A 143-instruction, 572-byte RISC-V M-mode monitor (`monitor.bin`) and a Lean 4 proof of
what its own words do when the privileged model of exp235 runs them. From reset, boot
leaves the machine in U-mode at the payload's first word, the PMP fencing the payload into
64 KiB at `0x80010000`, every register zero but `sp`. Whatever the payload then does, it
stays in the box and writes only inside it, or it traps — and from the trap vector the
monitor parks the machine with every register but `a0` zero (`a0` is the payload's own exit
code on a clean HALT, 1 otherwise), `mscratch` and the two words it saved zero, its own words
untouched. Eighteen wrong monitors and wrong sandboxes are refused by Lean; twenty-three
hostile payloads, and twelve monitors with one thing wrong each, are run on an emulator.
Nothing here ran on silicon or on the Hazard3 RTL.**

Needs: **no board**. The middle stone of the micro-monitor track: exp235 is the model it runs
on, exp229's field kernel is the payload it was built to hold, and the design is in
`docs/micro-monitor/`.

## What the monitor does

`monitor.S`, assembled at `0x80000000`; `_start` jumps to `_reset` at `0x80000040`.

```
0x80000000  _start                    j _reset
0x80000040  _reset (boot, 53 steps)   mtvec <- 0x80000114, mscratch <- 0x80008000,
                                      mcountinhibit <- 5, pmpaddr0 <- 0x20005fff (64 KiB NAPOT
                                      at 0x80010000), pmpcfg0 <- 0x1f (NAPOT, RWX), mepc <-
                                      0x80010000, MPP <- U, counters <- 0, sp <- 0x80020000,
                                      x1, x3..x31 <- 0, mcountinhibit <- 0, mret
0x80000114  trap_handler              freeze counters, swap sp with mscratch, save t0 and t1 at
                                      0x80008000/4, read mcause
                                        mcause == 8 and saved t0 == 1  ->  handle_halt: report HALT
                                        anything else                  ->  handle_fault: report FAULT, a0 <- 1
0x800001a0  scrub_exit                clear the two saved words and mscratch, x1..x9 and x11..x31,
                                      write a0 to the exit port, x6 <- 0
0x80000234  halt_loop                 wfi; j halt_loop
```

The reports go to two testbench words, `0xc0000004` (print) and `0xc0000008` (exit); the proof
treats them as memory. Only HALT is served: no `HASH`, no `CHECKSIG`, which is all exp229's
field kernel asks for.

## What is proved (`proof/Monitor.lean`, `lean/Rv32/Sandbox.lean`)

All on Lean's own axioms (`propext`, `Classical.choice`, `Quot.sound`). They are about
`PrivMachine` fetching and executing `monitorCode` — the words of `monitor.bin`, which
`check.sh` holds against `monitor.S` assembled afresh — not about a restatement of what the
monitor is meant to do.

| theorem | says |
| :--- | :--- |
| `monitor_boot` | from reset (image loaded, `pc = 0x80000040`, M-mode, CSRs at reset, any registers), 53 steps give `UBoxed 0x80010000 0x80020000`, `pc = 0x80010000`, `sp = 0x80020000`, every other register zero, the CSRs the handler relies on |
| `umode_step`, `umode_run` (library) | from a boxed state, a step stays in U-mode, still boxed, writing only inside the box — or traps to `mtvec` with the registers and memory as the payload left them; the CSRs boot set do not change. For any number of steps, up to the first trap. Needs `hi ≤ 2^32` |
| `monitor_halt` | at the trap vector, `mcause = 8` and saved `t0 = 1`: 57 steps park the machine (`pc = 0x80000234`) with `a0` the payload's, every other register zero, `mscratch` zero, the saved words zero |
| `monitor_fault_cause` | `mcause ≠ 8`: 59 steps, the same, with `a0 = 1` |
| `monitor_fault_syscall` | `mcause = 8`, saved `t0 ≠ 1`: 62 steps, the same, with `a0 = 1` |
| `monitor_scrub` | the scrub alone: 37 steps from `scrub_exit` |
| `monitor_end_to_end` | from reset, boot, then `n` payload steps: still running boxed with the monitor's words in place, or trapped — and then one of the three cases above applies and the machine parks |
| `monitorCode_length` | 143 words |

The handler and the scrub are proved in 23 short runs (`handler_*`, `scrub_*`), each a few
instructions long and ending at its first store, then chained: a longer run makes a proof term
the kernel cannot check, and a store changes the memory the next fetch reads. Boot is six.

## What is not proved, and what it rests on

- **The model is not the chip.** `docs/micro-monitor/phase1_priv_machine_design.md` section 8 lists where
  `Priv.lean` differs from Hazard3 or takes a rule from the RISC-V specification instead of a
  measurement: `mcounteren`, the C extension, the set of CSRs, counter writes, misaligned causes.
  Nothing here ran on the Hazard3 RTL (the Verilator testbench is not built on this machine and
  nothing wires the monitor to it) or on an RP2350.
- **`env.region`.** Tier 1 checks its own region on every load and store; the handler theorems
  assume it is `monRegion = [0x80000000, 0xC0000100)`. The sandbox theorems hold for any `env`.
- **No interrupts.** The model has none. The monitor never writes `mie`, and relies on it being 0 at reset.
- **The park loop's `wfi`** is not an instruction of the model; the theorems end with `pc` at it.
- **Payload memory is not scrubbed.** What the payload wrote in its 64 KiB stays there. The registers,
  `mscratch` and the saved words are scrubbed; `monitor_end_to_end` says nothing of the box's contents.
- **Reads.** `umode_step` is about what the payload can *change*. That its loads cannot see outside the
  box follows from the PMP check before the load (`pmpCheck_uboxed_iff`), not from a separate theorem.
- **Constant instruction counts.** The design in `docs/micro-monitor/phase3_micro_monitor_design.md`
  asked for a theorem that a trap-and-return costs a fixed number of `minstret` counts. This monitor does
  not return from a trap — it parks — so there is no such constant to state.
- **The emulator** (`tools/monitor/emulator.py`) is a second reading of the specification by the same
  author as the model. It does not hard-code the monitor's configuration: it decodes `pmpcfg0`/`pmpaddr0..3`
  when each instruction runs and returns to the privilege `mstatus.MPP` holds.

## The checks

1. `monitor.py --check`: `monitor.S` assembles to `monitor.bin` byte for byte, the SHA-256 matches,
   143 ≤ 150 instructions, and `monitorCode` in the proof is the binary's words in order.
2. `Monitor.lean` checks, with no errors and no warnings, on Lean's own axioms.
3. **Eighteen mutants** (`proof/mutants.txt`), each refused by Lean in the theorem it breaks: sixteen
   change one word of `monitorCode` — a PMP address, a permission bit, `MPP`, the payload's entry or `sp`,
   a register boot or the scrub forgets, the trap vector, the stack swap, the cause or syscall check, the
   fault exit code, the jump to the scrub, the report port — and two change a rule of the model the sandbox
   proof runs on (U-mode stores not checked against the PMP; U-mode `ecall` executed).
4. **Four normal cases**: exp229's secp256k1 field kernel (add, subtract, subtract with borrow, multiply)
   runs under the monitor on the emulator, the result is right, `a0 = 0`, and the machine ends parked and scrubbed.
5. **Twenty-three hostile payloads** (`cases/attack_cases.py`): stores and loads of the monitor and of
   the M-mode stack, jumps into the monitor and to the trap vector, `csrr`/`csrrsi`/`csrw`, `mret`, `wfi`,
   `ebreak`, an illegal word, a misaligned load, unknown and unoffered syscalls, a fault with `sp` pointing
   into the monitor, a payload that reads every register it starts with, and clean halts with secrets in
   every register. Each ends parked and scrubbed with the cause the hardware rule gives.
6. **Twelve broken monitors** (`cases/broken_monitors.py`): `monitor.S` with one change — a PMP window of
   4 GiB or 128 KiB from the monitor's base, no execute permission, `mret` into M-mode, a register boot or the
   scrub forgets, no stack swap, a fault that does not scrub, saved words or `mscratch` left behind, every
   `ecall` taken for HALT — each must fail the attack or the normal suite. One that passed would be a hole in them.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
(pasted from capture.txt)
```
