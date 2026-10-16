# exp242 — the roles the board trades

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Status: TODO (scaffold).** Second of four experiments in the single-board post-quantum
zero-knowledge payment plan:
[`docs/zkp-rv32/single-board-experiment-plan-zh-tw.md`](../../docs/zkp-rv32/single-board-experiment-plan-zh-tw.md)
(steps Z3, Z4 and Z5). Depends on exp241's proof format.

## Overview

One Pico 2 and one static page, trading the prover's and the verifier's parts. In the first role the
board proves `pk = H(sk)` (a hardware wallet: `sk` from the TRNG, never leaving the board) and the
page verifies as the proof streams in. In the second the page proves and the board verifies,
streaming, without storing the proof. Each role accepts what the other made, and rejects a tampered
proof naming the round and the check.

The same flash also measures the constants the rest of the plan waits for: hardware and software
SHA-256 per compression, whether `SUM0..7` can be written back, TRNG time, USB throughput both
ways to a phone and to a computer, and the page's own SHA-256 speed.

Needs: **no board** (scaffold). Planned: a Pico 2, a hand on BOOTSEL once, and a phone or computer
with Chrome.

## TODO

- [ ] **Constants**: the six measurements above, each a pasted measurement, then the plan's time
      estimates recomputed from them.
- [ ] **Receive path**: a bulk OUT path in `tools/hazard3/shell/` with a host test; every existing
      experiment's UF2 byte for byte unchanged.
- [ ] **Role: board proves**, page verifies; a page button that tampers with round k.
- [ ] **Role: page proves**, board verifies; a cut transfer reported as incomplete, never accepted.
- [ ] Deterministic-seed mode (for the byte comparison with exp241) kept apart from the real one.
- [ ] Per-role, per-step result lines and an LED that says which step; a log naming the firmware.
- [ ] `check.sh`, `run.sh`, capture, board log, index row filled in.
