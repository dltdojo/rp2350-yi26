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
   difference must be one of the kinds above, or the check fails.
3. **`probes/probes.py --check`**: the probes on the four readers print what `probes/table.txt` recorded.
4. **`model/mutants.py`**: twelve wrong models (`model/mutants.txt`), each refused by the differential: it finds
   something other than what it finds with the true model, on one of five suites.
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
(not yet recorded)
```
