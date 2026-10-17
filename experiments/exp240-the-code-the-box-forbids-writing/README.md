# exp240 — the code the box forbids writing

<!-- SPDX-License-Identifier: Apache-2.0 -->

**A 150-word, 600-byte RISC-V M-mode monitor (`monitor.bin`) that fences its payload into a box where no byte can be
both written and run, and a Lean 4 proof of what its own words do when the privileged model of exp235 runs them.
exp236's monitor gives the payload 64 KiB with one read-write-execute entry, so a stray pointer can rewrite the
payload's own instructions and anything it writes it can run. This one uses three of the four PMP entries, tried in
order: the **code**, 128 bytes, read and execute; the **data**, 4 KiB, read and write, with the code carved out of it by
the entry before; the **stack**, 4 KiB at the top of the box, read and write; and between the data and the stack a
52 KiB **guard** that matches nothing. The proof covers whatever the payload does: no address is fetchable and storable;
the code's bytes are the same after any number of steps, by the PMP alone; and the monitor parks with every register
but `a0` zero, memory as the payload left it but for the monitor's own stack words. Boot leaves the CSR file at
one constant whatever came before it, and a round leaves the machine ready for the next, any number of times. exp225's
Rule 30 kernel runs a hundred rounds under it on an emulator, loaded once, and every round's 256 generations are
`rule30.py`'s. Nothing here ran on silicon or on the Hazard3 RTL.**

Needs: **no board**. A sibling of exp238 and exp239, not a successor: all three are exp236's monitor with something
changed, and each has its own budget of words. The design is in `docs/micro-monitor/`, and section 5.4 there lists
where this differs from it.

## What the monitor does

`monitor.S`, assembled at `0x80000000`. It is exp236's, word for word, but for the seven words boot adds to set three
entries where exp236 set one: the trap vector and everything after it is exp236's, `0x1c` bytes further on.

```
0x80000040  _reset (boot, 60 steps)   mtvec <- 0x80000130, mscratch <- 0x80008000, mcountinhibit <- 5,
                                      pmpaddr0 <- 0x2000400f, pmpaddr1 <- 0x200041ff, pmpaddr2 <- 0x20007dff,
                                      pmpcfg0 <- 0x001b1b1d, mepc <- 0x80010000, MPP <- U, counters <- 0,
                                      sp <- 0x80020000, x1, x3..x31 <- 0, mcountinhibit <- 0, mret
0x80000130  trap_handler              freeze counters, swap sp with mscratch, save t0 and t1 at
                                      0x80008000/4, read mcause
                                        mcause == 8 and saved t0 == 1  ->  handle_halt: report HALT
                                        anything else                  ->  handle_fault: report FAULT, a0 <- 1
0x800001bc  scrub_exit                clear the two saved words and mscratch, x1..x9 and x11..x31,
                                      write a0 to the exit port, x6 <- 0
0x80000250  halt_loop                 wfi; j halt_loop
```

The three entries, and what each makes of an access (`pmpcfg0 = 0x001b1b1d`):

| entry | what | bytes | `pmpaddr` | `cfg` | read | write | execute |
| :---: | :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| 0 | code | `[0x80010000, 0x80010080)` | `0x2000400f` | `0x1d` | yes | **no** | yes |
| 1 | data | `[0x80010000, 0x80011000)` | `0x200041ff` | `0x1b` | yes | yes | **no** |
| 2 | stack | `[0x8001f000, 0x80020000)` | `0x20007dff` | `0x1b` | yes | yes | **no** |
| 3 | off | | | `0x00` | | | |

The lowest-numbered entry that touches an access decides it. The data entry surrounds the code entry, and the code
entry is first: a store into the code matches entry 0, which has no W, and is refused; a jump into the data matches
entry 1, which has no X, and is refused. `[0x80011000, 0x8001f000)` matches nothing, and U-mode that matches nothing is
refused, so a stack that grows down past its entry, or a pointer that wanders up from the data, ends in a fault with the
address in `mtval`, and the monitor reports and parks. The payload starts with `sp = 0x80020000`, the top of the stack.

The layout is the one exp225's kernel wants. It finds its own address with `auipc`, reads its seed at `+0x100` and writes
its history at `+0x200..+0x600`: past its own 76 bytes of code, and in the data. The code entry is 128 bytes, a power of
two the kernel fits in; a payload has to fit in it, and one of 33 words cannot fetch its 33rd.

The reports go to two testbench words, `0xc0000004` (print) and `0xc0000008` (exit); the proof treats them as memory.
Only HALT is served. A round is a hardware reset, boot, the payload to its first trap, and the monitor to the park loop.

## What is proved

All on Lean's own axioms. The library half, `lean/Rv32/WxBox.lean`, is about any machine in U-mode with the three
entries (`WXBoxed`), not about this monitor:

