# exp255 — the lives, round after round

<!-- SPDX-License-Identifier: Apache-2.0 -->

## Overview

The last of three rounds toward [exp225](../exp225-the-life-every-beat-proved/)'s Rule 30 kernel behind
[exp240](../exp240-the-code-the-box-forbids-writing/)'s monitor, round after round.

exp240 proved its monitor round after round, whatever the payload:

- a machine is `Ready` when the monitor's words are in place, the code entry holds what it was loaded with, and no PMP
  entry is locked;
- a round leaves a `Ready` machine `Ready`;
- so does any write of the host's that spares the monitor's words, the code and the locks.

It did not prove what exp225's kernel leaves in any round: rounds.py checked that on the emulator.
[exp254](../exp254-the-life-the-box-lets-through/) proved one round, from reset. A reset is how every round starts, so
this round extends it to all of them.

In Lean 4, on Lean's own axioms. Start from a machine `Ready` with exp225's kernel in its code. Run any number of rounds,
and let the host write anything it may between them. Then:

- **The next round is there, and it is the only one.** Its first trap is the kernel's 3079th step.
- **It parks with HALT 0**, and the host hears HALT, 0, 3081, 3081, then 0.
- **Its history is Rule 30 of the seed it found.** Memory, but for the monitor's stack and report words, is exp225's
  `lived` of the memory the round started with.
- **With rounds.py's host**, which copies each round's last generation into the seed, the rounds together are Rule 30
  from the first seed. After n rounds the seed is generation 256 n, and round n + 1's history is generations 256 n + 1
  to 256 n + 256.

Needs: **no board** at all, and no USB anywhere in it. There is no firmware of its own. It is about exp225's
`kernel.bin` and exp240's `monitor.bin`, which their own `check.sh` hold to their own proofs. Nothing here ran on
silicon or on the RTL.

## How this was decided

1. **The facts.**
   - exp240's `Ready`, `Round`, `HostWrite` and `Rounds`.
   - `monitor_rounds`: `Rounds` keep a machine `Ready`.
   - `monitor_round_ready`: one round does too.
   - exp254's `life_behind_the_box`: one round, from any reset that locks no PMP entry. exp240's `resetOf` is such a
     reset.
   - exp254's `life_traps`: every step before the kernel's last is in U-mode, and the last is the trap.
2. **What was already answered.**
   - exp240's `monitor_reentry`: no register and no CSR a round leaves reaches the next; only memory does. So one round
     from reset is every round, given the memory it starts with.
   - lean/Rv32/Proof.lean's `CodeAt.congr`: the kernel is in memory if the code entry's bytes are what they were.
3. **The contradictions.**
   - **`Round` is a relation, not a function.** It names a round by its first trap. That there is a round at all, and
     only one, has to be shown. `life_traps` gives both: U-mode before step 3079, M-mode at it.
   - **The host is anyone.** exp240's `HostWrite` lets it write anything but the monitor's words and the code, the CSRs
     too, so the seed a round finds is whatever was written. The theorem about every round speaks of the seed the round
     found. The one about rounds.py's host speaks of the first seed.
4. **What was decided without asking.**
   - **rounds.py's host is one function**, `nextSeed`. It reads the history's last word from memory and writes it at
     the seed, as rounds.py does. It does not use the theorem's value. The proof shows that the word it reads is
     generation 256 of the seed.
   - **The resets between rounds are `resetOf`**, the weakest there is, as in exp240. rounds.py's resets with junk CSRs
     are among the host's writes.
5. **What was asked**, and answered:
   - the next pair: exp240 with exp225, including any number of rounds;
   - three rounds, each merged on its own. This is the last.

## What is proved

In `proof/Rounds.lean`:

| theorem | says |
| :--- | :--- |
| `life_round` | **one round, from any `Ready` machine with the kernel in its code**: a `Round`, the only one; parked with HALT 0; memory exp225's `lived` of what it found but for the monitor's stack and report words; the host hears HALT, 0, 3081, 3081, 0 |
| `life_rounds` | **every round, whatever came before**: the same, after any `Rounds` -- any number of rounds and of the host's writes |
| `Rounds.trans`, `nextSeed_host` | rounds then rounds are rounds; rounds.py's host write is one exp240 allows |
| `gen_add`, `history_word`, `round_history` | generation `a + b` is generation `b` of generation `a`; word `i` of a round's history, read from where it parks, is generation `i + 1` of its seed |
| `life_forever` | **rounds.py, round after round**: after `n` rounds the machine is reached by `Rounds`, its seed is generation `256 n` of the first, and round `n + 1` parks with HALT 0 with generations `256 n + 1` to `256 n + 256` as its history |

`Rounds.lean` is written by `proof/gen.py`. It holds what exp254's `proof/gen.py` writes, then exp254's
`proof/tail.lean`, then `proof/tail.lean`. The reading and the cutting are exp254's generator's, loaded from it.
`check.sh` fails if the file is not what `gen.py` writes.

## What is not proved, and what it rests on

- **The host is any host the theorem names.** `life_rounds` covers every host exp240's `HostWrite` allows.
  `life_forever` covers one host, rounds.py's. A host that writes the code or locks a PMP entry is outside both, as
  in exp240.
- **`mcycle` is the model's**, as exp247 says. On Hazard3 a cycle is not an instruction.
- **The model.** Everything exp240's README says: one hart, interrupts not modelled, the model's reading of Hazard3,
  the MMIO words as memory.

## The checks

1. `proof/Rounds.lean` checks, every theorem it prints on Lean's own axioms.
2. **Six mutants** (`proof/mutants.txt`), each refused by Lean:
   - **Four claims other than the run's**:
     - a round ending where the trap is a step sooner;
     - every round's history Rule 30 of the first seed, not the one it found;
     - the seed after n rounds generation 255 n;
     - each history word a generation behind.
   - **The host made something else**:
     - copying the second-to-last generation;
     - writing the seed into the code entry, which exp240's `HostWrite` forbids.
3. `proof/Rounds.lean` is what `proof/gen.py` writes.
4. `suite/forever.py`, on the emulator, a separate program from the model. It runs two hosts.
   - **rounds.py's host**: 100 rounds from one RAM, with the kernel loaded once and every other reset leaving junk in
     the CSRs. Each round must:
     - first reach the park word at step 61 + 3079 + 57;
     - park with every register zero, exit 0, and the report HALT, 0, 3081, 3081;
     - leave memory as exp225's `lived` of what it found, but for the monitor's stack words;
     - find generation 256 n of the first seed as its seed;
     - leave generations 256 n + 1 to 256 n + 256 as its history, read from rule30.py's 25,600.
   - **Any host**: 20 rounds. After each one, the host writes junk over every byte but the monitor's words and the code
     entry, the seed among them, and resets with junk in the CSRs. Each round must do the same, with its history Rule 30
     of the seed the junk left.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
(not yet recorded)
```
