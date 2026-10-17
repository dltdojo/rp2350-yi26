# exp240 — the code the box forbids writing

<!-- SPDX-License-Identifier: Apache-2.0 -->

**A 151-word, 604-byte RISC-V M-mode monitor (`monitor.bin`) that fences its payload into a box where no byte can be
both written and run, and a Lean 4 proof of what its own words do when the privileged model of exp235 runs them.
exp236's monitor gives the payload 64 KiB with one read-write-execute entry, so a stray pointer can rewrite the
payload's own instructions and anything it writes it can run. This one uses three of the four PMP entries, tried in
order: the **code**, 128 bytes, read and execute; the **data**, 4 KiB, read and write, with the code carved out of it by
the entry before; the **stack**, 4 KiB at the top of the box, read and write; and between the data and the stack a
52 KiB **guard** that matches nothing. The proof covers whatever the payload does: no address is fetchable and storable;
the code's bytes are the same after any number of steps, by the PMP alone; and the monitor parks with every register
but `a0` zero, memory as the payload left it but for the monitor's own stack words. Boot writes every CSR the model has,
so from any CSRs that lock no PMP entry it leaves the CSR file at one constant; and a round leaves the machine ready
for the next, with the host's writes between rounds, any number of times. exp225's
Rule 30 kernel runs a hundred rounds under it on an emulator, loaded once, and every round's 256 generations are
`rule30.py`'s. Nothing here ran on silicon or on the Hazard3 RTL.**

Needs: **no board**. A sibling of exp238 and exp239, not a successor: all three are exp236's monitor with something
changed, and each has its own budget of words. The design is in `docs/micro-monitor/`, and section 5.4 there lists
where this differs from it.

## What the monitor does

`monitor.S`, assembled at `0x80000000`. It is exp236's, word for word, but for the seven words boot adds to set three
entries where exp236 set one, and one more: boot writes `mstatus` whole, with one word where exp236 cleared `MPP` with
three, and writes `pmpaddr3`, `mcause` and `mtval`, which exp236 left as it found them. The trap vector and everything
after it is exp236's, `0x20` bytes further on.