| theorem | says |
| :--- | :--- |
| `wx_fetch_iff` | an instruction fetch passes **exactly** inside the code entry |
| `wx_store_ok` | a store passes only wholly outside the code entry and wholly inside the data or the stack entry; `wx_store_allowed_data` and `wx_store_allowed_stack` say every such store does |
| `wx_load_ok` | a load passes only wholly inside the code, the data or the stack |
| `wx_disjoint`, `wx_no_write_exec` | **no byte is both writable and executable.** A fetch and a store that pass touch disjoint bytes; at the width the machine uses, no address passes both |
| `wx_step`, `wx_run` | one step, and any number of steps up to the first trap, of a boxed payload: it stays in U-mode, boxed, the CSRs the monitor set unchanged, and no byte `WxFrozen` names -- the code, and everything outside the data and the stack -- changes; or it traps to the vector with the registers and memory as it left them |
| `wx_code_immutable` | the code's bytes are the same after any number of steps. Nothing about the payload's instructions is assumed: it is the PMP alone |
| `pmpCheck_M_outside_in` | M-mode outside the box is never refused, whichever of the entries are on |

And about the words of `monitor.bin`, in `proof/Wx.lean`, which `check.sh` holds against `monitor.S` assembled afresh:

| theorem | says |
| :--- | :--- |
| `monitor_boot` | from reset (image loaded, `pc = 0x80000040`, M-mode, CSRs at reset, any registers), 60 steps give `WXBoxed` with the three entries at `0x80010000`, `sp = 0x80020000`, every other register zero, memory untouched, and **the CSR file exactly `csrsBooted`**: counters at 2, `mepc`, the trap vector, `mstatus`, the PMP -- constants |
| `monitor_halt`, `monitor_fault_cause`, `monitor_fault_syscall` | from the trap vector, whatever the payload left: 57, 59 and 62 steps to the park loop, the report made, the saved words and `mscratch` zero, every register but `a0` zero (`a0` the payload's own for a HALT, 1 otherwise), and **every byte of memory but the monitor's stack words and report words as the payload left it** |
| `monitor_traps` | the three, whichever it was: `Parked (run (trapSteps u) u) (exitCode u)`, the monitor's words in place, `FrameSP` |
| `payload_runs` | the payload in the box runs up to its first trap; frozen bytes are the image's; at the trap the handler's theorems apply |
| `monitor_end_to_end` | from reset, boot, then up to `n` payload steps: still running, boxed, in U-mode, with the monitor's words and **the code's 128 bytes as loaded** -- or it trapped, and the machine parks with those, and with memory as the payload left it but for the monitor's stack words |
| `monitor_reentry` | from any `Ready` machine -- the monitor's words in memory, whatever else: any registers, any CSRs, any privilege, any `pc` -- a reset and boot leave `WXBoxed`, `csrsBooted`, and `sp` at the top. **Nothing a round leaves behind reaches the next** |
| `monitor_round_ready` | one round from a `Ready` machine ends parked, and `Ready` again, with the code region the bytes it was loaded with |
| `monitor_rounds` | any number of rounds: `Ready` again |

A round is `Round`: reset, boot, the payload to its first trap (`Trapped`: M-mode, every step before it U-mode), and the
monitor's `trapSteps u` steps. `Ready` is the monitor's words in memory and the code region `C`; the registers and the
CSRs are not in it, which is the claim.

Each short run of the handler is one theorem -- a chunk, a few instructions -- written by `proof/gen.py` with the machinery
of `tools/monitor/chunks.py`, as exp238's and exp239's are; boot and the definitions are exp236's proof text with the PMP
values changed and the addresses moved on, `proof/defs.lean` and `proof/tail.lean` the hand-written parts, and `check.sh`
fails if `Wx.lean` is not what the generator writes.

## What is not proved, and what it rests on

- **The kernel's correctness is not joined to this proof.** exp225's theorem is about the kernel in Tier 1, from a base
  address it finds itself; that it also runs here without touching a PMP rule -- 3,079 instructions, one fetch window of
  76 bytes, stores only in `+0x200..+0x600` -- is checked on the emulator, a hundred rounds, byte for byte against a
  Rule 30 written a cell at a time, and not proved.
- **The model is not the chip.** `Priv.lean` is a reading of the Hazard3 documentation; nothing here ran on the RTL or on
  an RP2350. In particular the **order of the entries** is the RISC-V rule -- the lowest-numbered entry that matches
  decides -- which the carve-out depends on, and it is not measured on Hazard3 here. A core that tried the entries in
  another order would let a payload write its code (`pmp_entries_tried_backwards` shows Lean refusing exactly that
  model). There is no chip build of this monitor.
- **The payload has to fit in 128 bytes** to run, and to be a position-independent one that keeps its data past its code.
  That is the price of the carve-out; a payload that wants a bigger code entry needs a bigger power of two.
- **`env.region`.** Tier 1 checks its own region on every load and store; the handler theorems assume it is
  `monRegion = [0x80000000, 0xC0000100)`, which holds the box. The sandbox theorems hold for any `env`.
- **No interrupts.** The model has none. The monitor never writes `mie`, and relies on it being 0 at reset.
- **A reset is a model.** `resetOf` keeps the registers and the memory and resets the `pc`, the privilege and the CSRs. A
  chip's reset also puts the SRAM in whatever state it likes; `Ready` is what a round needs of it.
- **The stack words.** Trap entry saves `t0` and `t1` at `0x80008000/4`; the scrub zeroes them. The two words after are
  never written, and the theorems say nothing about them.
- **Reads.** `wx_load_ok` is what a load can reach; the monitor does not scrub what the payload wrote, in the data or on the
  stack (exp239's monitor does, for exp223's kernel). The next payload reads what the last one left.
- **The park loop's `wfi`** is not an instruction of the model; the theorems end with `pc` at it.
- **The emulator** (`tools/monitor/emulator.py`) is a second reading of the specification by the same author as the model.
  It does not hard-code the monitor's configuration: it decodes `pmpcfg0` and `pmpaddr0..3` when each instruction runs.

## The checks

1. `monitor.py --check`: `monitor.S` assembles to `monitor.bin` byte for byte, the SHA-256 matches, 150 ≤ 200 words, and
   `monitorCode` in the proof is the binary's words in order.
2. `Wx.lean` checks, with no errors and no warnings, on Lean's own axioms (and so does `WxBox.lean`, which it imports).
3. **Forty mutants** (`proof/mutants.txt`), each refused by Lean in the theorem it breaks. Twenty-six change one word of
   `monitorCode`: the three addresses and the configuration word -- a code entry of 256 or 64 bytes, a data entry of 8 or
   2 KiB, a stack entry of 8 KiB or one that reaches the monitor; a code entry that can be written, a data or stack entry
   that can be run, an entry off, entry 3 on, the code and the data exchanged -- and boot and handler words, as exp236's.
   Four change a claim (the counters at 3, a HALT in 56 steps, the code four bytes longer, the park loop a word on). Ten
   change a rule of the model or a statement of the library: stores and `ecall`s not checked, the entries tried
   backwards, a straddling access that passes, a store that needs R and not W, a fetch that needs R and not X, an access
   that matches nothing that passes, a code entry with W, a data entry with X, and a frozen set that forgets the last word
   of the code.
4. `proof/Wx.lean` is what `proof/gen.py` writes.
5. **Rule 30, round after round** (`suite/rounds.py`): exp225's kernel loaded once into the code entry, the box seeded with
   junk in every byte it does not own, a hundred rounds. Between rounds the host resets the core and writes one word, the
   last generation, as the next seed. Each round ends parked with HALT 0, the monitor having counted 3,079 + 2
   instructions, one trap, the `ecall`; the 1,024 bytes of history are `rule30.py`'s, and the kernel run alone leaves the
   same; 256 KiB of RAM is what it was but for the history and the monitor's two stack words; the code entry's bytes are
   the same; and the parked machine, registers and CSRs and report, is the same after every round. The 25,600
   generations are `rule30.py`'s from the first seed. Ten rounds under exp236's monitor give the same: the stricter box
   costs the kernel nothing.
6. **Fifty-two hostile payloads** (`suite/wx_attacks.py`), each place tried from both sides: stores into the code (first
   word, last word, last byte, the next instruction, with secrets in 20 registers); the data from the first byte past the
   code to its last word, run and written; the guard, read, written and run, both ends; the stack from its bottom word to
   past its top, by recursion until it overflows, and by popping past the top; shellcode written into the data, where the
   kernel keeps its seed, and onto the stack, and run; a payload of 32 words and one of 33; the monitor, the M-mode stack,
   system SRAM, past the box; `pmpcfg0`, `mstatus`, the counters, `mret`, `wfi`, `ebreak`, an illegal word, a misaligned
   load and store, unknown and unoffered syscalls; and clean halts with secrets in registers. Each ends parked and
   scrubbed with the cause and the `mtval` the PMP rule gives, and the code entry's bytes as loaded. Three of them --
   self-modifying code, and shellcode in the data and on the stack -- run to a clean HALT under exp236's monitor and are
   stopped by this one.
7. **Twenty-five broken monitors** (`suite/broken_monitors.py`): `monitor.S` with one change -- each of the cases of check 3
   that the emulator can see, the two entries in the wrong order, a payload `sp` at the bottom of the stack, a register
   boot or the scrub forgets, a fault that does not scrub, saved words or `mscratch` left behind -- each must fail the
   hostile payloads or the rounds.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.
