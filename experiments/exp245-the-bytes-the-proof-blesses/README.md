# exp245 — the bytes the proof blesses

<!-- SPDX-License-Identifier: Apache-2.0 -->

The design is in [`DESIGN.zh-TW.md`](./DESIGN.zh-TW.md) and the discussion in [`WHY.zh-TW.md`](./WHY.zh-TW.md). What
follows is what was built; where it differs from the design, it says so.

## Overview

Engineers in Tokyo buy Kanda Myojin's *IT情報安全守護* charm: a card and stickers for their machines, sold since 2002
([IT Leaders](https://it.impress.co.jp/articles/-/27423)). In Taiwan's server rooms, a green pack of *Kuai Kuai* sits on
top of the machines so the light stays green. Both are tokens of comfort against crashes, leaks and failures.

A proof becomes the same kind of token when it is read as a badge rather than as a conditional statement. This
experiment builds bytes that are fetched and executed, backed by Lean 4 theorems on Lean's own axioms, and guarded by
mutants that Lean refuses. They do nothing for what the payload can do, and **that is proved in Lean too**: next to each
charm's own theorem sits an *exposure theorem*, stated from reset, which says the charm changes nothing.

The monitor is [exp240](../exp240-the-code-the-box-forbids-writing/)'s, 151 words, with three charms added, 27 words, so
178 words, 712 bytes:

1. **The shrine seal** (18 words). Boot writes `0x4D414D4F` and `0x4941554B` at `0x80008010`, which read as the bytes
   `"OMAMKUAI"`. Before reporting a HALT, the handler checks both words and reports a FAULT if either differs.
   - *Charm theorems* `shrine_set_at_boot` and `halt_requires_shrine`: boot leaves the seal intact, and from **any**
     trap state an `ecall` with `t0 = 1` is a HALT with the payload's `a0` exactly when the seal is intact, and a FAULT
     with exit code 1 when it is not.
   - *Exposure* `shrine_always_intact`, `shrine_changes_nothing`: the shrine is outside the data and the stack, so the
     payload cannot write it, and boot writes it again every round. At every trap a round reaches the seal is intact,
     and the exit code is exp240's.
2. **The shadowed entry** (2 more words). Boot sets PMP entry 3 read-only over the seed window
   `[0x80010100, 0x80010200)`, with `pmpaddr3 = 0x2000405f` and `pmpcfg0 = 0x191b1b1d`.
   - *Charm theorems* `seed_entry_configured` and `entry3_forbids_seed_store`: after boot, entry 3 is NAPOT, read-only,
     over the window, and an access wholly inside the window is a full match of entry 3, whose permissions refuse a
     U-mode store.
   - *Exposure* `pmpCheck_shadowed`, in `lean/Rv32/WxBox.lean`, and `seed_store_allowed`: an entry 3 that lies wholly
     inside entry 1 never decides, because entry 1 is tried first; from reset, a U-mode store into the window passes.
3. **The ceremonial scrub** (7 words). Every exit zeroes a 32-byte slot at `[0x80010e00, 0x80010e20)` in the data.
   - *Charm theorem* `slot_zeroed_on_exit`: at the park loop the slot is zero, and every other byte but the monitor's
     stack and report words is as the payload left it.
   - *Exposure* `stack_reaches_next_round`: that frame, and boot's, carry the bytes the payload left on its stack at
     `[0x8001ffc0, 0x8001ffe0)` into the next round's payload.

Two of the three restate prior work on purpose. Entry order is exp240's `entries_swapped` and
`pmp_entries_tried_backwards`. A frame that keeps secrets is the shape of exp239's own `monitor_scrub`.

A fourth charm was in the first draft: a service call that reads its own request word back as a pass. It is discussed
in WHY §4 and not built. exp238 already discloses it, exp240 serves only HALT, and on the emulator those bytes actually
fail closed: the placebo there is the theorem, not the bytes.

"Does nothing" means *in exp240's model*: one hart, a U-mode payload, and the host's writes between rounds. Act 1b of
the emulator suite writes the seal from outside that model, standing for a DMA channel or the other core, and there the
check turns a HALT into a FAULT.

Needs: **no board** at all, and no USB anywhere in it. Nothing here ran on silicon or on the RTL.

## Documents in this directory

- [`WHY.zh-TW.md`](./WHY.zh-TW.md) — the charm and the Kuai Kuai, verification theater, why the fourth charm was
  dropped, and a checklist for reading a verification claim.
- [`DESIGN.zh-TW.md`](./DESIGN.zh-TW.md) — memory map, the assembly of each charm, the charm and exposure theorems, the
  mutants, and the emulator acts.

## What the monitor does

`monitor.S` is exp240's, word for word, with each charm marked: a block between `// [Charm N] {` and `// [Charm N] }` is
added, and a line ending `// [Charm N] exp240: X` is exp240's line `X` changed. `monitor.py` takes the marks away and
requires exp240's `monitor.bin` byte for byte with all three gone, and a different binary with any one gone alone.

```
0x80000040  _reset (boot, 71 steps)   exp240's boot, with entry 3 the seed window (pmpaddr3 0x2000405f,
                                      pmpcfg0 0x191b1b1d) [Charm 2], and after the CSRs the shrine's two
                                      words [Charm 1]; then the registers, mcountinhibit <- 0, mret
0x8000015c  trap_handler              exp240's
0x800001c0  the seal's check          both words, or the fault report [Charm 1]
0x800001e8  the HALT report           exp240's
0x80000210  scrub_exit                the saved words and mscratch, exp240's; then the slot zeroed
                                      [Charm 3]; then the registers and the exit word, exp240's
0x800002c0  halt_loop                 wfi, j halt_loop
```

Two places differ from the design, and neither changes what a charm does:

- **The shrine is written last of boot's CSRs**, before the registers, not right after `mscratch`. In the proof a run
  that steps on from a store needs a rewrite the model's `simp` does not reach in one pass; with the stores last, boot
  is two runs, each ending with one of them (`monitor_boot_config`, `monitor_boot_shrine`).
- **`pmpaddr3` is written where exp240 wrote it**, after `pmpcfg0`, not before. M-mode is not held to an entry that is
  not locked (`pmpCheck_M_unlocked`), so the order does not matter to the monitor, and the ablation stays a line for a
  line.

## What is proved

All on Lean's own axioms, in `proof/Bless.lean`, which `check.sh` holds against `monitor.S` assembled afresh. The proof
is exp240's at this monitor's addresses -- `tools/monitor/wx.py` writes both, and exp240's `Wx.lean` comes out of it
byte for byte -- with the charms' words added: two chunks for the seal's check, exp239's zeroing loop
(`chunks.zloop`) for the slot.

| theorem | says |
| :--- | :--- |
| `monitor_boot` | from reset (image loaded, `pc = 0x80000040`, M-mode, any CSRs that lock no PMP entry, any registers), 71 steps give `WXBoxed` with the three entries and entry 3 shadowed, `sp = 0x80020000`, every other register zero, the CSR file `csrsBooted`, and memory `shrined M0`: the shrine's two words written, every other byte as it was |
| `monitor_traps` | from the trap vector, whatever the payload left, five ways -- a HALT with the seal intact, the seal's first or second word wrong, an `ecall` for anything else, a fault -- `trapSteps` steps (95, 96, 100, 90, 87) to the park loop: `Parked` with `exitCode u`, the monitor's words in place, `SlotFrame`, the PMP as boot set it, the host having heard `trapIo u` |
| `payload_runs`, `monitor_end_to_end` | exp240's, for this binary: from reset, the payload boxed and its code the bytes it was loaded with, or trapped -- with the seal intact -- and parked |
| `monitor_reentry`, `ready_of_host`, `monitor_round_ready`, `monitor_rounds` | exp240's round after round: from any `Ready` machine a reset and boot leave the same CSRs and registers, and memory as it was but for the shrine, written again |
| `shrine_set_at_boot` | [Charm 1] `Sealed (shrined M0)`, whatever `M0` held there |
| `halt_requires_shrine` | [Charm 1] from **any** trap state, an `ecall` with `t0 = 1`: the seal intact, the host hears a HALT and `a0` is the payload's; the seal broken, a FAULT and `a0 = 1` |
| `shrine_always_intact`, `shrine_changes_nothing` | [Charm 1, exposed] at the first trap of every round from a `Ready` machine the seal is intact, so the exit code is exp240's |
| `seed_entry_configured`, `entry3_forbids_seed_store` | [Charm 2] after boot entry 3 is NAPOT, read-only, over `[0x80010100, 0x80010200)`; an access wholly inside it is entry 3's full match, and that refuses a U-mode store |
| `pmpCheck_shadowed` | [Charm 2, exposed] in the library: an entry 3 wholly inside entry 1 leaves `pmpCheck` the first three entries', for every privilege, address, width and access |
| `seed_store_allowed` | [Charm 2, exposed] from reset, a U-mode word store into the seed window passes the PMP |
| `slot_zeroed_on_exit` | [Charm 3] from the trap vector, whatever the payload did: the slot zero at the park loop, every other byte but the stack and report words as the payload left it |
| `stack_reaches_next_round` | [Charm 3, exposed] after a round, a reset and boot, the next payload starts with the bytes `[0x8001ffc0, 0x8001ffe0)` the last one left there at its trap |

`WXBoxed` in `lean/Rv32/WxBox.lean` now takes entry 3 off **or** shadowed (`Entry3Silent`), and every `wx_*` theorem of
exp240's holds for both: this monitor's box is exp240's box, which is the point of the second exposure.

## What is not proved, and what it rests on

Everything exp240's README says, for the same reasons; and:

- **The exposure theorems are about the model.** A writer the model does not have -- a DMA channel, the other core, a
  fault injected -- can change the shrine between boot and the trap. Act 1b does exactly that on the emulator, and the
  check then turns a HALT into a FAULT. Whether the chip has such a writer is a question about the threat model, not
  the proof.
- **`halt_requires_shrine` is true and says nothing about a round.** It is stated from any trap state, which is why
  Lean refuses `shrine_check_skipped`; `shrine_always_intact` says the states where the check would fire are not ones a
  round reaches.
- **The real fixes are not built**: the seed entry listed before the data entry, and a scrub of every byte U-mode can
  write (`wx_store_ok` names them: `[0x80010080, 0x80011000)` and `[0x8001f000, 0x80020000)`).

## The checks

1. `monitor.py --check`: `monitor.S` assembles to `monitor.bin` byte for byte, the SHA-256 matches, 178 ≤ 200 words,
   `monitorCode` is its words, and the charms taken away give exp240's `monitor.bin`.
2. `proof/Bless.lean` checks, every theorem it prints on Lean's own axioms.
3. **Sixty-eight mutants** (`proof/mutants.txt`, written by `gen.py`), each refused by Lean: thirteen of the charms --
   ten words and three claims that say more than a charm does (that an exit zeroes the stack, that the PMP refuses a
   store into the seed window, that a round reaches a broken seal) -- nine of exp240's ported to this monitor's words,
   and forty-six of exp240's as they are.
4. `proof/Bless.lean` and `proof/mutants.txt` are what `proof/gen.py` writes.
5. `suite/charms_audit.py`, on the emulator, reusing exp240's suite:
   - **Act 1a**: a payload overwrites its whole output and HALTs; the seal is intact.
   - **Act 1b**: the seal written from outside the model mid-run; exp245 FAULTs, exp240 HALTs.
   - **Act 2**: a store into the seed window goes in.
   - **Act 3**: a key left on the stack in round 1 is round 2's output, the slot zero at both parks.
   - **Act 4**: exp240, exp245 and exp245 with each charm taken away alone, under exp240's hostile payloads, Acts 1a,
     2 and 3, and 20 rounds of exp225's Rule 30 kernel: the same registers, reports, exit codes, traps and counters;
     memory different only in the monitor's words, the shrine and the slot, and entry 3 only where charm 2 is.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp245 — the bytes the proof blesses ===
recorded at 2026-10-24T15:36:09Z from commit 2756f54

>>> the micro-monitor binary, its size budget, and the charms taken away
PASS  monitor.bin (712 bytes, 178 words) is monitor.S assembled, matches monitor.sha256, is within 200 words, and is proof/Bless.lean's monitorCode
PASS  monitor.S with the three charms taken away is exp240's monitor.bin, byte for byte; each charm taken away alone changes the binary

>>> the formal theorems, and what they rest on
'Exp245.monitorCode_length' does not depend on any axioms
'Exp245.monitor_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp245.monitor_traps' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp245.payload_runs' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp245.monitor_end_to_end' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp245.ready_of_host' depends on axioms: [propext, Quot.sound]
'Exp245.monitor_reentry' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp245.monitor_round_ready' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp245.monitor_rounds' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp245.shrine_set_at_boot' depends on axioms: [propext, Quot.sound]
'Exp245.halt_requires_shrine' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp245.shrine_always_intact' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp245.shrine_changes_nothing' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp245.seed_entry_configured' depends on axioms: [propext, Quot.sound]
'Exp245.entry3_forbids_seed_store' depends on axioms: [propext, Quot.sound]
'Exp245.seed_store_allowed' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Priv.pmpCheck_shadowed' depends on axioms: [propext, Quot.sound]
'Exp245.slot_zeroed_on_exit' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp245.stack_reaches_next_round' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Priv.wx_store_allowed_data' depends on axioms: [propext, Quot.sound]
'Rv32.Priv.wx_run' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Priv.wx_code_immutable' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong monitors, wrong claims and wrong models: each must be refused
shrine_word0_typo                  [Charm 1] boot writes 0x4d414d4e for the shrine's first word                                                  refused in monitor_boot_config
shrine_kuai_yellow                 [Charm 1] the check compares the second word with 0x4941554c, not "KUAI"                                      refused in seal_2
shrine_check_skipped               [Charm 1] the check of the first word is a nop                                                                refused in seal_1
shrine_branch_inverted             [Charm 1] the check of the first word faults when it is right                                                 refused in seal_1
entry3_writable                    [Charm 2] entry 3 is read and write: cfg 0x1b                                                                 refused in monitor_boot_config
entry3_off                         [Charm 2] entry 3 is off: cfg 0x00, exp240's                                                                  refused in monitor_boot_config
entry3_window_escapes              [Charm 2] entry 3 covers the guard at 0x80011000, outside the data: it decides there                          refused in monitor_boot_config
slot_one_word_short                [Charm 3] the slot's end is 0x80010e1c: its last word is kept                                                 refused in slot_setup
slot_stores_pointer                [Charm 3] the loop stores its pointer, not zero                                                               refused in zstore_slot
slot_store_dropped                 [Charm 3] the loop runs and stores nothing: its sw is a nop                                                   refused in zstore_slot
claim_stack_scrubbed               claim: an exit zeroes the payload's stack at [0x8001ffc0, 0x8001ffe0), not the slot                           refused in slot_zeroed_on_exit
claim_entry3_decides               claim: from reset, the PMP refuses a U-mode store into the seed window                                        refused in seed_store_allowed
claim_shrine_reachable             claim: a round reaches a trap with the seal broken                                                            refused in shrine_always_intact
stack_entry_executable             the stack entry is read, write and execute (0x1f)                                                             refused in monitor_boot_config
stack_entry_off                    the stack entry is off                                                                                        refused in monitor_boot_config
entry_three_rwx                    entry 3 is read, write and execute                                                                            refused in monitor_boot_config
pmpaddr3_kept                      boot does not write pmpaddr3: it is whatever the last round left                                              refused in monitor_boot_config
trap_vector_wrong                  boot points mtvec four bytes past the handler                                                                 refused in monitor_boot_config
fault_skips_scrub                  a fault jumps to itself, not the scrub                                                                        refused in fault_6
scrub_skips_ra                     the scrub leaves x1                                                                                           refused in regs_a
halt_takes_94_steps                claim: a HALT takes the monitor 94 steps, not 95                                                              refused in monitor_traps
park_loop_one_word_on              claim: the park loop is one word on                                                                           refused in monitor_slot
code_entry_256_bytes               pmpaddr0 fences 256 bytes of code, not 128                                                                    refused in monitor_boot_config
code_entry_64_bytes                pmpaddr0 fences 64 bytes: the last of the kernel's 76 is not executable                                       refused in monitor_boot_config
data_entry_8_kib                   pmpaddr1 fences 8 KiB of data, not 4                                                                          refused in monitor_boot_config
data_entry_2_kib                   pmpaddr1 fences 2 KiB of data, not 4                                                                          refused in monitor_boot_config
stack_entry_to_the_monitor         pmpaddr2 reaches down to 0x80000000                                                                           refused in monitor_boot_config
stack_entry_8_kib                  pmpaddr2 fences 8 KiB of stack: the guard region is 4 KiB short                                               refused in monitor_boot_config
stack_entry_32_kib                 pmpaddr2 fences 32 KiB of stack: the guard region is 28 KiB short                                             refused in monitor_boot_config
code_entry_writable                the code entry is read, write and execute (0x1f)                                                              refused in monitor_boot_config
data_entry_executable              the data entry is read, write and execute (0x1f)                                                              refused in monitor_boot_config
code_entry_off                     the code entry is off: the data entry alone, 4 KiB of read and write                                          refused in monitor_boot_config
data_entry_off                     the data entry is off                                                                                         refused in monitor_boot_config
entries_swapped                    the code and the data entries swap places: the data is tried first                                            refused in monitor_boot_config
data_tried_before_code             the entries swap places and permissions: the data entry is tried first, so it decides a store into the code   refused in monitor_boot_config
mstatus_kept                       boot ORs t0 into mstatus instead of writing it whole: MPP is whatever the last round left                     refused in monitor_boot_config
mcause_kept                        boot does not write mcause: it is whatever the last round left                                                refused in monitor_boot_config
payload_entry_wrong                boot sends the payload to 0x80020000, past its region                                                         refused in monitor_boot_config
payload_sp_wrong                   boot gives the payload an sp at the bottom of its region                                                      refused in monitor_launch_1
boot_leaves_x31                    boot loads 1 into x31 instead of zero                                                                         refused in monitor_launch_3
mscratch_wrong                     boot puts the M-mode stack in the payload's region                                                            refused in monitor_boot_config
no_stack_swap                      the handler keeps the payload's sp                                                                            refused in entry_1
cause_check_dropped                the handler never looks at mcause                                                                             refused in entry_mcause
syscall_check_dropped              the handler takes every ecall for HALT                                                                        refused in call_is_halt
fault_exit_code_two                a fault exits with 2                                                                                          refused in fault_6
saved_t0_stays                     the scrub leaves the saved t0 on the M-mode stack                                                             refused in scrub_1a
scrub_leaves_sp                    the scrub loads 1 into x2                                                                                     refused in regs_a
mscratch_stays                     the scrub leaves mscratch holding the payload's sp                                                            refused in scrub_ms
mmio_address_wrong                 the reports go to a word in the payload's region                                                              refused in fault_1
halt_tag_wrong                     the HALT report's tag is "HALU", not "HALT": the host hears a report that is not HALT                         refused in halt_1
fault_tag_wrong                    the FAULT report's tag is "FAUM", not "FAUL"                                                                  refused in fault_1
exit_code_to_print_word            the exit code goes to the print word, not the exit word                                                       refused in regs_port
counters_start_at_three            claim: boot leaves the counters at 3, not 2                                                                   refused in monitor_launch_5
code_one_word_longer               claim: the code is four bytes longer, [0x80010000, 0x80010084)                                                refused in monitor_end_to_end
ready_allows_a_lock                claim: a round may start with a PMP entry locked                                                              refused in ready_of_host
host_may_write_code                claim: the host may write the code between rounds                                                             refused in ready_of_host
host_may_lock                      claim: the host may lock a PMP entry between rounds                                                           refused in ready_of_host
sandbox_store_unchecked            U-mode stores skip the PMP check                                                                              refused in st_in_box
sandbox_ecall_passes               U-mode ecall is executed instead of trapped                                                                   refused in trap_none_plain
pmp_entries_tried_backwards        the entries are tried from 3 down to 0, so the lowest does not win                                            refused in umode_default_deny
pmp_partial_match_passes           an access that straddles an entry's edge passes                                                               refused in pmpCheck_uboxed_iff
pmp_store_needs_read_not_write     a store needs the entry's R bit, not its W bit                                                                refused in pmpCheck_uboxed_iff
pmp_fetch_needs_read_not_execute   a fetch needs the entry's R bit, not its X bit                                                                refused in pmpCheck_uboxed_iff
pmp_unmatched_user_passes          U-mode that matches no entry passes                                                                           refused in umode_default_deny
lib_code_cfg_writable              the library's code entry has W set                                                                            refused in wx_store_ok
lib_data_cfg_executable            the library's data entry has X set                                                                            refused in wx_fetch_iff
lib_frozen_forgets_last_code_word  a byte in the last word of the code is not frozen                                                             refused in wx_code_immutable
pmp_m_mode_held_to_entries         M-mode is held to the entries as U-mode is, locked or not                                                     refused in pmpCheck_M_unlocked

>>> the charms on the emulator: what each theorem says, and what each charm does
PASS  Act 1a, the shrine seal: a payload overwrites its whole output [0x80010200, 0x80010600) and HALTs 0;
      the theorem's conclusion holds -- the seal reads "OMAMKUAI", the HALT is reported -- and that is all it
      says: the 8 bytes it checks are the monitor's own, and the payload's output was never among them
PASS  Act 1b, the shrine seal from outside the model: 200 steps into the payload the suite writes "YELL"
      over "KUAI" at 0x80008014, standing for a DMA channel or the other core. exp245: FAULT, mcause 8
      (the ecall), a0 = 1; exp240, the same write: HALT 0. Without the write, exp245 HALTs 0. The one place a
      charm does anything, and the writer is not in the model the theorems are about
PASS  Act 2, the shadowed entry: entry 3 as booted is NAPOT, read-only, over [0x80010100, 0x80010200) -- the
      theorem's conclusion -- and a payload stores 0x5eed5eed at 0x80010100, reads it back and HALTs with it:
      HALT 0x5eed5eed, one trap, the ecall. Entry 1, the data, is tried first and lets the store in
PASS  Act 3, the ceremonial scrub: round 1 leaves a key of eight words at [0x8001ffc0, 0x8001ffe0) on its
      stack and HALTs 0; the host writes one word in the data; round 2, the same payload, copies the stack to
      0x80010900 and HALTs 0. The slot [0x80010e00, 0x80010e20) is zero at both parks -- the theorem's
      conclusion -- and round 2's output is round 1's key: 0x6b657930 .. 0x6b657937
PASS  Act 4, the ablation: exp240, exp245, and exp245 with each charm taken away alone, under 55 hostile
      payloads, Acts 1a, 2 and 3, and 20 rounds of exp225's Rule 30 kernel: the registers, the reports and
      the exit codes, the traps, the counters and every CSR the payload's box is made of are the same for
      all five; memory differs only in the monitor's words, the shrine if charm 1 is there and the slot if
      charm 3 is; entry 3 differs only if charm 2 is

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  monitor.bin (712 bytes, 178 words) is monitor.S assembled, matches monitor.sha256, is within 200 words, and is proof/Bless.lean's monitorCode
PASS  monitor.S with the three charms taken away is exp240's monitor.bin, byte for byte; each charm taken away alone changes the binary
PASS  Bless.lean checks, with no errors and no warnings
PASS  all 22 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  shrine_word0_typo: the proof refuses a version where [Charm 1] boot writes 0x4d414d4e for the shrine's first word
PASS  shrine_kuai_yellow: the proof refuses a version where [Charm 1] the check compares the second word with 0x4941554c, not "KUAI"
PASS  shrine_check_skipped: the proof refuses a version where [Charm 1] the check of the first word is a nop
PASS  shrine_branch_inverted: the proof refuses a version where [Charm 1] the check of the first word faults when it is right
PASS  entry3_writable: the proof refuses a version where [Charm 2] entry 3 is read and write: cfg 0x1b
PASS  entry3_off: the proof refuses a version where [Charm 2] entry 3 is off: cfg 0x00, exp240's
PASS  entry3_window_escapes: the proof refuses a version where [Charm 2] entry 3 covers the guard at 0x80011000, outside the data: it decides there
PASS  slot_one_word_short: the proof refuses a version where [Charm 3] the slot's end is 0x80010e1c: its last word is kept
PASS  slot_stores_pointer: the proof refuses a version where [Charm 3] the loop stores its pointer, not zero
PASS  slot_store_dropped: the proof refuses a version where [Charm 3] the loop runs and stores nothing: its sw is a nop
PASS  claim_stack_scrubbed: the proof refuses a version where claim: an exit zeroes the payload's stack at [0x8001ffc0, 0x8001ffe0), not the slot
PASS  claim_entry3_decides: the proof refuses a version where claim: from reset, the PMP refuses a U-mode store into the seed window
PASS  claim_shrine_reachable: the proof refuses a version where claim: a round reaches a trap with the seal broken
PASS  stack_entry_executable: the proof refuses a version where the stack entry is read, write and execute (0x1f)
PASS  stack_entry_off: the proof refuses a version where the stack entry is off
PASS  entry_three_rwx: the proof refuses a version where entry 3 is read, write and execute
PASS  pmpaddr3_kept: the proof refuses a version where boot does not write pmpaddr3: it is whatever the last round left
PASS  trap_vector_wrong: the proof refuses a version where boot points mtvec four bytes past the handler
PASS  fault_skips_scrub: the proof refuses a version where a fault jumps to itself, not the scrub
PASS  scrub_skips_ra: the proof refuses a version where the scrub leaves x1
PASS  halt_takes_94_steps: the proof refuses a version where claim: a HALT takes the monitor 94 steps, not 95
PASS  park_loop_one_word_on: the proof refuses a version where claim: the park loop is one word on
PASS  code_entry_256_bytes: the proof refuses a version where pmpaddr0 fences 256 bytes of code, not 128
PASS  code_entry_64_bytes: the proof refuses a version where pmpaddr0 fences 64 bytes: the last of the kernel's 76 is not executable
PASS  data_entry_8_kib: the proof refuses a version where pmpaddr1 fences 8 KiB of data, not 4
PASS  data_entry_2_kib: the proof refuses a version where pmpaddr1 fences 2 KiB of data, not 4
PASS  stack_entry_to_the_monitor: the proof refuses a version where pmpaddr2 reaches down to 0x80000000
PASS  stack_entry_8_kib: the proof refuses a version where pmpaddr2 fences 8 KiB of stack: the guard region is 4 KiB short
PASS  stack_entry_32_kib: the proof refuses a version where pmpaddr2 fences 32 KiB of stack: the guard region is 28 KiB short
PASS  code_entry_writable: the proof refuses a version where the code entry is read, write and execute (0x1f)
PASS  data_entry_executable: the proof refuses a version where the data entry is read, write and execute (0x1f)
PASS  code_entry_off: the proof refuses a version where the code entry is off: the data entry alone, 4 KiB of read and write
PASS  data_entry_off: the proof refuses a version where the data entry is off
PASS  entries_swapped: the proof refuses a version where the code and the data entries swap places: the data is tried first
PASS  data_tried_before_code: the proof refuses a version where the entries swap places and permissions: the data entry is tried first, so it decides a store into the code
PASS  mstatus_kept: the proof refuses a version where boot ORs t0 into mstatus instead of writing it whole: MPP is whatever the last round left
PASS  mcause_kept: the proof refuses a version where boot does not write mcause: it is whatever the last round left
PASS  payload_entry_wrong: the proof refuses a version where boot sends the payload to 0x80020000, past its region
PASS  payload_sp_wrong: the proof refuses a version where boot gives the payload an sp at the bottom of its region
PASS  boot_leaves_x31: the proof refuses a version where boot loads 1 into x31 instead of zero
PASS  mscratch_wrong: the proof refuses a version where boot puts the M-mode stack in the payload's region
PASS  no_stack_swap: the proof refuses a version where the handler keeps the payload's sp
PASS  cause_check_dropped: the proof refuses a version where the handler never looks at mcause
PASS  syscall_check_dropped: the proof refuses a version where the handler takes every ecall for HALT
PASS  fault_exit_code_two: the proof refuses a version where a fault exits with 2
PASS  saved_t0_stays: the proof refuses a version where the scrub leaves the saved t0 on the M-mode stack
PASS  scrub_leaves_sp: the proof refuses a version where the scrub loads 1 into x2
PASS  mscratch_stays: the proof refuses a version where the scrub leaves mscratch holding the payload's sp
PASS  mmio_address_wrong: the proof refuses a version where the reports go to a word in the payload's region
PASS  halt_tag_wrong: the proof refuses a version where the HALT report's tag is "HALU", not "HALT": the host hears a report that is not HALT
PASS  fault_tag_wrong: the proof refuses a version where the FAULT report's tag is "FAUM", not "FAUL"
PASS  exit_code_to_print_word: the proof refuses a version where the exit code goes to the print word, not the exit word
PASS  counters_start_at_three: the proof refuses a version where claim: boot leaves the counters at 3, not 2
PASS  code_one_word_longer: the proof refuses a version where claim: the code is four bytes longer, [0x80010000, 0x80010084)
PASS  ready_allows_a_lock: the proof refuses a version where claim: a round may start with a PMP entry locked
PASS  host_may_write_code: the proof refuses a version where claim: the host may write the code between rounds
PASS  host_may_lock: the proof refuses a version where claim: the host may lock a PMP entry between rounds
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
PASS  pmp_m_mode_held_to_entries: the proof refuses a version where M-mode is held to the entries as U-mode is, locked or not
PASS  proof/Bless.lean and proof/mutants.txt are what proof/gen.py writes
PASS  Act 1a, the shrine seal: a payload overwrites its whole output [0x80010200, 0x80010600) and HALTs 0;
      the theorem's conclusion holds -- the seal reads "OMAMKUAI", the HALT is reported -- and that is all it
      says: the 8 bytes it checks are the monitor's own, and the payload's output was never among them
PASS  Act 1b, the shrine seal from outside the model: 200 steps into the payload the suite writes "YELL"
      over "KUAI" at 0x80008014, standing for a DMA channel or the other core. exp245: FAULT, mcause 8
      (the ecall), a0 = 1; exp240, the same write: HALT 0. Without the write, exp245 HALTs 0. The one place a
      charm does anything, and the writer is not in the model the theorems are about
PASS  Act 2, the shadowed entry: entry 3 as booted is NAPOT, read-only, over [0x80010100, 0x80010200) -- the
      theorem's conclusion -- and a payload stores 0x5eed5eed at 0x80010100, reads it back and HALTs with it:
      HALT 0x5eed5eed, one trap, the ecall. Entry 1, the data, is tried first and lets the store in
PASS  Act 3, the ceremonial scrub: round 1 leaves a key of eight words at [0x8001ffc0, 0x8001ffe0) on its
      stack and HALTs 0; the host writes one word in the data; round 2, the same payload, copies the stack to
      0x80010900 and HALTs 0. The slot [0x80010e00, 0x80010e20) is zero at both parks -- the theorem's
      conclusion -- and round 2's output is round 1's key: 0x6b657930 .. 0x6b657937
PASS  Act 4, the ablation: exp240, exp245, and exp245 with each charm taken away alone, under 55 hostile
      payloads, Acts 1a, 2 and 3, and 20 rounds of exp225's Rule 30 kernel: the registers, the reports and
      the exit codes, the traps, the counters and every CSR the payload's box is made of are the same for
      all five; memory differs only in the monitor's words, the shrine if charm 1 is there and the slot if
      charm 3 is; entry 3 differs only if charm 2 is
```
