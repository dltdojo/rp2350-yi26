# exp248 — the samples the front reads

<!-- SPDX-License-Identifier: Apache-2.0 -->

## Overview

[exp247](../exp247-the-remainder-behind-the-wall/) joined a proved kernel to a proved monitor. The one fact the
join needed that a kernel's own theorem does not say, "no call but HALT", came from the constant-time checker the
kernel already passed. The next pair, exp223's kernel behind [exp239](../exp239-the-scratch-the-monitor-scrubs/)'s
monitor, needs more than that, and gets none of it free:

- [exp223](../exp223-the-digest-the-kernel-withholds/)'s kernel was never run through the checker.
- Its health tests branch on the samples.
- It is two programs with data between them: the tests at +0, SHA-256 at +0x1000.
- Its SHA-256 is proved in a 64 KiB world of its own, which reaches 4 KiB past exp239's box.

What the box needs are facts about every step of the run: where each one reads, whether it writes, and what it
calls.

This is the first of three rounds that build a checker for those facts. **This round extends the checker, and runs
it on exp223's front**, the 34 instructions before SHA-256. In Lean 4, on Lean's own axioms, from the front's first
word, wherever it sits (its own 64 KiB, or a box it starts):

- **Every load reads a sample**, inside `[base + 0x3000, base + 0x4000)`.
- **Nothing is stored**, so memory is as it was.
- **The only call is HALT**, with `t0 = 1`.
- **These hold for every state up to SHA-256.** Either every state of the run so far is one of the front's 34
  instructions with the facts above, or the run has reached SHA-256's first word, `base + 0x1000`, and every state
  before that had them.

Needs: **no board** at all, and no USB anywhere in it. It has no firmware of its own: it is about exp223's
`kernel.bin`, which exp223's own `check.sh` holds to its proof. Nothing here ran on silicon or on the RTL.

## How this was decided

