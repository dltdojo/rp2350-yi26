# exp239 — the scratch the monitor scrubs

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Status: TODO (scaffold).** For the full design, see
[`docs/micro-monitor/2026-10-16-micro-monitor-workload-migration-design-zh-tw.md`](../../docs/micro-monitor/2026-10-16-micro-monitor-workload-migration-design-zh-tw.md).

## Overview

This experiment migrates [`exp223-the-digest-the-kernel-withholds`](../exp223-the-digest-the-kernel-withholds/)'s
**NIST SP 800-90B continuous health tests (RCT + APT) and SHA-256 conditioner kernel** (8,484 bytes)
to run inside the M-mode Micro-Monitor (`monitor.bin`) sandbox.

In `exp236` and `exp237`, `monitor.bin` scrubs general-purpose registers `x1..x9, x11..x31` on exit
but leaves payload SRAM untouched. For an entropy conditioner or secret-holding workload, leaving
raw unconditioned entropy samples (`+0x3000..0x4000`) and SHA-256 message schedule scratch words
(`+0x2200..0x2440`) in SRAM after exit leaks confidential intermediate state. Furthermore, when the
health tests fail (`HALT 1` after 17,425 instructions) or a hardware trap occurs, the M-mode
monitor itself should enforce a **fail-closed output wipe** by zeroing the 32-byte digest output
buffer (`+0x2140..0x2160`) before parking or returning.

Needs: **no board** (scaffold).

## TODO

- [ ] **Extend `monitor.S` / `monitor.bin` (Memory-Scrubbing & Fail-Closed Monitor)**
  - [ ] Partition the sandbox data region into a public digest output window (`+0x2140..0x2160`)
        and a confidential scratch/sample region (`+0x2200..0x4000`).
  - [ ] Add a bounded zeroization loop in `scrub_exit` that overwrites the confidential scratch
        SRAM region with zeros (`sw x0, 0(t0)`) on every exit.
  - [ ] Enforce privilege-level fail-closed wiping: whenever the exit code `a0 != 0` or any fault
        trap occurs, unconditionally zeroize the 32-byte public digest output window as well.
- [ ] **Lean 4 Proofs (`proof/Monitor.lean`)**
  - [ ] Prove `monitor_fail_closed_scrub`: when `a0 != 0` or a fault occurs, the parked state has
        all general-purpose registers (except `a0`), all confidential scratch bytes, and all 32
        digest output bytes equal to `0`.
  - [ ] Prove `monitor_pass_digest_kept`: when the payload halts cleanly (`t0 = 1, a0 = 0` after
        334,284 instructions), confidential scratch bytes are zeroized while the 32-byte SHA-256
        digest in the output window is preserved intact.
- [ ] **End-to-End Verification (`check.sh`)**
  - [ ] Run `exp223`'s `kernel.bin` against healthy entropy, stuck-at-1 entropy, and biased
        entropy streams under the monitor, verifying both the 334,284-instruction pass path and the
        17,425-instruction fail-closed path.
