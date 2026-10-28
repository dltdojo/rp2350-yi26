# exp257 — the bits the chip transposes

<!-- SPDX-License-Identifier: Apache-2.0 -->

## Overview

The second of three rounds on the audit's G4. [exp256](../exp256-the-readings-the-rtl-settles/), the first, held the
Tier 2 model to the emulator and to the Hazard3 RTL, and wrote down what the RP2350 does that no reader here had:
erratum RP2350-E6, eleven PMP regions where the model has four, three of them hardwired, and `PMPCFGM0`. Every
monitor theorem is about a PMP that is not the chip's.

This round does three things:

- **The model's own mistakes, fixed** ([`lean/Rv32/Priv.lean`](../../lean/Rv32/Priv.lean)): `ebreak` is a breakpoint
  (cause 3); a Tier 1 fault inside Tier 2 is the access fault it is; a U-mode `wfi` sleeps while `mstatus.TW` is
  clear, as the RTL and the datasheet say, and traps when it is set. Every proof that stands on the model is
  re-proved.
- **The RP2350's PMP, as a model of its own** ([`lean/Rv32/PmpChip.lean`](../../lean/Rv32/PmpChip.lean)), and a
  bridge theorem, `chip_eq_model`: when the chip's registers are *bridged* to the model's, the chip decides every
  access exactly as `Priv.pmpCheck` does. A monitor theorem on the model is then a theorem on the chip.
- **The core the RP2350 was built from**, as a third testbench, `tb_e6-rp2350`: Hazard3 at fce1c08, the commit before
  upstream fixed E6, with the datasheet's Table 387 parameters one for one. The chip model is held to it in E6's
  order, and to the pinned core in the specification's.

Needs: **no board** at all, and no USB anywhere in it. No firmware of its own. Nothing here ran on silicon.

## How this was decided

1. **The facts.**
   - Hazard3's history has the fix for E6 as commit 7d37029. Its parent, fce1c08, is the last core with R and X
     transposed. It runs under the pinned commit's testbench, less five ports it does not have yet
     ([`tb_e6.sed`](../../tools/hazard3/tb_e6.sed)), and three of its default parameters are rewritten so that
     Verilator 5.020 accepts them ([`hdl_e6.sed`](../../tools/hazard3/hdl_e6.sed)); no value the RP2350 configures
     changes.
   - Both cores' `hazard3_pmp.v` say what a write keeps: TOR and NA4 become OFF, an address register's two low bits
     are set (the 32-byte grain), PMPCFGM0's bits for the hardwired regions are dropped. Their access checks differ
     in one place besides E6: the old core refuses a fetch that straddles two regions, which an aligned 32-bit fetch
     never does.
   - The testbench's memory is at `0x80000000`. Anything else is a bus fault, whose `mcause` is the PMP's.
2. **What was already answered.**
   - exp256 found the model's three mistakes, and recorded E6, the regions and PMPCFGM0 from the datasheet.
   - **exp209 found, on a Pico 2, that PMP entry 0 does not read back as the shell wrote it**, where the RTL it was
     held to does. Nothing here explained it until now (below).
   - `Priv.lean`'s `readPmpAddr` says it models that quirk. It models the pinned RTL, which passes exp209's check.
3. **The contradictions.**
   - **A chip model or the model changed.** Changing `Priv.pmpCheck` to the chip's would re-open every monitor proof
     at once, and the chip's model would be proved about only through them. A separate model with a bridge keeps
     every theorem as it is and says exactly what a monitor must write for it to hold on the chip.
   - **The RTL cannot see the hardwired regions.** They match the ROM, the peripherals and SIO, where the testbench
     has nothing; the PMP letting an access through and refusing it both report `mcause` 5. Their registers are read
     back instead, and the mutants that only they could refuse are named as such.
4. **What was decided without asking.**
   - **Each order to its own core, and to the other.** A differential that cannot tell the two orders apart has not
     tested either, so the cross pairing must disagree somewhere.
   - **Locked cases run alone.** A lock outlives the case and binds the driver, so each runs from reset.
   - **The loop that builds a wrong model and asks a differential about it** was exp256's; this round needed it
     second, so it is [`tools/monitor/privmutants.py`](../../tools/monitor/privmutants.py) now, and both use it.
5. **What was asked**, and answered:
   - a separate chip model and a bridge theorem; `Priv.lean` fixed only where it was wrong;
   - the pre-fix RTL added, as the referee for E6.

