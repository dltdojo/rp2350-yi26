# exp236 — the wall the monitor holds

<!-- SPDX-License-Identifier: Apache-2.0 -->

**A 143-word, 572-byte RISC-V M-mode monitor (`monitor.bin`) and a Lean 4 proof of
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
| `monitor_halt` | at the trap vector, `mcause = 8` and saved `t0 = 1`: 57 steps park the machine (`pc = 0x80000234`) with `a0` the payload's, every other register zero, `mscratch` zero, the saved words zero, and the host having heard the HALT report and then `a0` at the exit word |
| `monitor_fault_cause` | `mcause ≠ 8`: 59 steps, the same, with `a0 = 1` |
| `monitor_fault_syscall` | `mcause = 8`, saved `t0 ≠ 1`: 62 steps, the same, with `a0 = 1` |
| `monitor_scrub` | the scrub alone: 37 steps from `scrub_exit` |
| `monitor_end_to_end` | from reset, boot, then `n` payload steps: still running boxed with the monitor's words in place, or trapped — and then one of the three cases above applies and the machine parks, the host having heard `haltIo` or `faultIo`: the report, then the exit code |
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
- **The reports are proved as words, not as what they mean.** In `Priv.lean` an M-mode word store to a port
  (`0xc0000000..0xc000001f`) is recorded, in order, in `io`, and the theorems say which words the host heard:
  `faultIo` or `haltIo`, the report and then the exit code. The `mtval` a fault reports is 0: Hazard3
  hardwires `mtval` to 0, and the model and the emulator do the same ([the audit](../../docs/2026-10-23-1116-emulator-verdicts-vs-theorems-audit-zh-tw.md), G3).
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
   143 ≤ 150 words, and `monitorCode` in the proof is the binary's words in order.
2. `Monitor.lean` checks, with no errors and no warnings, on Lean's own axioms.
3. **Twenty-six mutants** (`proof/mutants.txt`), each refused by Lean in the theorem it breaks: twenty-three
   change one word of `monitorCode` — a PMP address (one window too small, one the whole address space, one
   that covers the monitor), a permission bit, `MPP`, the payload's entry or `sp`,
   a register boot or the scrub forgets (`x31`, `x2`, `x1`), `mscratch` the scrub leaves, the trap vector, the stack swap, the cause or syscall check, the
   fault exit code, the jump to the scrub, the report port, the HALT or FAULT tag, the exit code sent to the print
   word — and three change a rule of the model the proofs run on (U-mode stores not checked against the PMP;
   U-mode `ecall` executed; an M-mode store to a port not recorded). Until 2026-10-23 no theorem said what was
   reported, and the three report mutants would have been accepted.
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
=== exp236 — the wall the monitor holds ===
recorded at 2026-10-23T09:34:18Z from commit 6a32561

>>> the micro-monitor binary and size budget
PASS  monitor.bin (572 bytes, 143 insts) matches monitor.S, monitor.sha256 and monitorCode

