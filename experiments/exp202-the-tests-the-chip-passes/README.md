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
not it. The [design](../../docs/2026-10-02-0800-verified-kernel-road-briefing-zh-tw.md)
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
- **That the RTL is the chip.** The testbench's configuration is Hazard3's
  default: four PMP regions and the Zbc extension, where the RP2350's
  configuration differs. The board half of this road
  ([Planned](../README.md#the-verified-kernel-road)) runs the same bytes on
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

Not captured yet.
