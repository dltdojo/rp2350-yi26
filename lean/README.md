# lean/

<!-- SPDX-License-Identifier: Apache-2.0 -->

The Lean library the verified-kernel road stands on — what `crates/` is to the
firmware. One copy of each fact, so that a kernel's own proof holds only what
that kernel is asking about.

| Module | Holds | Checked against something else by |
| --- | --- | --- |
| [`Rv32/Isa.lean`](./Rv32/Isa.lean) | the forty-six RV32IM forms a kernel may use; `encode`, `decode`, and both directions proved | LLVM, in [exp201](../experiments/exp201-one-word-one-reading/) |
| [`Rv32/Machine.lean`](./Rv32/Machine.lean) | what one instruction does in User mode inside one region; `ecall` as HASH and HALT | riscv-tests and the Hazard3 RTL, in [exp202](../experiments/exp202-the-tests-the-chip-passes/) |
| [`Rv32/Load.lean`](./Rv32/Load.lean) | `boot`: the calling convention, the state the shell builds | the harness in `tools/hazard3`, which builds it |
| [`Rv32/Proof.lean`](./Rv32/Proof.lean) | runs compose; a loaded program fetches; registers and memory after a write | — it is lemmas about the model, and is checked by Lean |
| [`Rv32/Asm.lean`](./Rv32/Asm.lean) | instructions as text, the way LLVM writes them | used by exp201's differential |
| [`Run.lean`](./Run.lean) | `rv32run`: the model, compiled, for running a binary | exp202 and exp203 run it beside the RTL |

```sh
tools/lean/lean.sh exe rv32run     # builds the library and the runner; prints the runner's path
```

Nothing here imports Mathlib, and nothing is proved by `native_decide` or
`bv_decide`: `tools/lean/lean.sh check` refuses the axioms they leave. The
build output, `.lake/`, is not committed.
