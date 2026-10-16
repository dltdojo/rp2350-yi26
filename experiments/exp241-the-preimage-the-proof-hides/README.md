# exp241 — the preimage the proof hides

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Status: TODO (scaffold).** First of four experiments in the single-board
post-quantum zero-knowledge payment plan:
[`docs/zkp-rv32/single-board-experiment-plan-zh-tw.md`](../../docs/zkp-rv32/single-board-experiment-plan-zh-tw.md)
(steps Z1 and Z2). The other three are exp242, exp243 and exp244.

## Overview

A zero-knowledge proof that the prover knows `sk` with `pk = SHA-256-compression(sk ‖ 0³²)`,
and nothing else: ZKB++ (three-party MPC-in-the-head), 219 rounds, the circuit being the SHA-256
compression function as a list of AND, XOR and NOT gates. Two things are claimed:

- the gate list **is** SHA-256 — checked against `hashlib`, and **proved in Lean**, for every input,
  equal to [`lean/Rv32/Sha.lean`](../../lean/Rv32/Sha.lean)'s compression;
- a Python prover and a JavaScript prover given the same seed make **byte-identical** proofs, each
  verifier accepts both, and changing any one byte is rejected naming the round and the check.

The proof format (v1) is fixed here, so exp242 to exp244 only cite it.

Needs: **no board** (scaffold, and the finished experiment).

## TODO

- [ ] **Circuit**: gate list for one SHA-256 compression (adders, Ch, Maj, Σ, σ); equals `hashlib` on
      random and edge inputs; print the AND count against the plan's estimate of 22,696.
- [ ] **Lean**: the gate list equals `Sha.lean`'s compression for all inputs; mutants (adder without
      a carry, a wrong rotation, a skipped schedule round) refused.
- [ ] **ZKB++**: Python reference prover and verifier; JS prover and verifier shared by the pages;
      seed derivation and rejection-sampled challenges as in plan 3.6.
- [ ] **Format v1**: header, challenge first, 219 rounds, tail; shared test-vector file.
- [ ] **Tamper tests**: every byte position class rejected, with the round and the check named.
- [ ] **Cost model**: proof size and compression counts printed, against the plan's 0.64 MB.
- [ ] `check.sh`, `run.sh`, capture, index row filled in.
