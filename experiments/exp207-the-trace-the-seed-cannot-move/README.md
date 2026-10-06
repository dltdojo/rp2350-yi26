# exp207 — the trace the seed cannot move

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Constant time, proved for exp213's key generator and signer: two runs that
differ only in secret bytes — the seed, and everything made from it — are
observed the same at every step: the same `pc`, the same address loaded or
stored, the same HASH arguments, the same end. The proof is not per kernel.
[`lean/Rv32/Ct.lean`](../../lean/Rv32/Ct.lean) is a checker, proved sound once,
and each kernel is run through it by `decide`. On the Hazard3 RTL two seeds of
the key generator and three of the signer retire the same `minstret` in the
same `mcycle`; another message, a public input, moves both.**

This is stage 3 of the [verified-kernel road](../README.md#the-verified-kernel-road).
exp203 saw 113 cycles on every data set and called it what it was: an
observation. exp213 proved its kernels' counts do not depend on the seed,
which is a statement about one number. This is the statement about every step.

## What "the same" means here

Two runs of one program, from states that agree on everything public — the
program, the registers, the public places in memory — and may differ
anywhere else. An observer of the core sees, at each step:

| | |
| --- | --- |
| where it is | the `pc` |
| what it touches | the address of a load or a store; HASH's source, length and destination |
| how it ends | halted with which code, or faulted how |

`trace env n s` in `lean/Rv32/Ct.lean` is that list for `n` steps. The theorem
is that the two traces are equal for every `n`, and the two runs end the same
way. What is *not* observed: the values in registers and memory. Those may
differ, and must — the signature is different under another seed.

On a core with no caches and no instruction whose time depends on its
operands, equal traces are equal time. Hazard3 has no caches, and neither
kernel multiplies or divides; that is the assumption between the theorem and
a clock, and the RTL is held to it below.

## The checker

Every register is, in two runs at once:

| | |
| --- | --- |
| `sec` | may differ |
| `pub` | the same in both |
| `num lo hi` | the same, a number in `[lo, hi]` |
| `ptr lo hi` | the same, `base` plus an offset in `[lo, hi]` |
| `aff r k c` | the same, `base + c + k · x`, where `x` is counter `r`'s value |

The last three exist for one reason: a store must be shown not to land in the
program or, with a secret, in a public place — and its address is a pointer a
loop moves. `aff` keeps a pointer tied to its loop counter, so that
`S9 = ENDS + 32 · i` with `i < 67` puts every chain end inside the ends.

`check` walks the program once, instruction by instruction, and refuses:

- a branch on a `sec` register;
- a load or store whose address is `sec`;
- a store, or HASH's 32 bytes, where the place is not known to lie above the
  program — and, for a secret value, outside every public place;
- `jal` and `jalr`, which neither kernel has.

A load is `pub` when every byte it may read is public, and `sec` otherwise.
Everything a kernel computes from public values is `pub`; from anything
secret, `sec`.

**Loops are given as heads**: the abstract state at each branch target, written
by hand — four for the key generator, five for the signer, in
[`proof/Trace.lean`](./proof/Trace.lean). The checker computes everything
between them and verifies that every way into a head lands in what the head
claims. A wrong head is not believed; it is refused.

## What is public

| Kernel | Public | Secret, so free to differ |
| --- | --- | --- |
| key generator | its own 432 bytes | everything else: the seed, the PRF input, the chain buffer, the ends, the tree |
| signer | its own 620 bytes, the message and the index (`0x1000`–`0x1021`), the digit scratch (`0x8040`–`0x8083`) | everything else: the seed, the tree, the PRF input, the signature, the path |

The index is public because an MSS signature publishes it. The signer reads
the tree at an address made from the index, and that is fine for the same
reason — and refused, below, the moment the index is called secret. The digit
scratch is in the list because the digits are computed from the message and
written there before they are read; the checker does not follow memory that
closely, so the two runs are asked to start with the same bytes there.

## What is proved

[`lean/Rv32/Ct.lean`](../../lean/Rv32/Ct.lean), once, for any program:

| Theorem | Says |
| --- | --- |
| `rel_mono` | a state implies any state the checker considers above it |
| `regs_write` | writing a register keeps every claim, a counter stepped in place moving what is affine in it |
| `range_addr` | the address an access goes to lies in the range the checker gave it |
| `rel_refine` | after a comparison, what the checker narrows a counter to holds |
| `step_lock` | two related runs at an accepted instruction take it together |
| `obs_eq` | and are observed the same doing it |
| `run_lock`, `constant_time` | every step, from any two states agreeing on what is public |
| `constant_time_boot` | the same, from the state the shell builds, for two images agreeing on what is public |

[`proof/Trace.lean`](./proof/Trace.lean), for exp213's kernels:

| Theorem | Says |
| --- | --- |
| `Keygen.accepted`, `Sign.accepted` | `check` accepts them, by `decide` |
| `keygen_constant_time` | two images beginning with `keygen.bin`, whatever else they hold, run in lock step |
| `sign_constant_time` | two images beginning with `sign.bin` with the same message, index and digit scratch — any seed, any tree — run in lock step |

All of it rests on `propext`, `Classical.choice` and `Quot.sound`.

Fourteen wrong versions in [`proof/mutants.txt`](./proof/mutants.txt) are each
refused:
- **three kernels that are not constant time:** a key generator that reads how far to walk from the seed, a signer that reads its digits from the PRF input, and a signer that picks the path's node by a byte of the seed;
- **two wrong claims about what is public:** the message secret, and the index secret — each leaks, through the walks and through the path's reads;
- **seven unsound checker rules:** a branch on a secret, a load from a secret address, a secret stored into a public place, a store into the program, a load called public whatever it reads, a pointer still affine in a counter that was written over, and a `!=` that narrows the wrong end of a range;
- **two wrong claims about the theorem:** an observer that also sees the value a store writes, and two runs that may start from different registers.

## The RTL

[`timing.py`](./timing.py) runs exp213's binaries from images built by
[`tools/hazard3/mss.py`](../../tools/hazard3/mss.py): the key generator under
two seeds, the signer under three — each seed with its own tree — signing one
message under one leaf, and then the signer once more with another message.

| Run | Model steps | RTL `minstret` | RTL `mcycle` |
| --- | ---: | ---: | ---: |
| key generator, seed 0 | 76456 | 145191 | 195653 |
| key generator, seed 1 | 76456 | 145191 | 195653 |
| signer, seed 0 | 3859 | 6230 | 8050 |
| signer, seed 1 | 3859 | 6230 | 8050 |
| signer, seed 2 | 3859 | 6230 | 8050 |
| signer, another message | 3544 | 5495 | 7002 |

Every seed retires the same instructions in the same cycles, on the model and
on the RTL. The last row is the control: the message is public, the walks'
lengths come from it, and a different message moves all three numbers — so
the measurement can see a difference when there is one. The RTL's
`minstret` is the model's count plus 3 for the harness's entry and exit and
4 for each HASH call — 76456 + 3 + 4 · 17183, and 3859 + 3 + 4 · 592.

## What it does not prove

- **That HASH is constant time.** In the model HASH is one step whose
  arguments are observed. On the RTL it is the harness's C SHA-256, on the
  chip the RP2350's SHA-256 block; their time is theirs, and the cycles above
  are counted only while the kernel runs.
- **The clock.** Equal traces are equal time on a core whose timing depends on
  nothing else — no caches, no data-dependent latency. That is the
  assumption, and the RTL is the evidence for it; silicon is exp212's.
- **Anything about values.** Which signature comes out is exp213's; that it
  verifies, exp206's.
- **The chip.** Nothing here has run on a board.

## Running it

```sh
./check.sh       # the proof, the mutants, the model and the RTL
./run.sh         # records capture.txt
```

Needs Lean (`tools/lean/setup.sh`) and the Hazard3 testbench
(`tools/hazard3/setup.sh`), and python3. No board.

## Expected output

```text
(pending)
```