## What was found

### The fixed model, against the emulator and the RTL

exp256's differential, run again on the fixed model: the 40 `ebreak` runs and the 4 `outside_region` runs now agree
with the emulator. **7,066 of 7,085 runs agree at every step.** The other 19 are one kind, `wfi_sleeps`: the model
sleeps on a U-mode `wfi`, as the RTL does in the same 19 runs, and the emulator traps it. Of exp256's probes, two
readings moved from "not the RTL's" to the RTL's: `ebreak` in U-mode, and `wfi` with TW clear. `mstatus` written all
ones now keeps TW, and still lacks MPRV.

### The chip's PMP, against two cores

[`differential/pmpdiff.py`](./differential/pmpdiff.py): 4,400 cases, 400 of them locked, each from reset.

| `chipCheck` in | held to | cases that differ |
| :--- | :--- | ---: |
| E6's order | `tb_e6-rp2350`, the chip's core | **0** |
| the specification's | `tb-rp2350`, the pinned core | **0** |
| E6's order | `tb-rp2350` | 658 |
| the specification's | `tb_e6-rp2350` | 658 |

Every case is a configuration of all eight dynamic entries and PMPCFGM0, and one access under it. The entries are
NAPOT regions of 32 bytes to 256 KiB, all of memory, or any word at all. Each has any A, any permissions and any
reserved bits. Every privilege, access kind and outcome occurs (the capture lists them).

### What the two cores read back

[`probes/probes.py`](./probes/probes.py): exp256's twenty-three probes and five more, on both cores. Seven readings
differ:

| probe | `tb_e6-rp2350` | `tb-rp2350` |
| :--- | :--- | :--- |
| `misa` | `0x40901105` | `0x40901107`: B as well |
| `pmpaddr1` written `0x20004000`, NAPOT, then OFF | `0x20004000`, then `0x20004003` | `0x20004003`, then `0x20004000` |
| `pmpaddr4`, never written, OFF | 3 | 0 |
| an execute-only entry (`0x1c`), fetch | fetch refused | fetch allowed, load refused |
| `0x1b` over U-mode's code, load | fetch allowed, load refused | fetch refused |
| `0x1e` over U-mode's code, run | fetch refused | runs |
| exp209's check 2: pmpcfg0's byte, pmpaddr0 xor what was written | `0x1f`, **3** | `0x1f`, 0 |

The hardwired regions' registers read the same on both: `0x01ffffff`, `0x13ffffff`, `0x35ffffff`, `pmpcfg2`
`0x001f1f1f`. PMPCFGM0 written all ones keeps `0xff` on both.

**The old core reads an address register's low bits the other way round.** Its source says the two low bits read as
zero when OFF and one when NAPOT; its logic does the opposite (`hazard3_pmp.v` at fce1c08, `cfg_read`). That is
exp209's check 2 failing. exp209's shell wrote a 64 KiB NAPOT entry and read it back; the old core returns it with
the two low bits clear, and the pinned core returns it as written. The board said the check failed and the RTL said
it passed — what each core does. The board never said which bits differed, so this is consistent with exp209, not
proved by it. Round 3's board probe can say.

### The bridge, and exp240's box on the chip

[`proof/Chip.lean`](./proof/Chip.lean):

- **`exp240_on_the_chip`**: exp240's box written in the chip's order is bridged to the box exp240 proved:
  - code `0x1d`;
  - data and stack `0x1e`;
  - entry 4 `0x18` over all of memory, granting nothing.

  On the chip it decides every access, by either privilege, as exp240's model does.
- **Each condition of the bridge is needed**:
  - `needs_order`: exp240's own bytes on the chip refuse U-mode its seed;
  - `needs_deny`: without entry 4, U-mode loads from the peripherals;
  - `needs_unlocked`, `needs_m0`: entry 4 locked, or bound to M-mode by PMPCFGM0, refuses M-mode its own memory.

## What it means for the proofs

- **Every proof on the model is re-proved** against the fixed `Priv.lean`, unchanged in what it claims: no monitor here
  executes `ebreak`, lets a payload past the PMP, or reaches a sleeping `wfi` in a theorem.
