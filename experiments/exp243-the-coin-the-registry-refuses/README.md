# exp243 — the coin the registry refuses

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Status: TODO (scaffold).** Third of four experiments in the single-board post-quantum
zero-knowledge payment plan:
[`docs/zkp-rv32/single-board-experiment-plan-zh-tw.md`](../../docs/zkp-rv32/single-board-experiment-plan-zh-tw.md)
(steps Z6 and Z7). Depends on exp241 and exp242.

## Overview

A private transaction and its double-spend refusal, once with each role. The statement: ownership of
a token commitment, the nullifier computed from the key, the two new commitments formed from the
stated amounts, and the amount conserved — with the spent commitment still public, so the version
hides the key and the amounts but **not which token was spent**.

The registry is whichever side verifies. With the page verifying it keeps the nullifier set; with
the board verifying it keeps a power-cut-safe, append-only nullifier log in flash. Both play the same
four scenarios: a normal payment, a forgery without the key, a tampered output, and a double-spend.

Needs: **no board** (scaffold). Planned: a Pico 2 and a phone or computer with Chrome.

## TODO

- [ ] **Statement**: the five checks of plan 3.3 as gate lists, each equal to the circuit pieces
      proved in exp241; proof size and times measured against the plan's 3.1 MB estimate.
- [ ] **Page as registry**: nullifier set and commitment list in the page's storage.
- [ ] **Board as registry**: append-only flash log, tested with every power cut the host can
      simulate, as exp211 did.
- [ ] The four scenarios in both roles, each ending in an ACCEPT or a named REJECT.
- [ ] README says plainly what a single verifier's double-spend check covers, and that the
      secret channel is the USB cable.
- [ ] `check.sh`, `run.sh`, capture, board log, index row filled in.
