# exp236 — the wall the monitor holds

<!-- SPDX-License-Identifier: Apache-2.0 -->

**The RISC-V M-mode micro-monitor, assembled and formally proved in Lean 4.
In 146 instructions (584 bytes, well within the 600-byte budget) of pure
RV32I + Zicsr machine code, `monitor.bin` establishes a hardware-enforced
sandboxed domain for untrusted or confidential execution on the RP2350
Hazard3 core. It configures a 64 KiB NAPOT PMP region at `0x80010000` with
default-deny everywhere else, locks down privilege mode via `MRET` into U-mode,
and intercepts all traps. On halting, it performs secret zeroization: wiping
all general-purpose registers `x1..x9` and `x11..x31` to zero while preserving
only the exit code in `a0`. Four security theorems are proved on Lean's own
axioms only. The monitor is verified against exp229's 458-instruction secp256k1
field arithmetic kernel and an adversarial test suite of five hostile U-mode attacks.**

Needs: **no board**. The middle stone of the micro-monitor track, implementing
Phase 3 (micro-monitor core assembly and formal proofs) and Phase 4 (PMP
sandbox integration and adversarial evaluation) from `docs/micro-monitor/`.

## Architecture: Micro-Monitor in Pure Assembly

The micro-monitor (`monitor.S`) replaces the unverified M-mode C harness with
a minimal, formally proved machine-code monitor assembled directly at `0x80000000`:

```
Physical Memory Map
0x80000000 ┌─────────────────────────────────────────────────────────┐
           │ Monitor Code & Vectors (monitor.bin: 146 insts, 584 B)  │
0x80008000 ├─────────────────────────────────────────────────────────┤
           │ Monitor M-Mode Stack & Scratch Frame                    │
0x80010000 ├─────────────────────────────────────────────────────────┤ ▲
           │ Sandboxed U-Mode Payload (64 KiB NAPOT PMP region)      │ │
           │ - RWX granted to U-mode                                 │ │
           │ - Exp229 secp256k1 field arithmetic kernel              │ │ 64 KiB
0x80020000 ├─────────────────────────────────────────────────────────┤ ▼
           │ Unmapped / Default-Deny (Traps mcause = 1, 5, 7)        │
           └─────────────────────────────────────────────────────────┘
```

### Execution Flow

1. **Boot Vector (`0x80000040`)**:
   - Freezes hardware counters (`csrwi mcountinhibit, 5`) so monitor overhead does
     not pollute payload cycle counts.
   - Sets trap vector to direct mode (`csrw mtvec, 0x80000040`).
   - Configures PMP entry 0: `pmpaddr0 = 0x20005fff` (64 KiB NAPOT at `0x80010000`),
     `pmpcfg0 = 0x1f` (NAPOT, RWX, unlocked). All other PMP entries remain OFF (default-deny).
   - Initializes M-mode stack pointer (`sp = 0x80008000`) and saves it in `mscratch`.
   - Clears target payload registers `x1..x31` and sets payload stack (`sp = 0x80020000`).
   - Configures `mstatus` with `MPP = 0` (U-mode) and `mepc = 0x80010000`.
   - Unfreezes counters (`csrwi mcountinhibit, 0`) and enters U-mode via `mret`.

2. **Trap Handler & Dispatch**:
   - Immediately freezes counters (`csrwi mcountinhibit, 5`).
   - Swaps stack pointer with `mscratch` and preserves scratch registers `t0, t1`.
   - Inspects `mcause`:
     - If `mcause == 8` (`CAUSE_ECALL_UMODE`), dispatches syscall in `t0`:
       - `t0 == 1` (`HALT`): proceeds to secret zeroization and normal exit.
       - Any other syscall ID: branches to `handle_fault`.
     - If `mcause != 8` (e.g. PMP access fault `1, 5, 7` or illegal instruction `2`):
       reports `TAG_FAULT` (`0x4641554c`), `mcause`, `mepc`, `mtval`, `minstret`,
       and exits with failure code `1`.