>>> the formal theorems, and what they rest on
'Exp236.monitorCode_length' does not depend on any axioms
'Exp236.monitor_boot' depends on axioms: [propext, Quot.sound]
'Exp236.monitor_scrub' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp236.monitor_halt' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp236.monitor_fault_cause' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp236.monitor_fault_syscall' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp236.monitor_end_to_end' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Priv.umode_step' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Priv.umode_run' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong monitors and wrong sandboxes: each must be refused
pmp_window_small           boot writes a PMP address that fences off 32 bytes, not 64 KiB                          refused in monitor_boot_config
pmp_window_4gib            boot writes a PMP address that fences off the whole address space                       refused in monitor_boot_config
pmp_window_covers_monitor  boot writes a PMP address that fences off 128 KiB from the monitor's base               refused in monitor_boot_config
pmp_no_execute             boot makes the payload region read-write but not executable                             refused in monitor_boot_config
mret_to_m_mode             boot sets MPP to M-mode instead of clearing it                                          refused in monitor_boot_config
payload_entry_wrong        boot sends the payload to 0x80020000, past its region                                   refused in monitor_boot_config
payload_sp_wrong           boot gives the payload an sp at the bottom of its region                                refused in monitor_launch_1
boot_leaves_x31            boot loads 1 into x31 instead of zero                                                   refused in monitor_launch_3
trap_vector_wrong          boot points mtvec four bytes past the handler                                           refused in monitor_boot_config
mscratch_wrong             boot puts the M-mode stack in the payload's region                                      refused in monitor_boot_config
no_stack_swap              the handler keeps the payload's sp                                                      refused in handler_e1
cause_check_dropped        the handler never looks at mcause                                                       refused in handler_e3_ecall
syscall_check_dropped      the handler takes every ecall for HALT                                                  refused in handler_c_bad
fault_exit_code_two        a fault exits with 2                                                                    refused in handler_f6
fault_skips_scrub          a fault jumps to the park loop, not the scrub                                           refused in handler_f6
saved_t0_stays             the scrub leaves the saved t0 on the M-mode stack                                       refused in scrub_s1
scrub_leaves_sp            the scrub loads 1 into x2                                                               refused in scrub_s3
scrub_skips_ra             the scrub leaves x1                                                                     refused in scrub_s3
mscratch_stays             the scrub leaves mscratch holding the payload's sp                                      refused in scrub_s3
mmio_address_wrong         the reports go to a word in the payload's region                                        refused in handler_h1
halt_tag_wrong             the HALT report's tag is "HALU", not "HALT": the host hears a report that is not HALT   refused in handler_h1
fault_tag_wrong            the FAULT report's tag is "FAUM", not "FAUL"                                            refused in handler_f1
exit_code_to_print_word    the exit code goes to the print word, not the exit word                                 refused in scrub_s6
sandbox_store_unchecked    U-mode stores skip the PMP check                                                        refused in st_in_box
sandbox_ecall_passes       U-mode ecall is executed instead of trapped                                             refused in trap_none_plain
port_writes_unrecorded     model: an M-mode store to a port is not recorded                                        refused in handler_h1

>>> normal execution: secp256k1 field arithmetic under PMP sandbox
PASS  4 normal cases verified (exp229 add/sub/mul, a0=0, secret scrubbed)

>>> hostile payloads
PASS  23 hostile payloads end parked and scrubbed, with the hardware's cause:
      fault mcause=7  store into the monitor's code
      fault mcause=5  load the monitor's code
      fault mcause=7  write the M-mode stack
      fault mcause=5  read system SRAM
      fault mcause=1  jump into the monitor
      fault mcause=1  jump to the trap vector
      fault mcause=2  read mstatus
      fault mcause=2  set a bit in mstatus
      fault mcause=2  write mscratch
      fault mcause=2  read the cycle counter
      fault mcause=2  mret to M-mode
      fault mcause=2  wfi
      fault mcause=3  ebreak
      fault mcause=2  an illegal word
      fault mcause=4  a misaligned load
      fault mcause=8  an unknown syscall
      fault mcause=8  hash syscall (not offered)
      fault mcause=7  a fault with secrets in every register
      halt  exit=7    a clean halt with secrets in every register
      fault mcause=2  a fault with sp pointing into the monitor
      halt  exit=0    the registers it starts with
      halt  exit=0    a clean halt, exit code 0
      halt  exit=3    writes in the box are allowed

