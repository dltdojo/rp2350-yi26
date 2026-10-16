# exp240 — the code the box forbids writing

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Status: TODO (scaffold).** For the full design, see
[`docs/micro-monitor/2026-10-16-micro-monitor-workload-migration-design-zh-tw.md`](../../docs/micro-monitor/2026-10-16-micro-monitor-workload-migration-design-zh-tw.md).

## Overview

This experiment migrates [`exp225-the-life-every-beat-proved`](../exp225-the-life-every-beat-proved/)'s
**Rule 30 cellular automaton kernel** (76 bytes, 3,079 instructions per round generating 256
generations of 32-bit words, where generation 256 feeds the next round's seed) to run inside the
M-mode Micro-Monitor (`monitor.bin`) sandbox.

In `exp236` and `exp237`, `monitor.bin` configures a single 64 KiB `NAPOT` PMP entry with full
`RWX` permissions (`pmpcfg0 = 0x1F`), which does not enforce **W^X (Write XOR Execute)** and allows
a buggy or compromised U-mode payload to overwrite its own instructions. This experiment activates
three `NAPOT` entries in `pmpcfg0` (`0x001B1B1D`) to enforce hardware W^X and stack isolation:

- **Entry 0 (Code, `0x20010000..0x20011000`, 4 KiB)**: `NAPOT`, **`R+X, !W`** (`0x1D`) — U-mode
  code is read/execute only; any store into code triggers a Store Access Fault (`mcause = 7`).
- **Entry 1 (Data / I/O, `0x20011000..0x20012000`, 4 KiB)**: `NAPOT`, **`R+W, !X`** (`0x1B`) —
  holds the round seed (`+0x100`) and 256-generation output (`+0x200..0x600`); non-executable.
- **Entry 2 (Stack, `0x2001F000..0x20020000`, 4 KiB)**: `NAPOT`, **`R+W, !X`** (`0x1B`) — isolated
  U-mode stack separated from Data by an unmapped 52 KiB hardware guard region (`0x20012000..0x2001F000`).

Needs: **no board** (scaffold).

## TODO

- [ ] **Extend `lean/Rv32/Sandbox.lean` and `monitor.S` (Multi-Entry W^X PMP Monitor)**
  - [ ] Configure `pmpaddr0`, `pmpaddr1`, `pmpaddr2` and `pmpcfg0 = 0x001B1B1D` during monitor boot.
  - [ ] Define the `WXBoxed` invariant in `lean/Rv32/Sandbox.lean` over the three disjoint `NAPOT`
        regions.
- [ ] **Lean 4 Proofs (`proof/Monitor.lean`)**
  - [ ] Prove `wx_no_write_exec`: under `WXBoxed`, no 32-bit address simultaneously satisfies
        `pmpCheck ... .Fetch = true` and `pmpCheck ... .Store = true`.
  - [ ] Prove `wx_code_immutable`: under `WXBoxed`, for any number of U-mode steps, every byte in
        the code region `[codeLo, codeHi)` remains identical to its initial value by hardware PMP
        enforcement alone.
  - [ ] Prove `monitor_reentry_invariant`: across repeated multi-round invocations, CSRs and the
        `WXBoxed` configuration are preserved without state leakage.
- [ ] **End-to-End Verification (`check.sh`)**
  - [ ] Run multi-round Rule 30 evolution under the monitor, verifying SHA-256 life histories,
        exact `minstret` counts (3,079 per round), and hardware trap interception on self-modifying
        code stores, data execution attempts, and stack guard-page overflows.