3. **Secret Zeroization on Exit**:
   - Latches `a0` exit code.
   - Sequentially zeroes all general-purpose registers:
     `li x1, 0`, `li x2, 0`, ..., `li x9, 0`, `li x11, 0`, ..., `li x31, 0`.
   - Leaves only `a0` carrying the application verdict.
   - Reports `TAG_HALT` (`0x48414c54`), `a0`, `minstret`, `mcycle` to the testbench.
   - Clears temporary scratch registers and halts the core (`wfi`).

## Formally Proved Security Theorems (`proof/Monitor.lean`)

All theorems check on Lean 4's own axioms only (`propext`, `Quot.sound`, or no axioms):

1. **`monitorCode_length`**:
   The concrete word list assembled from `monitor.S` has length exactly 146 instructions
   (584 bytes), strictly within the 150-instruction budget.
2. **`monitor_isolation_thm`**:
   Under the monitor's `UBoxed` PMP configuration, access from U-mode is granted if and
   only if `0x80010000 ≤ addr.toNat ∧ addr.toNat + width ≤ 0x80020000`. Any access outside
   the 64 KiB payload region is denied by hardware.
3. **`monitor_zeroization_thm`**:
   The monitor's exit sequence clears every general-purpose register `x1..x9` and `x11..x31`
   to zero (`∀ r, r.toNat ≠ 10 → zeroizeRegs regs r = 0`), leaving only `a0` intact.
4. **`monitor_forwarding_thm`**:
   The exit code passed in `a0` (x10) is preserved across zeroization.
5. **`monitor_instruction_count_thm`**:
   While `mcountinhibit` is active (`cy = true, ir = true`), `bumpCounters` increments neither
   `minstret` nor `mcycle`. Monitor instructions produce zero counter leakage.

## Mutants Refuted (`proof/mutants.txt`)

Five incorrect specifications and faulty properties are checked and refused by Lean:
- `isolation_inverted`: PMP domain isolation claiming out-of-bounds addresses are accepted.
- `zeroization_skips_registers`: Secret zeroization claiming GP registers are preserved instead of cleared.
- `forwarding_clears_exit_code`: Status forwarding claiming `a0` is overwritten with zero.
- `counters_minstret_leak`: Hardware counters claiming `minstret` advances while inhibited.
- `counters_mcycle_leak`: Hardware counters claiming `mcycle` advances while inhibited.

## Evaluation: Cryptographic Payload & Adversarial Attacks

1. **Normal Cryptographic Execution (`cases/normal_cases.py`)**:
   Runs `monitor.bin` combined with `exp229`'s 458-instruction secp256k1 field arithmetic kernel
   under the PMP sandbox:
   - `op = 0` (addition): $42 + 58 = 100 \pmod p$
   - `op = 1` (subtraction): $100 - 42 = 58 \pmod p$
   - `op = 1` (subtraction with borrow): $(10 - 20) \equiv p - 10 \pmod p$
   - `op = 2` (multiplication): $0x12345678 \times 0x87654321 \pmod p$
   All four cases succeed with exit code `a0 = 0`, correct 256-bit result words, and
   all registers `x1..x9` and `x11..x31` completely scrubbed.

2. **Adversarial Attack Suite (`cases/attack_cases.py`)**:
   Five hostile payloads attacking the monitor boundary:
   - **Attack 1 (Code Overwrite)**: Payload writes to `0x80000000` (monitor base).
     PMP triggers `mcause = 7` (Store Access Fault), monitor halts with exit code 1;
     monitor code at `0x80000000` remains intact.
   - **Attack 2 (Privilege Escalation)**: Payload executes `csrr t0, mstatus`.
     Hardware raises `mcause = 2` (Illegal Instruction), monitor halts with exit code 1.
   - **Attack 3 (Secret Exfiltration)**: Payload reads `0x20000000` (system SRAM).
     PMP triggers `mcause = 5` (Load Access Fault), monitor halts with exit code 1.
   - **Attack 4 (Control Flow Escape)**: Payload executes `jalr x0, 0(t0)` to `0x80000040`.
     PMP triggers `mcause = 1` (Fetch Access Fault), monitor halts with exit code 1.
   - **Attack 5 (Confused Deputy)**: Payload issues `ecall` with invalid syscall ID `0x1337`.
     Monitor rejects the call, emits `TAG_FAULT`, and halts with exit code 1.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp236 — the wall the monitor holds ===
