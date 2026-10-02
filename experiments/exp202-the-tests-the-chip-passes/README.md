# exp202 — the tests the chip passes

<!-- SPDX-License-Identifier: Apache-2.0 -->

**The Lean model of what an RV32IM instruction does passes all 48 of
riscv-tests' RV32I and RV32M tests; so does the Hazard3 RTL — the RP2350's own
core, simulated — given the same bytes; and after every one, and after five
probes of this experiment's own, the two end the same way and leave the whole
64 KiB region byte for byte the same. Fourteen wrong models are each refused.
Four of them only by the probes: the suite never jumps to an odd address, never
misaligns a load, and never stores or fetches outside its own memory.**

[exp201](../exp201-one-word-one-reading/) settled which word is which
instruction. This settles what each instruction *does* — in the model every
later proof is about, [`lean/Rv32/Machine.lean`](../../lean/Rv32/Machine.lean)
— and it does it the only way a model can be checked: against things that are
not it. The design this road follows (see its
[briefing](../../docs/2026-10-02-0930-verified-kernel-road-briefing-zh-tw.md))
names three executors for every kernel: the Lean model, the Hazard3 RTL, and
the chip. This is the first two, on a test suite somebody else wrote.

## Two executors, one set of bytes

| | Lean model | Hazard3 RTL |
| --- | --- | --- |
| what it is | `Rv32.step`, compiled: [`lean/Run.lean`](../../lean/Run.lean) → `rv32run` | Hazard3 at a pinned commit, Verilator, the repository's own testbench: [`tools/hazard3`](../../tools/hazard3/) |
| how a test starts | `Rv32.boot`: pc at the region's base, every register zero but `sp` | [`harness.S`](../../tools/hazard3/harness/harness.S): PMP gives User mode the region and nothing else, registers zeroed, `mret` into User mode |
| how it ends | `ecall` with `t0 = 1`, or a fault | the same `ecall`, trapping into [`handler.c`](../../tools/hazard3/harness/handler.c), or any other trap |

The harness is the shell the chip will have, written small: a few dozen
instructions of setup and a handler that decides HALT or fault. Everything the
model assumes — User mode, one region, no interrupts, registers zero — is a line
in it.

## The suite, in the kernel's world