```
0x80000040  _reset (boot, 61 steps)   mtvec <- 0x80000134, mscratch <- 0x80008000, mcountinhibit <- 5,
                                      pmpaddr0 <- 0x2000400f, pmpaddr1 <- 0x200041ff, pmpaddr2 <- 0x20007dff,
                                      pmpcfg0 <- 0x001b1b1d, mepc <- 0x80010000, mstatus <- 0 (MPP U),
                                      pmpaddr3, mcause, mtval <- 0, counters <- 0,
                                      sp <- 0x80020000, x1, x3..x31 <- 0, mcountinhibit <- 0, mret
0x80000134  trap_handler              freeze counters, swap sp with mscratch, save t0 and t1 at
                                      0x80008000/4, read mcause
                                        mcause == 8 and saved t0 == 1  ->  handle_halt: report HALT
                                        anything else                  ->  handle_fault: report FAULT, a0 <- 1
0x800001c0  scrub_exit                clear the two saved words and mscratch, x1..x9 and x11..x31,
                                      write a0 to the exit port, x6 <- 0
0x80000254  halt_loop                 wfi; j halt_loop
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
Only HALT is served. A round is a reset -- the hardware's, or one that leaves the CSRs as they were -- boot, the payload
to its first trap, and the monitor to the park loop; between rounds the host may write memory.

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
| `pmpCheck_M_unlocked` | while no entry is locked, M-mode is refused **nowhere**, for an aligned word, whatever the entries say: what boot needs for the words it runs before it has set the PMP |

And about the words of `monitor.bin`, in `proof/Wx.lean`, which `check.sh` holds against `monitor.S` assembled afresh:

| theorem | says |
| :--- | :--- |
| `monitor_boot` | from reset (image loaded, `pc = 0x80000040`, M-mode, **any CSRs that lock no PMP entry**, any registers), 61 steps give `WXBoxed` with the three entries at `0x80010000`, `sp = 0x80020000`, every other register zero, memory untouched, and **the CSR file exactly `csrsBooted`**: counters at 2, `mepc`, `mcause`, `mtval`, the trap vector, `mstatus`, the PMP -- constants |
| `monitor_halt`, `monitor_fault_cause`, `monitor_fault_syscall` | from the trap vector, whatever the payload left: 57, 59 and 62 steps to the park loop, the report made, the saved words and `mscratch` zero, every register but `a0` zero (`a0` the payload's own for a HALT, 1 otherwise), and **every byte of memory but the monitor's stack words and report words as the payload left it** |
| `monitor_traps` | the three, whichever it was: `Parked (run (trapSteps u) u) (exitCode u)`, the monitor's words in place, `FrameSP`, `pmpcfg0` as boot set it |
| `payload_runs` | the payload in the box runs up to its first trap; frozen bytes are the image's; at the trap the handler's theorems apply |
| `monitor_end_to_end` | from reset, or any CSRs that lock no entry, boot, then up to `n` payload steps: still running, boxed, in U-mode, with the monitor's words and **the code's 128 bytes as loaded** -- or it trapped, and the machine parks with those, and with memory as the payload left it but for the monitor's stack words |
| `monitor_reentry` | from any `Ready` machine -- the monitor's words in memory, the code, no PMP entry locked; whatever else: any registers, any other CSRs, any privilege, any `pc` -- a reset that keeps the CSRs and boot leave `WXBoxed`, `csrsBooted`, and `sp` at the top. **No register and no CSR a round leaves behind reaches the next**; memory does, outside the monitor's words, and the next payload reads it |
| `ready_of_host` | the host's write between rounds -- anything at all but the monitor's words, the code, or a lock bit (`HostWrite`) -- leaves a `Ready` machine `Ready` |
| `monitor_round_ready` | one round from a `Ready` machine ends parked, and `Ready` again, with the code region the bytes it was loaded with and the PMP as boot set it, which locks nothing |
| `monitor_rounds` | any number of rounds, and of the host's writes between them: `Ready` again. This is what `suite/rounds.py` runs |

A round is `Round`: reset, boot, the payload to its first trap (`Trapped`: M-mode, every step before it U-mode), and the
monitor's `trapSteps u` steps. `Ready` is the monitor's words in memory, the code region `C`, and no PMP entry locked;
the registers and the rest of the CSRs are not in it, which is the claim. `Rounds` is any sequence of `Round`s and
`HostWrite`s.

Each short run of the handler is one theorem -- a chunk, a few instructions -- written by `proof/gen.py` with the machinery
of `tools/monitor/chunks.py`, as exp238's and exp239's are; the second half of boot and the definitions are exp236's
proof text with the PMP values changed and the addresses moved on, the first half of boot written for CSRs it does not
know, `proof/defs.lean` and `proof/tail.lean` the hand-written parts, and `check.sh`
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
- **No interrupts.** The model has none, and no `mie`. The monitor never writes `mie`, and relies on it being 0 at reset;
  "any CSRs" in the theorems is any of the CSRs the model has, and a reset that kept a non-zero `mie` is outside them.
- **A reset is a model.** `resetOf` keeps the registers, the CSRs and the memory, and resets the `pc` and the privilege:
  the weakest reset there is, and the hardware's, which resets the CSRs too, is one. What is assumed of the CSRs is only
  that no PMP entry is locked: a locked entry holds M-mode too and ignores boot's writes, and this monitor never sets
  `L`. A chip's reset also puts the SRAM in whatever state it likes; `Ready` is what a round needs of it.
- **The stack words.** Trap entry saves `t0` and `t1` at `0x80008000/4`; the scrub zeroes them. The two words after are
  never written, and the theorems say nothing about them.
- **Reads.** `wx_load_ok` is what a load can reach; the monitor does not scrub what the payload wrote, in the data or on the
  stack (exp239's monitor does, for exp223's kernel). The next payload reads what the last one left.
- **The park loop's `wfi`** is not an instruction of the model; the theorems end with `pc` at it.
- **The emulator** (`tools/monitor/emulator.py`) is a second reading of the specification by the same author as the model.
  It does not hard-code the monitor's configuration: it decodes `pmpcfg0` and `pmpaddr0..3` when each instruction runs.
  An access the PMP lets through to an address with no memory faults with the same `mcause` and `mtval` as one the PMP
  refuses, as a bus fault does on the chip, so the monitor's report cannot tell a box that held from a box that let the
  access through to nothing. The emulator records which it was, and `harness.check_fault` requires the PMP's;
  `entry_three_on`, a fourth entry over the 32 bytes at address 0, is caught by that and by nothing else. A board run
  would have no such record.
- **The model's `mtval`** is a plain register: a trap does not write it, as the chip's does. That is why boot writes it --
  in the model, the next fault would report the last round's -- and why `mtval_kept` is refused by Lean and not looked
  for on the emulator.

## The checks

1. `monitor.py --check`: `monitor.S` assembles to `monitor.bin` byte for byte, the SHA-256 matches, 151 ≤ 200 words, and
   `monitorCode` in the proof is the binary's words in order.
2. `Wx.lean` checks, with no errors and no warnings, on Lean's own axioms (and so does `WxBox.lean`, which it imports).
3. **Forty-seven mutants** (`proof/mutants.txt`), each refused by Lean in the theorem it breaks. Twenty-nine change one
   word of `monitorCode`: the three addresses and the configuration word -- a code entry of 256 or 64 bytes, a data entry
   of 8 or 2 KiB, a stack entry of 8 KiB or one that reaches the monitor; a code entry that can be written, a data or
   stack entry that can be run, an entry off, entry 3 on, the code and the data exchanged -- boot's four writes of the
   CSRs it would otherwise find as they were (`mstatus`, `pmpaddr3`, `mcause`, `mtval`), and boot and handler words, as
   exp236's. Seven change a claim (the counters at 3, a HALT in 56 steps, the code four bytes longer, the park loop a
   word on, a round that may start with an entry locked, a host that may write the code or lock an entry). Eleven change
   a rule of the model or a statement of the library: stores and `ecall`s not checked, the entries tried backwards, a
   straddling access that passes, a store that needs R and not W, a fetch that needs R and not X, an access that matches
   nothing that passes, M-mode held to the entries as U-mode is, a code entry with W, a data entry with X, and a frozen
   set that forgets the last word of the code.
4. `proof/Wx.lean` is what `proof/gen.py` writes.
5. **Rule 30, round after round** (`suite/rounds.py`): exp225's kernel loaded once into the code entry, the box seeded with
   junk in every byte it does not own, a hundred rounds. Between rounds the host writes one word, the last generation, as
   the next seed, and resets the core: every other round with a reset that leaves junk in the CSRs -- `MPP` M-mode, both
   interrupt enables, four PMP entries on, none locked. Each round ends parked with HALT 0, the monitor having counted 3,079 + 2
   instructions, one trap, the `ecall`; the 1,024 bytes of history are `rule30.py`'s, and the kernel run alone leaves the
   same; 256 KiB of RAM is what it was but for the history and the monitor's two stack words; the code entry's bytes are
   the same; and the parked machine, registers and CSRs and report, is the same after every round. The 25,600
   generations are `rule30.py`'s from the first seed. Ten rounds under exp236's monitor give the same from a reset of the
   CSRs: the stricter box costs the kernel nothing. From the junk they give two different parked machines: exp236 clears
   `MPP` alone and sets one entry, so the interrupt enable and the addresses of the entries it does not use are still
   there at the park.
6. **Fifty-five hostile payloads** (`suite/wx_attacks.py`), each place tried from both sides: stores into the code (first
   word, last word, last byte, the next instruction, with secrets in 20 registers); the data from the first byte past the
   code to its last word, run and written; the guard, read, written and run, both ends; the stack from its bottom word to
   past its top, by recursion until it overflows, and by popping past the top; shellcode written into the data, where the
   kernel keeps its seed, and onto the stack, and run; a payload of 32 words and one of 33; the monitor, the M-mode stack,
   system SRAM, past the box; address 0, where there is no memory, read, written and run; `pmpcfg0`, `mstatus`, the counters, `mret`, `wfi`, `ebreak`, an illegal word, a misaligned
   load and store, unknown and unoffered syscalls; and clean halts with secrets in registers. Each ends parked and
   scrubbed with the cause and the `mtval` the PMP rule gives, refused by the PMP and not by the bus, and the code
   entry's bytes as loaded. Three of them --
   self-modifying code, and shellcode in the data and on the stack -- run to a clean HALT under exp236's monitor and are
   stopped by this one.
7. **Twenty-seven broken monitors** (`suite/broken_monitors.py`): `monitor.S` with one change -- each of the cases of
   check 3 that the emulator can see, the two entries in the wrong order, a fourth entry on, `mstatus` not written or
   `MPP` set to M-mode, a payload `sp` at the bottom of the stack, a register boot or the scrub forgets, a fault that does not scrub, saved words or `mscratch` left behind -- each must fail the
   hostile payloads or the rounds.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp240 — the code the box forbids writing ===
recorded at 2026-10-17T10:02:06Z from commit 0fb782a

>>> the micro-monitor binary and size budget
PASS  monitor.bin (600 bytes, 150 words) is monitor.S assembled, matches monitor.sha256, is within 200 words, and is proof/Wx.lean's monitorCode

>>> the formal theorems, and what they rest on
'Exp240.monitorCode_length' does not depend on any axioms
'Exp240.monitor_boot' depends on axioms: [propext, Quot.sound]
'Exp240.monitor_halt' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp240.monitor_fault_cause' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp240.monitor_fault_syscall' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp240.monitor_traps' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp240.payload_runs' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp240.monitor_end_to_end' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp240.monitor_reentry' depends on axioms: [propext, Quot.sound]
'Exp240.monitor_round_ready' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp240.monitor_rounds' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Priv.wx_fetch_iff' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Priv.wx_store_ok' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Priv.wx_load_ok' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Priv.pmpCheck_M_outside_in' depends on axioms: [propext, Quot.sound]
'Rv32.Priv.wx_step' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Priv.wx_run' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Priv.wx_code_immutable' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Priv.wx_no_write_exec' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong monitors, wrong claims and wrong models: each must be refused
code_entry_256_bytes               pmpaddr0 fences 256 bytes of code, not 128                                refused in monitor_boot_config
code_entry_64_bytes                pmpaddr0 fences 64 bytes: the last of the kernel's 76 is not executable   refused in monitor_boot_config
data_entry_8_kib                   pmpaddr1 fences 8 KiB of data, not 4                                      refused in monitor_boot_config
data_entry_2_kib                   pmpaddr1 fences 2 KiB of data, not 4                                      refused in monitor_boot_config
stack_entry_to_the_monitor         pmpaddr2 reaches down to 0x80000000                                       refused in monitor_boot_config
stack_entry_8_kib                  pmpaddr2 fences 8 KiB of stack: the guard region is 4 KiB short           refused in monitor_boot_config
code_entry_writable                the code entry is read, write and execute (0x1f)                          refused in monitor_boot_config
data_entry_executable              the data entry is read, write and execute (0x1f)                          refused in monitor_boot_config
stack_entry_executable             the stack entry is read, write and execute (0x1f)                         refused in monitor_boot_config
code_entry_off                     the code entry is off: the data entry alone, 4 KiB of read and write      refused in monitor_boot_config
entry_three_on                     entry 3 is on, NAPOT, read, write and execute                             refused in monitor_boot_config
entries_swapped                    the code and the data entries swap places: the data is tried first        refused in monitor_boot_config
mret_to_m_mode                     boot sets MPP to M-mode instead of clearing it                            refused in monitor_boot_config
payload_entry_wrong                boot sends the payload to 0x80020000, past its region                     refused in monitor_boot_config
payload_sp_wrong                   boot gives the payload an sp at the bottom of its region                  refused in monitor_launch_1
boot_leaves_x31                    boot loads 1 into x31 instead of zero                                     refused in monitor_launch_3
trap_vector_wrong                  boot points mtvec four bytes past the handler                             refused in monitor_boot_config
mscratch_wrong                     boot puts the M-mode stack in the payload's region                        refused in monitor_boot_config
no_stack_swap                      the handler keeps the payload's sp                                        refused in entry_1
cause_check_dropped                the handler never looks at mcause                                         refused in entry_mcause
syscall_check_dropped              the handler takes every ecall for HALT                                    refused in call_is_halt
fault_exit_code_two                a fault exits with 2                                                      refused in fault_6
fault_skips_scrub                  a fault jumps to the park loop, not the scrub                             refused in fault_6
saved_t0_stays                     the scrub leaves the saved t0 on the M-mode stack                         refused in scrub_1a
scrub_leaves_sp                    the scrub loads 1 into x2                                                 refused in regs_a
mmio_address_wrong                 the reports go to a word in the payload's region                          refused in fault_1
counters_start_at_three            claim: boot leaves the counters at 3, not 2                               refused in monitor_launch_5
halt_takes_56_steps                claim: a HALT takes the monitor 56 steps, not 57                          refused in monitor_traps
code_one_word_longer               claim: the code is four bytes longer, [0x80010000, 0x80010084)            refused in monitor_end_to_end
park_loop_one_word_on              claim: the park loop is one word on                                       refused in monitor_traps
sandbox_store_unchecked            U-mode stores skip the PMP check                                          refused in st_in_box
sandbox_ecall_passes               U-mode ecall is executed instead of trapped                               refused in trap_none_plain
pmp_entries_tried_backwards        the entries are tried from 3 down to 0, so the lowest does not win        refused in umode_default_deny
pmp_partial_match_passes           an access that straddles an entry's edge passes                           refused in pmpCheck_uboxed_iff
pmp_store_needs_read_not_write     a store needs the entry's R bit, not its W bit                            refused in pmpCheck_uboxed_iff
pmp_fetch_needs_read_not_execute   a fetch needs the entry's R bit, not its X bit                            refused in pmpCheck_uboxed_iff
pmp_unmatched_user_passes          U-mode that matches no entry passes                                       refused in umode_default_deny
lib_code_cfg_writable              the library's code entry has W set                                        refused in wx_store_ok
lib_data_cfg_executable            the library's data entry has X set                                        refused in wx_fetch_iff
lib_frozen_forgets_last_code_word  a byte in the last word of the code is not frozen                         refused in wx_code_immutable

>>> exp225's Rule 30 kernel, round after round, under the monitor
PASS  100 rounds of exp225's Rule 30 kernel under the monitor, 25600 generations, the kernel loaded once:
      each round: HALT 0, minstret 3081 = 3079 + 2, mcycle 3081; one trap, the ecall
      each round: the 1,024 bytes of history are rule30.py's, and the kernel run alone leaves the same
      each round: 256 KiB of RAM unchanged but for the history and the monitor's two stack words
      the code entry's 128 bytes the same after every round; the parked machine the same after every round
      SHA-256 of the 25600 generations: 53f14f5b390e205cf7a174142803e8d96adf274ed4b44397d8934b91c3a4bbe0
PASS  exp236's monitor, one RWX entry over the box, gives the same: the stricter box costs the kernel nothing

>>> payloads that write the code, run the data, and fall off the stack
PASS  52 payloads end parked and scrubbed, with the cause and the address the PMP rule gives:
      fault mcause=7 mtval=0x80010000      store into the code, first word
      fault mcause=7 mtval=0x8001007c      store into the code, last word
      fault mcause=7 mtval=0x8001007f      store into the code, last byte
      fault mcause=7 mtval=0x80010014      rewrite the next instruction (self-modifying code)
      fault mcause=7 mtval=0x80010040      store into the code with secrets in 20 registers
      halt  exit=0x0                       read the code
      halt  exit=0x0                       a payload of 32 words runs to its last word
      fault mcause=1 mtval=0x80010080      a payload of 33 words cannot fetch its 33rd
      halt  exit=0x0                       store into the data, first byte past the code
      halt  exit=0x0                       store into the data, last word
      fault mcause=1 mtval=0x80010080      run the data, first byte past the code
      fault mcause=1 mtval=0x80010400      write an ecall into the data and run it
      fault mcause=1 mtval=0x80010100      write an ecall where the kernel keeps its seed and run it
      fault mcause=7 mtval=0x80011000      store into the guard, first word
      fault mcause=5 mtval=0x80011000      load from the guard, first word
      fault mcause=1 mtval=0x80011000      run the guard
      fault mcause=7 mtval=0x8001effc      store into the guard, last word
      fault mcause=5 mtval=0x8001effc      load from the guard, last word
      halt  exit=0x0                       store into the stack, bottom word
      halt  exit=0x0                       store into the stack, top word
      fault mcause=7 mtval=0x8001eff0      overflow the stack by recursion
      fault mcause=5 mtval=0x80020000      underflow the stack: load past the top
      fault mcause=7 mtval=0x80020000      underflow the stack: store past the top
      fault mcause=1 mtval=0x8001fff0      write an ecall onto the stack and run it
      fault mcause=1 mtval=0x8001f000      run the stack
      fault mcause=7 mtval=0x80000000      store into the monitor's code
      fault mcause=5 mtval=0x80000000      load the monitor's code
      fault mcause=7 mtval=0x80008000      write the M-mode stack
      fault mcause=5 mtval=0x20000000      read system SRAM
      fault mcause=7 mtval=0x80020000      write past the box
      fault mcause=1 mtval=0x80000040      jump into the monitor
      fault mcause=1 mtval=0x80000130      jump to the trap vector
      fault mcause=2                       write pmpcfg0 to unlock the code
      fault mcause=2                       read pmpaddr0
      fault mcause=2                       set a bit in mstatus
      fault mcause=2                       read the cycle counter
      fault mcause=2                       write mscratch
      fault mcause=2                       mret to M-mode
      fault mcause=2                       wfi
      fault mcause=3                       ebreak
      fault mcause=2                       an illegal word
      fault mcause=4                       a misaligned load
      fault mcause=6                       a misaligned store
      fault mcause=8                       an unknown syscall
      fault mcause=8                       hash syscall (not offered)
      fault mcause=7 mtval=0x80000000      a fault with secrets in 20 registers
      halt  exit=0x7                       a clean halt with secrets in 20 registers
      fault mcause=2                       a fault with sp pointing into the monitor
      halt  exit=0x0                       the registers it starts with
      halt  exit=0x80020000                the stack pointer it starts with
      halt  exit=0x0                       a clean halt, exit code 0
      halt  exit=0x80000000                a clean halt, exit code 0x80000000
PASS  3 payloads that exp236's one RWX entry lets run are stopped by the three:
      exp236 halt exit=0x7; exp240 fault mcause=7 mtval=0x80010014  rewrite the next instruction (self-modifying code)
      exp236 halt exit=0x0; exp240 fault mcause=1 mtval=0x80010400  write an ecall into the data and run it
      exp236 halt exit=0x0; exp240 fault mcause=1 mtval=0x8001fff0  write an ecall onto the stack and run it

>>> monitors with one thing wrong: each must be caught
PASS  25 broken monitors, each caught by the hostile payloads or the rounds of Rule 30:
      code_entry_writable          the code entry is read, write and execute
      data_entry_executable        the data entry is read, write and execute
      stack_entry_executable       the stack entry is read, write and execute
      code_entry_off               the code entry is off
      data_entry_off               the data entry is off
      stack_entry_off              the stack entry is off
      code_entry_256_bytes         the code entry is 256 bytes: the data from +0x80 can be run
      code_entry_64_bytes          the code entry is 64 bytes: the end of the kernel cannot be fetched
      data_entry_8_kib             the data entry is 8 KiB: it reaches 4 KiB into the guard
      data_entry_2_kib             the data entry is 2 KiB: the top half of the data is not there
      stack_entry_8_kib            the stack entry is 8 KiB: the guard is 4 KiB short
      stack_entry_32_kib           the stack entry is 32 KiB: the guard is 28 KiB short
      stack_entry_to_the_monitor   the stack entry is 256 KiB from the monitor's base
      code_and_data_swapped        the code entry has the data's address and the data entry the code's
      data_tried_before_code       the data entry is tried first, so it decides a store into the code
      mret_stays_in_m_mode         mret returns to M-mode
      boot_leaves_a_register       boot does not zero x31 before the payload
      payload_sp_wrong             the payload's sp is the bottom of the stack entry, not the top
      no_stack_swap                the trap entry keeps the payload's sp
      scrub_skips_register         the scrub forgets x17
      scrub_skips_ra               the scrub forgets x1
      fault_does_not_scrub         a fault parks without scrubbing
      saved_words_stay             the saved t0 and t1 stay on the stack
      mscratch_stays               mscratch keeps the payload's sp
      any_syscall_halts            every ecall is taken for HALT

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  monitor.bin (600 bytes, 150 words) is monitor.S assembled, matches monitor.sha256, is within 200 words, and is proof/Wx.lean's monitorCode
PASS  Wx.lean checks, with no errors and no warnings
PASS  all 19 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  code_entry_256_bytes: the proof refuses a version where pmpaddr0 fences 256 bytes of code, not 128
PASS  code_entry_64_bytes: the proof refuses a version where pmpaddr0 fences 64 bytes: the last of the kernel's 76 is not executable
PASS  data_entry_8_kib: the proof refuses a version where pmpaddr1 fences 8 KiB of data, not 4
PASS  data_entry_2_kib: the proof refuses a version where pmpaddr1 fences 2 KiB of data, not 4
PASS  stack_entry_to_the_monitor: the proof refuses a version where pmpaddr2 reaches down to 0x80000000
PASS  stack_entry_8_kib: the proof refuses a version where pmpaddr2 fences 8 KiB of stack: the guard region is 4 KiB short
PASS  code_entry_writable: the proof refuses a version where the code entry is read, write and execute (0x1f)
PASS  data_entry_executable: the proof refuses a version where the data entry is read, write and execute (0x1f)
PASS  stack_entry_executable: the proof refuses a version where the stack entry is read, write and execute (0x1f)
PASS  code_entry_off: the proof refuses a version where the code entry is off: the data entry alone, 4 KiB of read and write
PASS  entry_three_on: the proof refuses a version where entry 3 is on, NAPOT, read, write and execute
PASS  entries_swapped: the proof refuses a version where the code and the data entries swap places: the data is tried first
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
PASS  mmio_address_wrong: the proof refuses a version where the reports go to a word in the payload's region
PASS  counters_start_at_three: the proof refuses a version where claim: boot leaves the counters at 3, not 2
PASS  halt_takes_56_steps: the proof refuses a version where claim: a HALT takes the monitor 56 steps, not 57
PASS  code_one_word_longer: the proof refuses a version where claim: the code is four bytes longer, [0x80010000, 0x80010084)
PASS  park_loop_one_word_on: the proof refuses a version where claim: the park loop is one word on
PASS  sandbox_store_unchecked: the proof refuses a version where U-mode stores skip the PMP check
PASS  sandbox_ecall_passes: the proof refuses a version where U-mode ecall is executed instead of trapped
PASS  pmp_entries_tried_backwards: the proof refuses a version where the entries are tried from 3 down to 0, so the lowest does not win
PASS  pmp_partial_match_passes: the proof refuses a version where an access that straddles an entry's edge passes
PASS  pmp_store_needs_read_not_write: the proof refuses a version where a store needs the entry's R bit, not its W bit
PASS  pmp_fetch_needs_read_not_execute: the proof refuses a version where a fetch needs the entry's R bit, not its X bit
PASS  pmp_unmatched_user_passes: the proof refuses a version where U-mode that matches no entry passes
PASS  lib_code_cfg_writable: the proof refuses a version where the library's code entry has W set
PASS  lib_data_cfg_executable: the proof refuses a version where the library's data entry has X set
PASS  lib_frozen_forgets_last_code_word: the proof refuses a version where a byte in the last word of the code is not frozen
PASS  proof/Wx.lean is what proof/gen.py writes
PASS  100 rounds of exp225's Rule 30 kernel under the monitor, 25600 generations, the kernel loaded once:
      each round: HALT 0, minstret 3081 = 3079 + 2, mcycle 3081; one trap, the ecall
      each round: the 1,024 bytes of history are rule30.py's, and the kernel run alone leaves the same
      each round: 256 KiB of RAM unchanged but for the history and the monitor's two stack words
      the code entry's 128 bytes the same after every round; the parked machine the same after every round
      SHA-256 of the 25600 generations: 53f14f5b390e205cf7a174142803e8d96adf274ed4b44397d8934b91c3a4bbe0
PASS  exp236's monitor, one RWX entry over the box, gives the same: the stricter box costs the kernel nothing
PASS  52 payloads end parked and scrubbed, with the cause and the address the PMP rule gives:
      fault mcause=7 mtval=0x80010000      store into the code, first word
      fault mcause=7 mtval=0x8001007c      store into the code, last word
      fault mcause=7 mtval=0x8001007f      store into the code, last byte
      fault mcause=7 mtval=0x80010014      rewrite the next instruction (self-modifying code)
      fault mcause=7 mtval=0x80010040      store into the code with secrets in 20 registers
      halt  exit=0x0                       read the code
      halt  exit=0x0                       a payload of 32 words runs to its last word
      fault mcause=1 mtval=0x80010080      a payload of 33 words cannot fetch its 33rd
      halt  exit=0x0                       store into the data, first byte past the code
      halt  exit=0x0                       store into the data, last word
      fault mcause=1 mtval=0x80010080      run the data, first byte past the code
      fault mcause=1 mtval=0x80010400      write an ecall into the data and run it
      fault mcause=1 mtval=0x80010100      write an ecall where the kernel keeps its seed and run it
      fault mcause=7 mtval=0x80011000      store into the guard, first word
      fault mcause=5 mtval=0x80011000      load from the guard, first word
      fault mcause=1 mtval=0x80011000      run the guard
      fault mcause=7 mtval=0x8001effc      store into the guard, last word
      fault mcause=5 mtval=0x8001effc      load from the guard, last word
      halt  exit=0x0                       store into the stack, bottom word
      halt  exit=0x0                       store into the stack, top word
      fault mcause=7 mtval=0x8001eff0      overflow the stack by recursion
      fault mcause=5 mtval=0x80020000      underflow the stack: load past the top
      fault mcause=7 mtval=0x80020000      underflow the stack: store past the top
      fault mcause=1 mtval=0x8001fff0      write an ecall onto the stack and run it
      fault mcause=1 mtval=0x8001f000      run the stack
      fault mcause=7 mtval=0x80000000      store into the monitor's code
      fault mcause=5 mtval=0x80000000      load the monitor's code
      fault mcause=7 mtval=0x80008000      write the M-mode stack
      fault mcause=5 mtval=0x20000000      read system SRAM
      fault mcause=7 mtval=0x80020000      write past the box
      fault mcause=1 mtval=0x80000040      jump into the monitor
      fault mcause=1 mtval=0x80000130      jump to the trap vector
      fault mcause=2                       write pmpcfg0 to unlock the code
      fault mcause=2                       read pmpaddr0
      fault mcause=2                       set a bit in mstatus
      fault mcause=2                       read the cycle counter
      fault mcause=2                       write mscratch
      fault mcause=2                       mret to M-mode
      fault mcause=2                       wfi
      fault mcause=3                       ebreak
      fault mcause=2                       an illegal word
      fault mcause=4                       a misaligned load
      fault mcause=6                       a misaligned store
      fault mcause=8                       an unknown syscall
      fault mcause=8                       hash syscall (not offered)
      fault mcause=7 mtval=0x80000000      a fault with secrets in 20 registers
      halt  exit=0x7                       a clean halt with secrets in 20 registers
      fault mcause=2                       a fault with sp pointing into the monitor
      halt  exit=0x0                       the registers it starts with
      halt  exit=0x80020000                the stack pointer it starts with
      halt  exit=0x0                       a clean halt, exit code 0
      halt  exit=0x80000000                a clean halt, exit code 0x80000000
PASS  3 payloads that exp236's one RWX entry lets run are stopped by the three:
      exp236 halt exit=0x7; exp240 fault mcause=7 mtval=0x80010014  rewrite the next instruction (self-modifying code)
      exp236 halt exit=0x0; exp240 fault mcause=1 mtval=0x80010400  write an ecall into the data and run it
      exp236 halt exit=0x0; exp240 fault mcause=1 mtval=0x8001fff0  write an ecall onto the stack and run it
PASS  25 broken monitors, each caught by the hostile payloads or the rounds of Rule 30:
      code_entry_writable          the code entry is read, write and execute
      data_entry_executable        the data entry is read, write and execute
      stack_entry_executable       the stack entry is read, write and execute
      code_entry_off               the code entry is off
      data_entry_off               the data entry is off
      stack_entry_off              the stack entry is off
      code_entry_256_bytes         the code entry is 256 bytes: the data from +0x80 can be run
      code_entry_64_bytes          the code entry is 64 bytes: the end of the kernel cannot be fetched
      data_entry_8_kib             the data entry is 8 KiB: it reaches 4 KiB into the guard
      data_entry_2_kib             the data entry is 2 KiB: the top half of the data is not there
      stack_entry_8_kib            the stack entry is 8 KiB: the guard is 4 KiB short
      stack_entry_32_kib           the stack entry is 32 KiB: the guard is 28 KiB short
      stack_entry_to_the_monitor   the stack entry is 256 KiB from the monitor's base
      code_and_data_swapped        the code entry has the data's address and the data entry the code's
      data_tried_before_code       the data entry is tried first, so it decides a store into the code
      mret_stays_in_m_mode         mret returns to M-mode
      boot_leaves_a_register       boot does not zero x31 before the payload
      payload_sp_wrong             the payload's sp is the bottom of the stack entry, not the top
      no_stack_swap                the trap entry keeps the payload's sp
      scrub_skips_register         the scrub forgets x17
      scrub_skips_ra               the scrub forgets x1
      fault_does_not_scrub         a fault parks without scrubbing
      saved_words_stay             the saved t0 and t1 stay on the stack
      mscratch_stays               mscratch keeps the payload's sp
      any_syscall_halts            every ecall is taken for HALT
```