recorded at 2026-10-16T01:34:55Z from commit 39d20cc

>>> the micro-monitor binary and size budget
PASS  monitor.bin (584 bytes, 146 insts) matches monitor.S and monitor.sha256

>>> the formal theorems, and what they rest on
'Exp236.monitorCode_length' does not depend on any axioms
'Exp236.monitor_isolation_thm' depends on axioms: [propext, Quot.sound]
'Exp236.monitor_zeroization_thm' depends on axioms: [propext]
'Exp236.monitor_forwarding_thm' depends on axioms: [propext]
'Exp236.monitor_instruction_count_thm' does not depend on any axioms
exit 0

>>> wrong monitor properties: each must be refused
isolation_inverted           PMP domain isolation claims out-of-bounds addresses are accepted               refused in monitor_isolation_thm
zeroization_skips_registers  Secret zeroization claims other GP registers are preserved instead of zeroed   refused in zeroizeRegs_others
forwarding_clears_exit_code  Exit status forwarding claims a0 is overwritten with 0 instead of preserved    refused in zeroizeRegs_a0
counters_minstret_leak       Counters claim minstret increments even when mcountinhibit has ir=true         refused in monitor_instruction_count_thm
counters_mcycle_leak         Counters claim mcycle increments even when mcountinhibit has cy=true           refused in monitor_instruction_count_thm

>>> normal execution: secp256k1 field arithmetic under PMP sandbox
PASS  4 normal cases verified (exp229 add/sub/mul, a0=0, secret scrubbed)

>>> adversarial attack test suite: 5 hostile U-mode attacks
PASS  5 adversarial attacks caught and rejected by Micro-Monitor:
      1. Store to monitor code (0x80000000) -> mcause=7 (Store Access Fault), exit=1
      2. CSR read from U-mode (mstatus)     -> mcause=2 (Illegal Instruction), exit=1
      3. Load from out-of-bounds (0x20000000) -> mcause=5 (Load Access Fault), exit=1
      4. Execution escape (0x80000040)      -> mcause=1 (Fetch Access Fault), exit=1
      5. Invalid syscall id (0x1337)        -> syscall rejected, fault exit=1

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  monitor.bin (584 bytes, 146 insts) matches monitor.S and monitor.sha256
PASS  Monitor.lean checks, with no errors and no warnings
PASS  all 5 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  isolation_inverted: the proof refuses a version where PMP domain isolation claims out-of-bounds addresses are accepted
PASS  zeroization_skips_registers: the proof refuses a version where Secret zeroization claims other GP registers are preserved instead of zeroed
PASS  forwarding_clears_exit_code: the proof refuses a version where Exit status forwarding claims a0 is overwritten with 0 instead of preserved
PASS  counters_minstret_leak: the proof refuses a version where Counters claim minstret increments even when mcountinhibit has ir=true
PASS  counters_mcycle_leak: the proof refuses a version where Counters claim mcycle increments even when mcountinhibit has cy=true
PASS  4 normal cases verified (exp229 add/sub/mul, a0=0, secret scrubbed)
PASS  5 adversarial attacks caught and rejected by Micro-Monitor:
      1. Store to monitor code (0x80000000) -> mcause=7 (Store Access Fault), exit=1
      2. CSR read from U-mode (mstatus)     -> mcause=2 (Illegal Instruction), exit=1
      3. Load from out-of-bounds (0x20000000) -> mcause=5 (Load Access Fault), exit=1
      4. Execution escape (0x80000040)      -> mcause=1 (Fetch Access Fault), exit=1
      5. Invalid syscall id (0x1337)        -> syscall rejected, fault exit=1
```
