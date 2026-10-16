# exp238 — the call the monitor checks

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Status: TODO (scaffold).** For the full design, see
[`docs/micro-monitor/2026-10-16-micro-monitor-workload-migration-design-zh-tw.md`](../../docs/micro-monitor/2026-10-16-micro-monitor-workload-migration-design-zh-tw.md).

## Overview

This experiment migrates [`exp228-the-script-the-kernel-runs`](../exp228-the-script-the-kernel-runs/)'s
**Bitcoin Tapscript interpreter** (881 RV32IM instructions) to run inside the formally verified
M-mode Micro-Monitor (`monitor.bin`) sandbox.

In `exp236` and `exp237`, `monitor.bin` supports only a single-shot halting call (`ecall` with
`t0 = 1`, `SYS_HALT`); any other `t0` value is treated as a fault and terminates the payload.
However, `exp228` invokes two non-halting system calls partway through script evaluation:

- **`ecall t0 = 2` (`HASHB`)**: compute SHA-256 over `a1` bytes at `a0` and write the 32-byte
  digest to `a2`.
- **`ecall t0 = 3` (`CHECKSIG`)**: verify a 64-byte BIP340 signature at `a1` against a 32-byte
  public key at `a0`, returning `1` (valid) or `0` (invalid) in `a0`.

This experiment extends `monitor.bin` and its Lean 4 proofs to support bidirectional non-halting
system calls, overflow-safe **Confused-Deputy PMP pointer bounds checking**, and resuming U-mode
execution at `mepc + 4` via `mret` with a proved constant `minstret` overhead.

Needs: **no board** (scaffold).

## TODO

- [ ] **Extend `monitor.S` / `monitor.bin` (Interactive Syscall Monitor)**
  - [ ] Save and restore the full U-mode general-purpose register frame in `mscratch` (`0x80008000`).
  - [ ] Implement overflow-safe unsigned subtraction bounds checking (`pmp_bounds_check`) verifying
        that `[a0, a0 + a1)` and output buffers lie entirely within `[BOX_LO, BOX_HI)`.
  - [ ] Dispatch `t0 = 2` (`HASHB`) and `t0 = 3` (`CHECKSIG`), advance `mepc <- mepc + 4`,
        unfreeze counters (`csrwi mcountinhibit, 0`), and return to U-mode via `mret`.
- [ ] **Lean 4 Proofs (`proof/Monitor.lean`)**
  - [ ] Prove `monitor_hashb_ok` and `monitor_checksig_ok`: in-bounds syscalls advance `mepc` by 4
        and return to U-mode preserving `UBoxed`.
  - [ ] Prove `monitor_confused_deputy_reject`: out-of-bounds or wraparound pointers (`a0 + a1 >= 2^32`)
        branch to `handle_fault` without reading or writing outside the sandbox, then scrub all
        registers and park.
  - [ ] Prove `monitor_syscall_instret`: each trap-and-return cycle increments `minstret` by an
        exact architectural constant.
- [ ] **End-to-End Verification (`check.sh`)**
  - [ ] Run `exp228`'s `kernel.bin` and 34 test scripts plus out-of-bounds syscall payloads under
        the monitor and verify all verdicts and instruction counts.

- [ ] **Extend `monitor.S` / `monitor.bin` (Interactive Syscall Monitor)**
  - [ ] Save and restore the full U-mode general-purpose register frame in `mscratch` (`0x80008000`).
  - [ ] Implement overflow-safe unsigned subtraction bounds checking (`pmp_bounds_check`) verifying
        that `[a0, a0 + a1)` and output buffers lie entirely within `[BOX_LO, BOX_HI)`.
  - [ ] Dispatch `t0 = 2` (`HASHB`) and `t0 = 3` (`CHECKSIG`), advance `mepc <- mepc + 4`,
        unfreeze counters (`csrwi mcountinhibit, 0`), and return to U-mode via `mret`.
- [ ] **Lean 4 Proofs (`proof/Monitor.lean`)**
  - [ ] Prove `monitor_hashb_ok` and `monitor_checksig_ok`: in-bounds syscalls advance `mepc` by 4
        and return to U-mode preserving `UBoxed`.
  - [ ] Prove `monitor_confused_deputy_reject`: out-of-bounds or wraparound pointers (`a0 + a1 >= 2^32`)
        branch to `handle_fault` without reading or writing outside the sandbox, then scrub all
        registers and park.
  - [ ] Prove `monitor_syscall_instret`: each trap-and-return cycle increments `minstret` by an
        exact architectural constant.
- [ ] **End-to-End Verification (`check.sh`)**
  - [ ] Run `exp228`'s `kernel.bin` and 34 test scripts plus out-of-bounds syscall payloads under
        the monitor and verify all verdicts and instruction counts.

