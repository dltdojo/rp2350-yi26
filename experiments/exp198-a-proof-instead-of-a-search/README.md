# exp198 — a proof instead of a search

<!-- SPDX-License-Identifier: Apache-2.0 -->

**exp197's model checked `crates/client-pin`'s counter with eight retries and
found nothing wrong with it. This proves the same thing for every counter and
every sequence of wrong guesses, power cycles and refused `setPIN`s, of any
length: a failed attempt is never given back. Five theorems in Lean, resting on
nothing but Lean's own axioms — and four wrong versions of the crate, each of
which the checker refuses.**

Nothing new is found here, on purpose. The subject is small, already tested and
already modelled, so that the only thing that changes between exp197 and this is
the kind of certainty — and what it costs.

## Search and proof, side by side

| | exp197, TLA+ | exp198, Lean |
| --- | --- | --- |
| What it does | walks every order of events | checks a proof somebody wrote |
| How far it reaches | 8 retries, 3 in a row, the states TLC could list | every counter, every sequence length |
| When the claim is false | the shortest path to a violation, for free | "unsolved goals" at the step that no longer holds |
| When the claim is true | "no error inside these bounds" | a theorem, with no bounds |
| Who does the work | the machine | a person, who writes the proof |
| What it downloads | a 2 MB jar | 580 MB, 2.9 GB unpacked |

The two are not rivals. A model checker is how to *find* a bug: it hands back a
counterexample without being asked how. A proof is how to *close* a question
once nothing is being found — and it needs somebody to say why the thing is
true, step by step, which a search never does.

## What is proved

[`proof/ClientPin.lean`](./proof/ClientPin.lean) transcribes `begin`, `judge`,
`set_pin` and `power_cycle` from the crate, and every event anybody can cause —
a guess, a power cycle, a `setPIN` — as one `step`. Each theorem quotes the
sentence it formalises.

| Theorem | In words | exp197's |
| --- | --- | --- |
| `never_given_back` | across any sequence of wrong guesses, power cycles and refused `setPIN`s, **counter + guesses judged = the counter it started with** | `GuessesAreBounded`, for 8 |
| `guesses_bounded` | so nobody gets more wrong guesses judged than the counter held, however often the power goes | — |
| `malware_stops_at_three` | with no power cycle, at most three wrong guesses are ever judged | `MalwareCannotBlock` |
| `a_power_cycle_is_what_lifts_the_limit` | drop "no power cycle" and a fourth is judged — the hypothesis is needed, not decoration | — |
| `old_design_replaces_the_pin` | exp186–exp189's `setPIN` could replace the owner's PIN: a counterexample, stated as a theorem | P1 |

`never_given_back` is an equation, not an inequality, on purpose: it says every
guess judged was paid for exactly once, which is P2 — nothing is free and
nothing is charged twice. `guesses_bounded` is one line after it.

## The four ways it could be worth less than it looks

1. **A step skipped.** Lean lets a proof say `sorry` and move on. `#print axioms`
   lists what each theorem rests on; a `sorry` anywhere underneath shows up as
   `sorryAx`. `check.sh` requires all five to list only `propext` and
   `Quot.sound`, which are Lean's own.
2. **The wrong sentence proved.** exp195 found a fix checked against a weaker
   property than the one written down. So each theorem quotes its sentence, and
   `a_power_cycle_is_what_lifts_the_limit` shows the one hypothesis a reader
   might suspect is doing the work really is.
3. **A proof that would pass anyway.** [`proof/mutants.txt`](./proof/mutants.txt)
   writes four wrong versions of the crate into the Lean — the decrement
   removed, a mismatch refilling the counter, the three-in-a-row check deleted,
   `setPIN` no longer refusing — and `check.sh` requires Lean to refuse every
   one. This is exp196's `--wrong` again: a grader that has never failed
   anything has not been shown to grade.
4. **A proof about code that no longer exists.** The Lean is a copy, and the
   Rust can change under it. [`proof/cited.txt`](./proof/cited.txt) names the
   sixteen Rust lines it transcribes and `check.sh` re-reads them through
   `tools/tlc/tlc.sh cited`, exactly as exp195–exp197 hold their models.

Where the refusal lands is worth reading. A mutant is usually refused at a small
lemma — `pay_ok`, `judge_wrong` — not at the headline theorem, because the
checker stops at the first step that no longer holds. The lemma is where the
deleted rule was being used.

## What it does not prove

- **`u8`.** The proof counts in `Nat`, where the crate has `u8`. The crate never
  lets either counter leave 0..=8 — `begin` refuses at 0, and three in a row
  stops everything — so no `u8` ever wraps, but that is an argument in this
  README, not part of the proof.
- **Constant time.** The PIN hash is a number compared by equality. The crate
  compares 16 bytes in constant time; timing is not something this proof can
  see.
- **The Rust itself.** The citations say the lines are still there; they do not
  say the transcription is faithful. That is read by a person, and it is the
  same second copy exp195–exp197's models are.
- **Persistence.** The crate keeps its state in RAM, and this is a proof about
  the crate. exp197's P4 — unplug, set a PIN of your own — is untouched.

## Try it

Delete the line `else if MAX_CONSECUTIVE ≤ s.consecutive then .error .authBlocked`
from `pay` and check the file again. Before reading the error, predict which
theorem fails. Then read where Lean actually stopped, and why it stopped
there first.

## Running it

```sh
../../tools/lean/setup.sh   # once, needs the network: Lean 4.34.0 by sha256, 580 MB
./check.sh                  # no board: the proof, its axioms, four mutants, the citations, the crate
./run.sh                    # records capture.txt
```

No board and nobody. `cargo` for the crate's tests; `zstd`, or python3 with
`zstandard`, to unpack Lean.

## Expected output

The capture lands in the next commit.