[riscv-tests](https://github.com/riscv-software-src/riscv-tests) is
self-checking: each test computes, compares against a constant, and reports
which case failed. That makes it usable without a reference model, which is
why it is used here rather than riscv-arch-test, whose tests compare a memory
signature against one made by the Sail model.

Its environments start in Machine mode and report through a `tohost` word. Only
that was replaced — [`env/riscv_test.h`](./env/riscv_test.h), thirty lines —
so a test starts in User mode and ends with the kernel's own `ecall`. Everything
a test *checks* is the suite's, at the commit Hazard3's own repository pins.

Two tests are not built, and each is a decision: `fence_i` (Zifencei, which the
model refuses on purpose) and `ma_data` (it checks misaligned access through a
trap handler made of CSR instructions, which the model also refuses).

## What the suite cannot see

Fourteen plausible mistakes in a model of RV32IM, in
[`semantics/mutants.txt`](./semantics/mutants.txt). Lean builds every one —
nothing in a type says what `sra` should do — and the comparison must refuse
each:

| The model gets wrong | Refused by |
| --- | --- |
| `x0` can be written and read back | 26 binaries |
| `sra` shifts in zeros | `rv32ui-sra` |
| `sll` uses the whole register as the shift amount | `rv32ui-sll` |
| signed division by zero gives zero | `rv32um-div` |
| `intMin % -1` is `intMin` | `rv32um-rem` |
| `mulhsu`'s signed operand is the other one | `rv32um-mulhsu` |
| `bge` compares unsigned | `rv32ui-bge` |
| `lb` zero-extends | 4 binaries |
| `sh` stores four bytes | 3 binaries |
| `auipc` adds to the next instruction's address | 14 binaries |
| **`jalr` keeps the target's low bit** | **`probe-jalr_lsb` only** |
| **a misaligned load is carried out** | **`probe-load_misaligned` only** |
| **a store outside the region is carried out** | **`probe-store_outside` only** |
| **an instruction outside the region is fetched** | **`probe-fetch_outside` only** |

The last four went through all 48 tests untouched. riscv-tests' `jalr` cases
only ever jump to even addresses, its stores stay in its own data, and its one
misaligned test is the one that cannot be built here. Those four are exactly the
behaviours a kernel proof leans on hardest — a proof that a kernel never faults
is a proof about where the faults are — so [`probes/`](./probes/) has one small
program for each, and a fifth for an instruction outside the subset. For every
probe the model and the RTL stop at the same instruction with the same kind of
fault, or, for `jalr`, land in the same place.

That is the finding: **a test suite that passes is evidence about what the suite
exercises**, and here that left out the parts of the model that matter most to
what comes next. The mutants are how it was found, and they stay, so that a
model that drifts on any of the fourteen is refused by name.

## Where the model and the core are allowed to differ

Where the model is stricter than the core, it is on purpose, and none of it is
in any binary above:

- **`fence`, `ebreak`, CSRs** — the model refuses them; Hazard3 runs them. A
  kernel the theorems are about contains none.
- **A jump to an address that is 2 mod 4** — legal on Hazard3, which has the C
  extension; a misaligned fetch in the model.
- **`mtval`** — Hazard3 writes zero on every fault here. The model has no
  `mtval`; the comparison uses `mepc`.

## What it does not prove

- **That the model is right.** It is evidence, on 53 programs, and the mutants
  measure how much of the model those programs actually look at. It is not a
  proof; there is no specification in Lean to prove it against.
- **That the RTL is the chip.** By the Hazard3 README, the testbench's default
  configuration is the RP2350's except that it adds the Zbc extension. But the
  RTL is a 2026 commit of the v1.1 line, and the RP2350 has v1.0-rc1 — its
  `mimpid` is `86fc4e3f`, by Hazard3's own documentation. The board half of this
  road ([Planned](../README.md#the-verified-kernel-road)) runs the same bytes on
  silicon.
- **Instruction counts.** Both executors count, and the numbers are printed;
  what they mean, and whether a proof can predict them, is
  [exp203](../exp203-the-count-the-proof-promised/)'s question.

## Running it

```sh
../../tools/lean/setup.sh      # once, needs the network: Lean 4.34.0, 580 MB
../../tools/hazard3/setup.sh   # once, needs the network: Hazard3 at a pinned commit, built with Verilator
./check.sh                     # no board: build, compare, fourteen mutants
./run.sh                       # records capture.txt
```

No board and nobody. `verilator`, `clang++`, `clang`, `lld` and `llvm-objcopy`
(Ubuntu: `verilator clang lld llvm`). The Hazard3 testbench builds in under a
minute; the comparison takes twenty seconds, and the mutants about five
minutes.

## Expected output

```text
=== exp202 — the tests the chip passes ===
recorded at 2026-10-02T08:31:15Z from commit dd7ce8b

>>> what runs it
    Lean (version 4.34.0, x86_64-unknown-linux-gnu, commit 293d5d0c0c3f3dded4688b3ccd6a33939ac5102b, Release)
    Hazard3 8af992930f71, riscv-tests 49a24d7f41e7, Verilator 5.020 2024-01-01 rev (Debian 5.020-1)

>>> every binary, on the model and on the RTL
binary                   Lean model                 Hazard3 RTL
probe-fetch_outside      fault 1 at 80000100        fault 1 at 80000100
probe-illegal_csr        fault 2 at 80010000        fault 2 at 80010000
probe-jalr_lsb           halt 00000000              halt 00000000
probe-load_misaligned    fault 4 at 80010008        fault 4 at 80010008
probe-store_outside      fault 7 at 80010004        fault 7 at 80010004
rv32ui-add               halt 00000000              halt 00000000
rv32ui-addi              halt 00000000              halt 00000000
rv32ui-and               halt 00000000              halt 00000000
rv32ui-andi              halt 00000000              halt 00000000
rv32ui-auipc             halt 00000000              halt 00000000
rv32ui-beq               halt 00000000              halt 00000000
rv32ui-bge               halt 00000000              halt 00000000
rv32ui-bgeu              halt 00000000              halt 00000000
rv32ui-blt               halt 00000000              halt 00000000
rv32ui-bltu              halt 00000000              halt 00000000
rv32ui-bne               halt 00000000              halt 00000000
rv32ui-jal               halt 00000000              halt 00000000
rv32ui-jalr              halt 00000000              halt 00000000
rv32ui-lb                halt 00000000              halt 00000000
rv32ui-lbu               halt 00000000              halt 00000000
rv32ui-ld_st             halt 00000000              halt 00000000
rv32ui-lh                halt 00000000              halt 00000000
rv32ui-lhu               halt 00000000              halt 00000000
rv32ui-lui               halt 00000000              halt 00000000
rv32ui-lw                halt 00000000              halt 00000000
rv32ui-or                halt 00000000              halt 00000000
rv32ui-ori               halt 00000000              halt 00000000
rv32ui-sb                halt 00000000              halt 00000000
rv32ui-sh                halt 00000000              halt 00000000
rv32ui-simple            halt 00000000              halt 00000000
rv32ui-sll               halt 00000000              halt 00000000
rv32ui-slli              halt 00000000              halt 00000000
rv32ui-slt               halt 00000000              halt 00000000
rv32ui-slti              halt 00000000              halt 00000000
rv32ui-sltiu             halt 00000000              halt 00000000
rv32ui-sltu              halt 00000000              halt 00000000
rv32ui-sra               halt 00000000              halt 00000000
rv32ui-srai              halt 00000000              halt 00000000
rv32ui-srl               halt 00000000              halt 00000000
rv32ui-srli              halt 00000000              halt 00000000
rv32ui-st_ld             halt 00000000              halt 00000000
rv32ui-sub               halt 00000000              halt 00000000
rv32ui-sw                halt 00000000              halt 00000000
rv32ui-xor               halt 00000000              halt 00000000
rv32ui-xori              halt 00000000              halt 00000000
rv32um-div               halt 00000000              halt 00000000
rv32um-divu              halt 00000000              halt 00000000
rv32um-mul               halt 00000000              halt 00000000
rv32um-mulh              halt 00000000              halt 00000000
rv32um-mulhsu            halt 00000000              halt 00000000
rv32um-mulhu             halt 00000000              halt 00000000
rv32um-rem               halt 00000000              halt 00000000
rv32um-remu              halt 00000000              halt 00000000

PASS  the Lean model passes all 48 riscv-tests
PASS  the Hazard3 RTL passes all 48 riscv-tests
PASS  every binary ends the same way on both — 48 tests and 5 probes
PASS  after every one, the whole region is byte for byte the same on both (53 × 65536 bytes)

>>> wrong models: each must be refused, and by what
PASS  x0: the comparison refuses a model where x0 can be written and read back — refused by 26: probe-jalr_lsb rv32ui-add rv32ui-addi rv32ui-andi ...
PASS  sra: the comparison refuses a model where sra shifts in zeros, as srl does — refused by 1: rv32ui-sra
PASS  sll: the comparison refuses a model where sll uses the whole register as the shift amount, not its low five bits — refused by 1: rv32ui-sll
PASS  div: the comparison refuses a model where signed division by zero gives zero, not all ones — refused by 1: rv32um-div
PASS  rem: the comparison refuses a model where the remainder of intMin by -1 is intMin, not zero — refused by 1: rv32um-rem
PASS  mulhsu: the comparison refuses a model where mulhsu takes the second operand as the signed one — refused by 1: rv32um-mulhsu
PASS  bge: the comparison refuses a model where bge compares unsigned — refused by 1: rv32ui-bge
PASS  lb: the comparison refuses a model where lb zero-extends the byte — refused by 4: rv32ui-lb rv32ui-ld_st rv32ui-sb rv32ui-st_ld
PASS  sh: the comparison refuses a model where sh stores four bytes — refused by 3: rv32ui-ld_st rv32ui-sh rv32ui-st_ld
PASS  auipc: the comparison refuses a model where auipc adds to the next instruction's address — refused by 14: probe-jalr_lsb rv32ui-auipc rv32ui-jal rv32ui-jalr ...
PASS  jalr: the comparison refuses a model where jalr keeps the target's low bit — refused by 1: probe-jalr_lsb
PASS  misaligned: the comparison refuses a model where a misaligned load is carried out instead of faulting — refused by 1: probe-load_misaligned
PASS  store-region: the comparison refuses a model where a store outside the region is carried out — refused by 1: probe-store_outside
PASS  fetch-region: the comparison refuses a model where an instruction outside the region is fetched — refused by 1: probe-fetch_outside
```

There is no board half here: the RTL is the chip's core, simulated on this
machine. Running the same bytes on silicon is on the board half of the road.
