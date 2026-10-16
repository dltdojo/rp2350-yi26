# exp244 — the crowd the spender hides in

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Status: TODO (scaffold).** Last of four experiments in the single-board post-quantum
zero-knowledge payment plan:
[`docs/zkp-rv32/single-board-experiment-plan-zh-tw.md`](../../docs/zkp-rv32/single-board-experiment-plan-zh-tw.md)
(step Z8). Depends on exp243; how far it goes depends on exp243's measurements.

## Overview

Adds the one thing exp243 leaves out: the proof that the spent commitment is a leaf of the
commitment tree, so a watcher cannot tell **which** token was spent among the `2^d` in the tree.
Starts at a small depth and measures how the proof's size and the prover's time grow with `d`,
against the plan's estimate of about 0.63 MB and 4.5 s more per level.

Needs: **no board** (scaffold). Planned: a Pico 2 and a phone or computer with Chrome.

## TODO

- [ ] Merkle path as gate lists, equal to exp241's compression circuit, extended by depth.
- [ ] Board proves, page verifies, at depth 4; then the deepest depth the board's time allows.
- [ ] Proof size and times against depth, measured, with the plan's estimates beside them.
- [ ] Decide from exp243's numbers whether this one is worth building, and write the decision here.
- [ ] `check.sh`, `run.sh`, capture, board log, index row filled in.