- **No monitor here is yet proved on the chip.** exp236 to exp239 write one RWX entry and leave 4 to 7 alone; exp240
  writes `0x1b`. Neither is bridged. Round 3 writes each monitor's bytes in the chip's order, adds entry 4, sets
  `mstatus.TW` (a payload's `wfi` hangs the monitor otherwise), drops the `csrs = {}` hypotheses for Hazard3's
  reset, and re-proves. `exp240_on_the_chip` is that change for exp240, made on the PMP alone.
- **The fixed `wfi` is not liveness.** A payload's `wfi` now sleeps in the model, as on the RTL; no theorem says a
  monitor wakes.

## What is not checked, and what it rests on

- **Neither core is the chip.** fce1c08 is the closest commit to the RP2350's core that upstream published with E6 in
  it. Its parameters are Table 387's. Nothing here says the chip's netlist is this commit.
- **The hardwired regions' matching is not tested**, only their registers. Two wrong models are invisible for that
  reason: PMPCFGM0 binding M-mode to a hardwired region, and a hardwired region over other addresses.
- **Readback is not modelled.** `chipCheck` decides accesses; what software reads back from the address registers is
  recorded by the probes, not by a model.
- **Accesses are aligned.** A misaligned access traps before the PMP is asked, and a 32-byte grain never splits an
  aligned access. The old core's straddling-fetch rule is not reached.

## The checks

1. **`proof/Chip.lean`**: the six theorems above, on Lean's axioms only.
2. **`proof/mutants.txt`**: nine wrong versions, each refused by Lean:
   - exp240's box with its own bytes;
   - entry 4 granting everything, locked, bound to M-mode, or over half of memory;
   - `needs_order` reversed;
   - the bridge loosened three ways, in `PmpChip.lean` itself.
3. **`privrun` builds**, with `--pmp`.
4. **`differential/pmpdiff.py`**: the table above: both orders agree with their own core on every case, and differ
   from the other core somewhere.
5. **`probes/probes.py --check`**: both cores read back what `probes/table.txt` recorded.
6. **`model/mutants.py`**: eight wrong chip models, each refused by the differential:
   - E6 ignored, and E6 everywhere;
   - the grain ignored;
   - the two top bits of an address kept;
   - TOR and NA4 matched as NAPOT;
   - locks ignored;
   - PMPCFGM0 ignored;
   - unmatched U-mode let through.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp257 — the bits the chip transposes ===
recorded at 2026-10-28T00:46:36Z from commit 35a0324

>>> twenty-eight probes, two cores: what each reads back
probe                core          words printed
mstatus_reset        tb_e6-rp2350  00001800
                     tb-rp2350     00001800
mcountinhibit_reset  tb_e6-rp2350  00000005
                     tb-rp2350     00000005
ebreak_u             tb_e6-rp2350  54524150 00000003 00000060
                     tb-rp2350     54524150 00000003 00000060
fence_m              tb_e6-rp2350  00000001
                     tb-rp2350     00000001
misa_m               tb_e6-rp2350  40901105   <- not tb-rp2350's
                     tb-rp2350     40901107
mhartid_m            tb_e6-rp2350  00000000
                     tb-rp2350     00000000
mtvec_bit0           tb_e6-rp2350  800000a5
                     tb-rp2350     800000a5
mtvec_bit1           tb_e6-rp2350  800000a4
                     tb-rp2350     800000a4
mpp_01               tb_e6-rp2350  00000000
                     tb-rp2350     00000000
mstatus_ones         tb_e6-rp2350  00221888
                     tb-rp2350     00221888
mcountinhibit_ones   tb_e6-rp2350  00000005
                     tb-rp2350     00000005
pmpaddr_napot        tb_e6-rp2350  20004000 20004003   <- not tb-rp2350's
                     tb-rp2350     20004003 20004000
pmpcfg_tor           tb_e6-rp2350  0000071f
                     tb-rp2350     0000071f
pmpcfg_na4           tb_e6-rp2350  0000071f
                     tb-rp2350     0000071f
pmpcfg1              tb_e6-rp2350  00000000
                     tb-rp2350     00000000
pmpaddr4             tb_e6-rp2350  00000003   <- not tb-rp2350's
                     tb-rp2350     00000000
pmpcfgm0             tb_e6-rp2350  00000000
                     tb-rp2350     00000000
counted_mret         tb_e6-rp2350  54524150 00000008 00000060 00000015
                     tb-rp2350     54524150 00000008 00000060 00000015
lock_m               tb_e6-rp2350  54524150 00000007 0000005c
                     tb-rp2350     54524150 00000007 0000005c
x_only               tb_e6-rp2350  54524150 00000001 00000080   <- not tb-rp2350's
                     tb-rp2350     54524150 00000005 00000084
u_peripheral         tb_e6-rp2350  54524150 00000005 00000064
                     tb-rp2350     54524150 00000005 00000064
wfi_u_tw             tb_e6-rp2350  54524150 00000002 00000060
                     tb-rp2350     54524150 00000002 00000060
wfi_u                tb_e6-rp2350   hangs
                     tb-rp2350      hangs
hardwired            tb_e6-rp2350  01ffffff 13ffffff 35ffffff 001f1f1f
                     tb-rp2350     01ffffff 13ffffff 35ffffff 001f1f1f
cfg_1b               tb_e6-rp2350  54524150 00000005 00000084   <- not tb-rp2350's
                     tb-rp2350     54524150 00000001 00000080
cfg_1e               tb_e6-rp2350  54524150 00000001 00000080   <- not tb-rp2350's
                     tb-rp2350     54524150 00000008 00000084
exp209_check2        tb_e6-rp2350  0000001f 00000003   <- not tb-rp2350's
                     tb-rp2350     0000001f 00000000
pmpcfgm0_ones        tb_e6-rp2350  000000ff
                     tb-rp2350     000000ff

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  Chip.lean checks, with no errors and no warnings
PASS  all 6 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  bytes_as_written: the proof refuses a version where exp240's bytes as it writes them, 0x1b, are bridged on the chip
PASS  deny_grants: the proof refuses a version where entry 4 granting everything is bridged
PASS  deny_locked: the proof refuses a version where entry 4 locked is bridged
PASS  deny_bound: the proof refuses a version where entry 4 bound to M-mode by PMPCFGM0 is bridged
PASS  deny_half: the proof refuses a version where entry 4 over half of memory is bridged
PASS  order_not_needed: the proof refuses a version where claim: exp240's own bytes on the chip let U-mode load its seed
PASS  bridge_m0_four: the proof refuses a version where the bridge lets PMPCFGM0 bind entry 4
PASS  bridge_deny_mode: the proof refuses a version where the bridge asks only that entry 4 be NAPOT, not that it grant nothing
PASS  bridge_deny_half: the proof refuses a version where the bridge lets entry 4 cover half of memory
PASS  privrun builds: PrivMachine.step and, with --pmp, PmpChip.chipCheck, compiled, from lean/PrivExec.lean
PASS  chipCheck .e6 decides as tb_e6-rp2350 on all 4400 cases (400 of them locked, each from reset)
PASS  chipCheck .standard decides as tb-rp2350 on all 4400 cases (400 of them locked, each from reset)
PASS  chipCheck .e6 differs from tb-rp2350 on 658 cases
PASS  chipCheck .standard differs from tb_e6-rp2350 on 658 cases
      what the cases came to on tb_e6-rp2350, by privilege, access and mcause:
        M F  1  18
        M F 11  327
        M l  5  37
        M l 11  907
        M s  7  51
        M s 11  860
        U F  1  200
        U F  8  112
        U l  1  152
        U l  5  531
        U l  8  235
        U s  1  144
        U s  7  567
        U s  8  259
PASS  28 probes on two cores print what probes/table.txt recorded: 7 where the chip's core is not the pinned one
PASS  e6_ignored: the differential refuses a model where the chip reads a configuration byte in the specification's order -- refused by tb_e6-rp2350
PASS  e6_everywhere: the differential refuses a model where both cores read a configuration byte in erratum E6's order -- refused by tb-rp2350
PASS  grain_ignored: the differential refuses a model where an address register keeps the two low bits written to it, so a region can be 8 or 16 bytes -- refused by tb_e6-rp2350, tb-rp2350
PASS  top_bits_kept: the differential refuses a model where an address register keeps the two top bits written to it -- refused by tb_e6-rp2350, tb-rp2350
PASS  tor_na4_napot: the differential refuses a model where TOR and NA4, written, match as NAPOT -- refused by tb_e6-rp2350, tb-rp2350
PASS  lock_ignored: the differential refuses a model where a locked region does not bind M-mode -- refused by tb_e6-rp2350, tb-rp2350
PASS  m0_ignored: the differential refuses a model where PMPCFGM0 binds M-mode to nothing -- refused by tb_e6-rp2350, tb-rp2350
PASS  unmatched_user: the differential refuses a model where U-mode that matches no region is let through -- refused by tb_e6-rp2350, tb-rp2350
```