>>> monitors with one thing wrong: each must be caught
PASS  12 broken monitors, each caught by the attack and normal suites:
      pmp_window_4gib            the PMP window is the whole address space
      pmp_window_covers_monitor  the PMP window is 128 KiB from the monitor's base
      pmp_no_execute             the payload region is read-write but not executable
      mret_stays_in_m_mode       mret returns to M-mode
      boot_leaves_a_register     boot does not zero x31 before the payload
      no_stack_swap              the trap entry keeps the payload's sp
      scrub_skips_register       the scrub forgets x17
      scrub_skips_ra             the scrub forgets x1
      fault_does_not_scrub       a fault parks without scrubbing
      saved_words_stay           the saved t0 and t1 stay on the stack
      mscratch_stays             mscratch keeps the payload's sp
      any_syscall_halts          every ecall is taken for HALT

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  monitor.bin (572 bytes, 143 insts) matches monitor.S, monitor.sha256 and monitorCode
PASS  Monitor.lean checks, with no errors and no warnings
PASS  all 9 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  pmp_window_small: the proof refuses a version where boot writes a PMP address that fences off 32 bytes, not 64 KiB
PASS  pmp_window_4gib: the proof refuses a version where boot writes a PMP address that fences off the whole address space
PASS  pmp_window_covers_monitor: the proof refuses a version where boot writes a PMP address that fences off 128 KiB from the monitor's base
PASS  pmp_no_execute: the proof refuses a version where boot makes the payload region read-write but not executable
PASS  mret_to_m_mode: the proof refuses a version where boot sets MPP to M-mode instead of clearing it
PASS  payload_entry_wrong: the proof refuses a version where boot sends the payload to 0x80020000, past its region
PASS  payload_sp_wrong: the proof refuses a version where boot gives the payload an sp at the bottom of its region
PASS  boot_leaves_x31: the proof refuses a version where boot loads 1 into x31 instead of zero
PASS  trap_vector_wrong: the proof refuses a version where boot points mtvec four bytes past the handler
PASS  mscratch_wrong: the proof refuses a version where boot puts the M-mode stack in the payload's region
PASS  no_stack_swap: the proof refuses a version where the handler keeps the payload's sp
PASS  cause_check_dropped: the proof refuses a version where the handler never looks at mcause
PASS  syscall_check_dropped: the proof refuses a version where the handler takes every ecall for HALT
PASS  fault_exit_code_two: the proof refuses a version where a fault exits with 2
PASS  fault_skips_scrub: the proof refuses a version where a fault jumps to the park loop, not the scrub
PASS  saved_t0_stays: the proof refuses a version where the scrub leaves the saved t0 on the M-mode stack
PASS  scrub_leaves_sp: the proof refuses a version where the scrub loads 1 into x2
PASS  scrub_skips_ra: the proof refuses a version where the scrub leaves x1
PASS  mscratch_stays: the proof refuses a version where the scrub leaves mscratch holding the payload's sp
PASS  mmio_address_wrong: the proof refuses a version where the reports go to a word in the payload's region
PASS  halt_tag_wrong: the proof refuses a version where the HALT report's tag is "HALU", not "HALT": the host hears a report that is not HALT
PASS  fault_tag_wrong: the proof refuses a version where the FAULT report's tag is "FAUM", not "FAUL"
PASS  exit_code_to_print_word: the proof refuses a version where the exit code goes to the print word, not the exit word
PASS  sandbox_store_unchecked: the proof refuses a version where U-mode stores skip the PMP check
PASS  sandbox_ecall_passes: the proof refuses a version where U-mode ecall is executed instead of trapped
PASS  port_writes_unrecorded: the proof refuses a version where model: an M-mode store to a port is not recorded
PASS  4 normal cases verified (exp229 add/sub/mul, a0=0, secret scrubbed)
PASS  23 hostile payloads end parked and scrubbed, with the hardware's cause:
      fault mcause=7  store into the monitor's code
      fault mcause=5  load the monitor's code
      fault mcause=7  write the M-mode stack
      fault mcause=5  read system SRAM
      fault mcause=1  jump into the monitor
      fault mcause=1  jump to the trap vector
      fault mcause=2  read mstatus
      fault mcause=2  set a bit in mstatus
      fault mcause=2  write mscratch
      fault mcause=2  read the cycle counter
      fault mcause=2  mret to M-mode
      fault mcause=2  wfi
      fault mcause=3  ebreak
      fault mcause=2  an illegal word
      fault mcause=4  a misaligned load
      fault mcause=8  an unknown syscall
      fault mcause=8  hash syscall (not offered)
      fault mcause=7  a fault with secrets in every register
      halt  exit=7    a clean halt with secrets in every register
      fault mcause=2  a fault with sp pointing into the monitor
      halt  exit=0    the registers it starts with
      halt  exit=0    a clean halt, exit code 0
      halt  exit=3    writes in the box are allowed
PASS  12 broken monitors, each caught by the attack and normal suites:
      pmp_window_4gib            the PMP window is the whole address space
      pmp_window_covers_monitor  the PMP window is 128 KiB from the monitor's base
      pmp_no_execute             the payload region is read-write but not executable
      mret_stays_in_m_mode       mret returns to M-mode
      boot_leaves_a_register     boot does not zero x31 before the payload
      no_stack_swap              the trap entry keeps the payload's sp
      scrub_skips_register       the scrub forgets x17
      scrub_skips_ra             the scrub forgets x1
      fault_does_not_scrub       a fault parks without scrubbing
      saved_words_stay           the saved t0 and t1 stay on the stack
      mscratch_stays             mscratch keeps the payload's sp
      any_syscall_halts          every ecall is taken for HALT
```