The interrogation, as [the repository asks](../README.md#every-new-experiment-starts-with-an-interrogation), before any
of it was built:

1. **The facts.**
   - exp239's emulator runs exp223's kernel under the monitor, and alone, on exp222's fourteen sample streams.
   - The kernel's theorem (`Exp223.conditions`) is in a 128 KiB world (`Wide`).
   - The front's tests are proved in `low env base`, the box's own 64 KiB. SHA-256's are proved in
     `[base + 0x1000, base + 0x11000)`.
   - exp239's monitor serves only HALT. An earlier note here said it served HASH; it does not.
2. **What was already answered.**
   - `lean/Rv32/Ct.lean`'s checker, and its `run_lock`, which holds at every step.
   - exp247's `ecalls_halt`, the first single-run reading of that relation.
   - `lean/Rv32/Within.lean`'s `run_within`, which only widens a region and never narrows one.
3. **The contradictions.**
   - "The run stays in 64 KiB" is a fact about every step, like "no call". Both need bounds on store addresses,
     because otherwise nothing keeps the code from being overwritten.
   - The checker refused exp223 for four reasons:
     - it took only one contiguous program;
     - it took only a branch to one of that program's own instructions;
     - it asked the program's world to be exactly the 64 KiB from its first word;
     - it bounded no load address.
   - SHA-256 adds two more:
     - its block count is read from memory (`lw` of the length 4096, `srli` by 6), so no register analysis knows it;
     - its message pointer depends on two nested counters.

     These were found after the first estimate. They tripled it, so the work was split into three rounds.
4. **What was decided without asking.**
   - The checker is extended in place, not copied:
     - `check prog P H` is now `checkX prog P H []`, so exp207's and exp229's acceptances are unchanged;
     - `Placed` became the weaker `Hosted`.
   - The new facts are read off the existing relation in a new file, not proved again.
   - "Public" is set to everything: for one run, nothing needs to be secret.
5. **What was asked**, and answered:
   - the next pair: exp239 with exp223;
   - how to close its gaps: a general reach checker, not explicit hypotheses or another pass over the proofs;
   - once its cost was known: build it in three rounds, this one first.

## What is proved

In the library, `lean/Rv32/Ct.lean`, changed:

| | says |
| :--- | :--- |
| `checkX`, `succOK` | the checker with **exits** `X`: a jump may also land on an index in `X`, where what the program claims stops. `check` is `checkX` with none |
| `Lock`, `AtIn`, `AtExit` | two runs step together to related states at one accepted instruction, **or at one exit**, related as the jump left them |
| `Hosted` | what soundness asks of where a program runs: `base` aligned, 64 KiB addressable above it, the program's own words in the region. `Placed` gives it, and so does a program at +0x1000 of a box |

`lean/Rv32/Reach.lean`, new:

| theorem | says |
| :--- | :--- |
| `windowed` | the static check, by `decide`: every load and every store the checker reaches is known to lie in its window, offsets from `base` |
| `Good`, `good_of_at` | what the checker says of one state: at one of the program's instructions, the program in memory, the step that instruction's, its load or store inside its window, an `ecall` at `t0 = 1` |
| `reach_until` | **every state up to the first exit is `Good`**: either all of the first `n` are, or the run is at an exit after `j ≤ n` steps and every state before was |
| `reach` | with no exits, every state of the run is `Good` |
| `frame` | **stores stay in their window**: if every state so far was `Good`, memory outside the store window is as it was |

And about exp223's front, in `proof/Front.lean`:

| theorem | says |
| :--- | :--- |
| `accepted`, `windows`, `halts_only` | the front through the checker, by `decide`: one loop head (instruction 10, `s1` at `base + 0x4000 − 4·s3`, `s3` from 1 to 1024), one exit (instruction 0x400, SHA-256), loads in the samples, stores nowhere, every `ecall` at `t0 = 1` |
| `front_reach` | **the front reads only samples, writes nothing and calls nothing but HALT, up to SHA-256**: for any `n`, every state of the first `n` steps is `Good` with memory as it was, or the run is at `base + 0x1000` after `j ≤ n` steps, memory as it was, every state before `Good` |

`Front.lean` is written by `proof/gen.py`. It holds exp223's `proof/Condition.lean` as exp223's `check.sh` holds it,
then `proof/tail.lean`. `check.sh` fails if the file is not what `gen.py` writes.

## What is not proved, and what it rests on

- **SHA-256.** Its run is not checked here. That is the next round: constant words in memory (the length), a
  pointer offset in two nested counters, and joins where two paths meet.
- **The front and SHA-256 as one run, and G5 for exp239.** The round after that: the two programs' facts joined at
  the exit, the run narrowed from exp223's 128 KiB to the box, and the bridge of exp247 for exp239's monitor.
- **When the exit comes.** `front_reach` says the facts hold until the run first reaches `base + 0x1000`, not that
  this happens at step 17422. exp223's `front_decides` says the run is there at step 17422, but not that it was not
  there sooner; joining with SHA-256's checker makes the question moot. The emulator shows 17422 for every healthy
  stream.
- **The model.** `Rv32.Machine`, the Tier 1 model: one hart, no interrupts, the region as Tier 1 checks it.

## The checks

1. `proof/Front.lean` checks, every theorem it prints on Lean's own axioms.
2. **Eight mutants** (`proof/mutants.txt`), each refused by Lean:
   - **Five claims other than the front's**: a window a word short; a loop head that lets the pointer run one past
     the last sample; the way out a word before SHA-256; no way out at all; the exit a word on.
   - **Three checkers made unsound**, which the soundness proofs must catch: a jump to any target let through, a store
     at an address the checker does not know let through, and the store window not checked.
3. `proof/Front.lean` is what `proof/gen.py` writes.
4. `suite/front_reach.py`, on the emulator, a separate program from the model: exp223's kernel alone on exp222's
   fourteen streams, every access recorded.
   - **Up to SHA-256:** every `pc` is one of the front's, every load is in the samples and both ends of the window are
     read, nothing is stored, and the only call is HALT.
   - **Healthy streams** reach +0x1000 at step 17422, memory as it was.
   - **Unhealthy streams** never reach it.
   - **SHA-256**, ahead and not claimed: the windows it reads and writes, which the next round's checker will have
     to compute.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
(captured by ./run.sh)
```
