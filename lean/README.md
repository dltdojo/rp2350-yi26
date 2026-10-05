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
| [`Rv32/Place.lean`](./Rv32/Place.lean) | a kernel at `base` in the 64 KiB region: `Placed`, address arithmetic that never wraps, the `lbu` and HASH steps, `readBytes`, and `code_of_image` — the bridge from a file's bytes to `CodeAt` | — lemmas, checked by Lean; exp203 wrote the first half, exp204 needed it second |
| [`Rv32/Kernel.lean`](./Rv32/Kernel.lean) | one instruction of any program at a time — `stepK`, `regStep`, `loadStep`, `lbuStep`, `storeStep`, `sbStep` — `overlay`, and the word lemmas | — lemmas; exp204 wrote them for itself, exp205 needed them second |
| [`Rv32/Blocks.lean`](./Rv32/Blocks.lean) | eight words zeroed, copied and compared, registers and offsets as parameters; `Keeps`, memory changed in one place only; `se_neg` and `dec_one`, which `decide` and `omega` run out of memory on | — lemmas; used by exp204, exp205, exp206 and exp213 |
| [`Rv32/Wots.lean`](./Rv32/Wots.lean) | WOTS (w = 16): the 69 instructions every WOTS kernel here starts with — setup, the 64 digits and their checksum, each chain's copy and walk — and what they do, for any program that starts with them (`Starts`). The chain's state is stated over the memory the kernel has left so far, so a kernel that writes elsewhere between chains still has it | — lemmas; exp205 wrote them for itself, exp206's MSS verifier starts with the same 69 instructions and exp213's signer with the first 46 of them |
| [`Rv32/Walk.lean`](./Rv32/Walk.lean) | a hash chain walked in place — `ecall; addi t3, t3, -1; bne t3, x0, -8` — at any instruction of any program, over any 64-byte buffer, and with the `beq` that skips it for zero steps | — lemmas; exp205's walk at a fixed place, then exp213's key generator and signer, each at its own |
| [`Rv32/Frame.lean`](./Rv32/Frame.lean) | `Within`, memory changed only in two places, and moving a step's own `Keeps` into it and past a read; the PRF input `seed ‖ l ‖ i ‖ 0³⁰` read back after its byte stores | — lemmas; exp213's key generator and signer |
| [`Rv32/Mss.lean`](./Rv32/Mss.lean) | exp206's MSS verifier — its kernel and everything proved of it — and the reference scheme: `secret`, `leafRef`, `node`, `authRef`, completeness | the model, the RTL and Python, in [exp206](../experiments/exp206-the-root-the-path-climbs/); here since exp213 needed it |
| [`Rv32/MssKeygen.lean`](./Rv32/MssKeygen.lean) | exp213's key generator: 108 instructions that write the seed's whole tree, proved to halt with 0 after exactly 76456 | the model, the RTL and Python, in [exp213](../experiments/exp213-the-signer-the-verifier-accepts/) |
| [`Rv32/MssSign.lean`](./Rv32/MssSign.lean) | exp213's signer: 155 instructions, exp205's first 46 among them, that write a signature, a path and a root where exp206's verifier reads them, in exactly `2284 + 3·Σdᵢ` | the same, in exp213 |
| [`Rv32/Asm.lean`](./Rv32/Asm.lean) | instructions as text, the way LLVM writes them | used by exp201's differential |
| [`Run.lean`](./Run.lean) | `rv32run`: the model, compiled, for running a binary; memory held in an array, so 6000 stores take a fraction of a second | exp202 to exp213 run it beside the RTL |
| [`Sha256.lean`](./Sha256.lean) | SHA-256, for `rv32run`'s HASH only — no theorem mentions it, so it can make a run disagree but never a proof wrong | `hashlib` at ten lengths, and the harness's C, in [exp204](../experiments/exp204-the-signature-the-kernel-checks/) |

```sh
tools/lean/lean.sh exe rv32run     # builds the library and the runner; prints the runner's path
```

Nothing here imports Mathlib, and nothing is proved by `native_decide` or
`bv_decide`: `tools/lean/lean.sh check` refuses the axioms they leave. The
build output, `.lake/`, is not committed.
