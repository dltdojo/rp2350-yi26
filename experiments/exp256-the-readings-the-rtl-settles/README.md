# exp256 — the readings the RTL settles

<!-- SPDX-License-Identifier: Apache-2.0 -->

## Overview

Every monitor theorem here is about `lean/Rv32/Priv.lean`, the Tier 2 model. Every monitor suite runs on
`tools/monitor/emulator.py`. Both are readings of the same documents, by the same hands, and until now neither had
been held against the other or against the core. That is the audit's G4. If the two readings made the same mistake,
nothing would notice; if they made different ones, only one side would show it.

This is the first of three rounds on G4. It builds the tool and records what it finds:

- **`privrun`**: `PrivMachine.step`, compiled ([`lean/PrivExec.lean`](../../lean/PrivExec.lean)). It is the model the
  theorems are about, run, and never an argument in a proof.
- **[`tools/monitor/privdiff.py`](../../tools/monitor/privdiff.py)**: runs a monitor suite as it is. Each emulator run
  the suite makes is replayed on `privrun`, compared after every step on everything software can read.
- **The Hazard3 RTL, as the RP2350 configures it** ([`tools/hazard3/config_rp2350.vh`](../../tools/hazard3/config_rp2350.vh),
  from the RP2350 datasheet's Table 387). Every run that starts from reset is run on it and compared at the end:
  every word printed, the exit code, every byte of RAM.
- **Twenty-three probes**: one question each, about a corner of the privileged specification the monitors seldom
  step on. They are asked of all four readers: the emulator, the model, and the RTL in two configurations.

Needs: **no board** at all, and no USB anywhere in it. No firmware of its own. Nothing here ran on silicon.

## How this was decided

1. **The facts.**
   - `PrivMachine` is computable from end to end, so it compiles as exp202's `rv32run` does.
   - The Hazard3 testbench builds here with Ubuntu's Verilator 5.020, the version exp202 used. Its memory map is the
     monitors': RAM at `0x80000000`, the reset vector at `0x80000040`, the print and exit words at `0xc0000004` and
     `0xc0000008`.
   - The RP2350 datasheet's Table 387 gives the configuration the chip's Hazard3 was built with: 8 dynamic PMP regions
     and 3 hardwired ones, a 32-byte grain, NAPOT only. The testbench's default has 4 regions, a grain of 4 bytes and
     TOR.
2. **What was already answered.**
   - exp202 held the Tier 1 model to riscv-tests and the RTL.
   - exp203 measured on the RTL that the counts around an `mret` depend on what the frontend had fetched.
   - exp209 found that PMP entry 0 reads back on the chip other than as written.
3. **The contradictions.**
   - **The RP2350 is not the pinned RTL.** Erratum RP2350-E6 transposes PMPCFG's R and X bits on the chip. Upstream
     fixed it (commit 7d37029) before the commit exp202 pinned, so no RTL here shows it.
   - **A suite and its replay are one program.** Patching the suites would change what they test, so they run unchanged,
     and the emulator is wrapped instead: the first time a machine steps, a copy is kept.
   - **The testbench has no host** for exp238's service port, so the runs that call it are counted on the RTL and not
     compared.
   - **The registers out of reset differ**: the emulator's are junk by design, to catch a monitor that trusts them;
     the RTL's are 0. For the RTL comparison the emulator starts at 0 too.
4. **What was decided without asking.**
   - **The emulator is the go-between.** The model agrees with it everywhere but two places, so the RTL is held to the
     emulator, and through it to the model.
   - **The counts are not a difference in what the core does**, but they are recorded: minstret per report, and the
     spread.
5. **What was asked**, and answered:
   - three rounds, each merged:
     - this one, the differential;
     - the model given the RP2350's PMP;
     - the monitors fixed and re-proved, then a board probe;
   - the RTL pinned as exp202 pinned it, with the RP2350's configuration;
   - the board last.

## What was found

> **Since [exp257](../exp257-the-bits-the-chip-transposes/)** the model's three mistakes below are fixed: `ebreak`
> is a breakpoint, a Tier 1 fault inside Tier 2 is an access fault, and a U-mode `wfi` sleeps while `mstatus.TW` is
> clear. The tables here are what this round found. The checks now hold the fixed model: 7,066 runs agree at every
> step and the other 19 are one kind, `wfi_sleeps`, the model sleeping where the RTL sleeps; and two of the probes'
> thirty readings that were not the RTL's now are. The capture below is today's.

### The model against the emulator: every run of twenty suites

**7,085 runs, 15,355,245 steps, each compared after every step.** 7,041 agree at every step. The other 44 are two
kinds:

| kind | runs | the model | the emulator | the RTL |
| :--- | ---: | :--- | :--- | :--- |
| `ebreak` | 40 | illegal instruction, cause 2 | breakpoint, cause 3 | breakpoint, cause 3 |
| `outside_region` | 4 | illegal instruction, cause 2 | access fault, cause 5 or 7 | access fault |

`outside_region` is a load or store the PMP let through, to an address outside Tier 1's region (`env.region`).
Inside Tier 2 the model checks that region too, and a Tier 1 fault becomes an illegal instruction. Both kinds are
the model's mistakes. No monitor theorem is affected: no proved monitor executes `ebreak` or lets a payload past the
PMP.

### The RTL against the emulator: every run from reset

Of the runs that start from reset, those that call the service port are counted and not compared. Every other one
ends the same on the RTL, every word, exit code and byte of RAM, but for three kinds:

- **`counters`**: only a report's counts differ. minstret is 1 to 3 higher on the RTL. mcycle counts cycles there and
  instructions in the emulator. **exp240's round reports 3082 instructions on the RTL**; the emulator, the model and
  exp254's theorem say 3081.
- **`wfi_sleeps`**: a payload's U-mode `wfi` sleeps on the RTL, and with no interrupt enabled it never wakes. The
  emulator and the model trap it as illegal. The datasheet agrees with the RTL: U-mode `wfi` is permitted while
  `mstatus.TW` is clear, and every monitor here leaves it clear. **A payload can hang every monitor here.**
- **`mpp_reset`**: Hazard3 resets `mstatus.MPP` to M-mode (`hazard3_csr.v`); the emulator and the model reset it to
  U-mode. A monitor that does not write MPP before its `mret` runs its payload in M-mode on the RTL. One of the
  monitors exp240's `broken_monitors.py` runs does this: HALT 0 on the emulator, an `ecall` from M-mode on the RTL.

The counts are in the capture below.

### The probes

From the table in the capture, the readings that are not the RTL's:

| probe | emulator | model | RTL (`tb-rp2350`) |
| :--- | :--- | :--- | :--- |
| `mstatus` at reset | 0 | 0 | `0x1800`: MPP = M |
| `mcountinhibit` at reset | 0 | 0 | 5: both counters stopped |
| `ebreak` in U-mode | cause 3 | **cause 2** | cause 3 |
| `fence` | illegal | illegal | an instruction |
| `misa`, `mhartid` | illegal | illegal | readable |
| `mtvec` written with bit 0 set | bit 0 dropped | dropped | **kept**: vectored mode |
| `mstatus` MPP = 01 | **reads `0x800`** | reads 0 | reads 0 |
| `mstatus` written all ones | `0x1888` | `0x1888` | `0x221888`: TW and MPRV are there too |
| `pmpcfg` entry written TOR or NA4 | kept | kept | becomes OFF |
| `pmpcfg1`, `pmpaddr4`, `PMPCFGM0` | illegal | illegal | readable |
| minstret across an `mret` and an `ecall` | 19 | 19 | 21 |
| `wfi` in U-mode, TW clear | cause 2 | cause 2 | **sleeps** |

The two RTL configurations differ where Table 387 says they should. The grain-3 `pmpaddr` readback the model was
written to is `tb-rp2350`'s and not `tb`'s; TOR and NA4 are refused only by `tb-rp2350`. Locks, an execute-only
entry, MPP = 01 in the model, and `wfi` with TW set agree everywhere.

### What the RP2350 datasheet says that no reader here has

These cannot be measured on any RTL here. They are cited, not tested:

- **Erratum RP2350-E6** (A2, A3, A4): PMPCFG's R and X bits are transposed.
  - exp240's code entry, `0x1d`, reads the same either way.
  - **exp240's data and stack entries, `0x1b`, are W+X with no R on the chip.** The data entry is then writable and
    executable, so the box is not W^X. And exp225's kernel faults at its first load, the seed.
  - exp236's to exp239's `0x1f` reads the same either way.
- **Three hardwired regions**, 8 to 10: U-mode RWX on ROM, the peripherals (`0x40000000`–`0x5fffffff`) and SIO. A U-mode
  access no dynamic entry matches is refused in the model, and allowed there on the chip.
- **Eight dynamic regions.** The model has four. Entries 4 to 7 are not written by any monitor here, and a weak reset
  may leave them on.
- **`PMPCFGM0`**: a CSR that applies a region to M-mode without locking it. The model does not have it, and exp240's
  "from any CSRs that lock no PMP entry" does not exclude it.

## What it means for the proofs

- **exp236, exp238 and exp239** prove their monitors from `s.csrs = {}`. Hazard3 resets `mstatus.MPP` to M and
  `mcountinhibit` to 5, so `{}` is not its reset. The monitors write both before they use them, so the theorems likely
  survive a weaker hypothesis; as stated, they do not cover the chip's reset.
- **exp240** proves its boot from any CSRs that lock no PMP entry. That covers Hazard3's reset values above, but not
  `PMPCFGM0` or entries 4 to 7. On the chip, E6 makes its box something else.
- **exp254 and exp255** say the host hears 3081 instructions. The RTL counts 3082: the frontend effect exp203 named,
  which the model leaves out.
- **No monitor sets `mstatus.TW`**, so a payload's `wfi` hangs the monitor on the RTL. No theorem here is about
  liveness.

Rounds 2 and 3 take these up: the model given the RP2350's PMP, then the monitors fixed and re-proved, then a board
probe for what only the chip can say.

## What is not checked, and what it rests on

- **The RTL is not the chip.** It is Hazard3 at the commit exp202 pinned, newer than the RP2350's, configured from the
  datasheet. The testbench has no peripherals, so a U-mode access to them faults on the bus either way, and the probe
  `u_peripheral` cannot tell the hardwired region from a refusal.
- **The RTL is compared at the end only.** The testbench shows what is printed and the RAM, not the registers after
  each step.
- **The host is not compared.** What a port load returns, and the digest a hash request writes, are the emulator's
  host's; the model is given them.
- **The suites decide the coverage.** A corner no suite and no probe reaches is not compared. The model's mutants say
  which mistakes the differential can see.

## The checks

1. **`privrun` builds**: `PrivMachine.step`, compiled, from `lean/PrivExec.lean`.
2. **`differential/differential.py`**: every run of the twenty monitor suites on the model and, from reset, on `tb-rp2350`. Every
   difference must be one of the kinds above, or the check fails. Since exp257, the model has one kind against the
   emulator, `wfi_sleeps`, and `ebreak` or `outside_region` would fail it.
3. **`probes/probes.py --check`**: the probes on the four readers print what `probes/table.txt` recorded.
4. **`model/mutants.py`**: twelve wrong models (`model/mutants.txt`), each refused by the differential: it finds
   something other than what it finds with the true model, on one of five suites. The loop is
   `tools/monitor/privmutants.py` since exp257 needed it too.
   - **The PMP**:
     - R and X transposed, which is erratum E6, what the chip does;
     - entries tried from the last;
     - unmatched U-mode let through;
     - NAPOT twice as large;
     - locks ignored;
     - `pmpaddr` read back raw.
   - **Traps**:
     - not counted;
     - MIE kept;
     - the two `ecall` causes swapped.
   - **`mret`**:
     - MPIE left clear;
     - MPP kept.
   - **`mtvec`** keeps its low bits.

   Three of them break a theorem `Priv.lean` proves of the rule they change. The copy drops that theorem, so that what
   is built is the wrong model. A thirteenth, an access straddling an entry's edge, cannot be seen: NAPOT entries are
   multiples of 32 bytes and a misaligned access traps first.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp256 — the readings the RTL settles ===
recorded at 2026-10-28T00:48:45Z from commit 369c097

>>> twenty-three probes, four readers: what each prints
probe                reader     words printed
mstatus_reset        emulator   00000000   <- not the RTL's
                     model      00000000   <- not the RTL's
                     tb-rp2350  00001800
                     tb         00001800
mcountinhibit_reset  emulator   00000000   <- not the RTL's
                     model      00000000   <- not the RTL's
                     tb-rp2350  00000005
                     tb         00000005
ebreak_u             emulator   54524150 00000003 00000060
                     model      54524150 00000003 00000060
                     tb-rp2350  54524150 00000003 00000060
                     tb         54524150 00000003 00000060
fence_m              emulator   54524150 00000002 00000034   <- not the RTL's
                     model      54524150 00000002 00000034   <- not the RTL's
                     tb-rp2350  00000001
                     tb         00000001
misa_m               emulator   54524150 00000002 00000034   <- not the RTL's
                     model      54524150 00000002 00000034   <- not the RTL's
                     tb-rp2350  40901107
                     tb         40901107
mhartid_m            emulator   54524150 00000002 00000034   <- not the RTL's
                     model      54524150 00000002 00000034   <- not the RTL's
                     tb-rp2350  00000000
                     tb         00000000
mtvec_bit0           emulator   800000a4   <- not the RTL's
                     model      800000a4   <- not the RTL's
                     tb-rp2350  800000a5
                     tb         800000a5
mtvec_bit1           emulator   800000a4
                     model      800000a4
                     tb-rp2350  800000a4
                     tb         800000a4
mpp_01               emulator   00000800   <- not the RTL's
                     model      00000000
                     tb-rp2350  00000000
                     tb         00000000
mstatus_ones         emulator   00001888   <- not the RTL's
                     model      00201888   <- not the RTL's
                     tb-rp2350  00221888
                     tb         00221888
mcountinhibit_ones   emulator   00000005
                     model      00000005
                     tb-rp2350  00000005
                     tb         00000005
pmpaddr_napot        emulator   20004003 20004000
                     model      20004003 20004000
                     tb-rp2350  20004003 20004000
                     tb         20004000 20004000
pmpcfg_tor           emulator   00000f1f   <- not the RTL's
                     model      00000f1f   <- not the RTL's
                     tb-rp2350  0000071f
                     tb         00000f1f
pmpcfg_na4           emulator   0000171f   <- not the RTL's
                     model      0000171f   <- not the RTL's
                     tb-rp2350  0000071f
                     tb         0000171f
pmpcfg1              emulator   54524150 00000002 00000034   <- not the RTL's
                     model      54524150 00000002 00000034   <- not the RTL's
                     tb-rp2350  00000000
                     tb         00000000
pmpaddr4             emulator   54524150 00000002 00000034   <- not the RTL's
                     model      54524150 00000002 00000034   <- not the RTL's
                     tb-rp2350  00000000
                     tb         00000000
pmpcfgm0             emulator   54524150 00000002 00000034   <- not the RTL's
                     model      54524150 00000002 00000034   <- not the RTL's
                     tb-rp2350  00000000
                     tb         00000000
counted_mret         emulator   54524150 00000008 00000060 00000013   <- not the RTL's
                     model      54524150 00000008 00000060 00000013   <- not the RTL's
                     tb-rp2350  54524150 00000008 00000060 00000015
                     tb         54524150 00000008 00000060 00000015
lock_m               emulator   54524150 00000007 0000005c
                     model      54524150 00000007 0000005c
                     tb-rp2350  54524150 00000007 0000005c
                     tb         54524150 00000007 0000005c
x_only               emulator   54524150 00000005 00000084
                     model      54524150 00000005 00000084
                     tb-rp2350  54524150 00000005 00000084
                     tb         54524150 00000005 00000084
u_peripheral         emulator   54524150 00000005 00000064
                     model      54524150 00000005 00000064
                     tb-rp2350  54524150 00000005 00000064
                     tb         54524150 00000005 00000064
wfi_u_tw             emulator   54524150 00000002 00000060
                     model      54524150 00000002 00000060
                     tb-rp2350  54524150 00000002 00000060
                     tb         54524150 00000002 00000060
wfi_u                emulator   54524150 00000002 00000060   <- not the RTL's
                     model       hangs
                     tb-rp2350   hangs
                     tb          hangs

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  privrun builds: PrivMachine.step, compiled, from lean/PrivExec.lean
PASS  the model against the emulator: 20 suites, 7085 runs, 15355245 steps, every one
      compared after every step; 7066 runs agree at every step, and the 19 that do not are 19 wfi_sleeps
PASS  the RTL (tb-rp2350) against the emulator: 6770 runs from reset, 751 of them calling the
      service port, which the testbench has no host for; of the 6019 compared, 934 end the same,
      every word, exit code and byte of RAM; 5065 differ only in a report's counts and 19 are wfi_sleeps,
      1 mpp_reset
      minstret, RTL less emulator, in the reports that differ: +1 in 2067, +2 in 2992, +3 in 6
PASS  23 probes on four readers print what probes/table.txt recorded: 28 readings that are not the RTL's
PASS  r_x_transposed: the differential refuses a model where PMPCFG's R and X bits are transposed -- erratum RP2350-E6, what the chip does -- refused by probes.py, wx_attacks.py, rounds.py
PASS  last_entry_first: the differential refuses a model where the PMP tries its entries from the last -- refused by probes.py, wx_attacks.py, rounds.py
PASS  unmatched_user: the differential refuses a model where U-mode that matches no entry is let through -- refused by attack_cases.py, wx_attacks.py
PASS  napot_double: the differential refuses a model where a NAPOT entry covers twice the bytes it says -- refused by wx_attacks.py
PASS  lock_ignored: the differential refuses a model where a locked entry does not bind M-mode -- refused by probes.py
PASS  trap_uncounted: the differential refuses a model where a trap is not counted in minstret -- refused by probes.py, attack_cases.py, wx_attacks.py, rounds.py
PASS  trap_keeps_mie: the differential refuses a model where a trap leaves mstatus.MIE as it was -- refused by rounds.py
PASS  mret_mpie_clear: the differential refuses a model where mret leaves mstatus.MPIE clear -- refused by probes.py, attack_cases.py, wx_attacks.py, rounds.py
PASS  mret_keeps_mpp: the differential refuses a model where mret leaves mstatus.MPP as it was -- refused by probes.py
PASS  mtvec_unmasked: the differential refuses a model where mtvec keeps the two low bits written to it -- refused by probes.py
PASS  readback_raw: the differential refuses a model where pmpaddr reads back as written in NAPOT, its low bits not forced -- refused by probes.py, rounds.py
PASS  ecall_causes_swapped: the differential refuses a model where an ecall from U-mode reports M-mode's cause, and the other way round -- refused by probes.py, attack_cases.py, wx_attacks.py, rounds.py
```
