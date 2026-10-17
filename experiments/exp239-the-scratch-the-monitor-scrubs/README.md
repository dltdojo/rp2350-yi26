# exp239 — the scratch the monitor scrubs

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Status: TODO (scaffold).** For the design, see
[`docs/micro-monitor/2026-10-16-micro-monitor-workload-migration-design-zh-tw.md`](../../docs/micro-monitor/2026-10-16-micro-monitor-workload-migration-design-zh-tw.md),
section 四, and its correction (第 4 小節, 2026-10-17), which this scaffold follows.

## Overview

This experiment runs [`exp223-the-digest-the-kernel-withholds`](../exp223-the-digest-the-kernel-withholds/)'s
**NIST SP 800-90B continuous health tests (RCT + APT) and SHA-256 conditioner kernel** under an M-mode
micro-monitor that also scrubs the payload's memory on the way out.

exp236's monitor scrubs the registers but leaves the payload's SRAM as the payload left it. For an entropy
conditioner that leaves the raw samples (`+0x3000..+0x4000`) and the SHA-256 schedule (`+0x2200..+0x2440`) in
memory after it halts. This monitor zeroes the confidential region `+0x2200..+0x4000` on every exit, and on
every exit that is not a clean `HALT 0` — a failed health test or any fault — the 32-byte digest window
`+0x2140..+0x2160` as well: only a payload that passed and halted cleanly leaves a digest behind.

Needs: **no board**.

## Decided before starting

- **The base is exp236's monitor, not exp238's.** exp223's kernel computes SHA-256 itself and asks the
  monitor for nothing but HALT. exp238's monitor is already 200 words; exp236's is 143, which leaves room
  for the scrub inside the 200-word budget.
- **The scrub is a loop, and the proof needs a loop lemma.** 1,920 words cannot be proved by stepping
  through them one at a time the way exp238's generator does; a loop invariant has to say that on exit every
  byte of the region is 0 and nothing outside it changed.
- **The kernel's correctness is not joined to this proof.** exp223's kernel theorems need a 128 KiB region;
  the monitor's box is 64 KiB. The kernel touches nothing above `+0x4000`, so it runs in the box, but its
  theorems do not apply there. As in exp238: the monitor's behaviour is proved in Lean; the kernel's result
  under the monitor is compared byte for byte, on the emulator, with the kernel run with no monitor.
- **No chip.** There is no chip build of this monitor; exp237's `monitor_chip.S` is derived from exp236's
  and unproved. A chip port is a later experiment.
- Addresses are the model's: the box is `0x80010000..0x80020000`, as in exp236 and exp238.

## TODO

- [ ] **`monitor.S` / `monitor.bin`**, from exp236's
  - [ ] In `scrub_exit`, a bounded loop that zeroes `+0x2200..+0x4000` on every exit.
  - [ ] When the exit code is not 0, or the exit is a fault, zero `+0x2140..+0x2160` too.
  - [ ] Within 200 words.
- [ ] **Lean 4 proof**
  - [ ] A loop lemma for the zeroing loop: on exit every byte of the range is 0, memory outside it unchanged.
  - [ ] `monitor_fail_closed_scrub`: a fault, or a HALT with `a0 ≠ 0`, parks with every register but `a0`
        zero, every byte of the confidential region and of the digest window zero.
  - [ ] `monitor_pass_digest_kept`: a HALT with `a0 = 0` parks with the confidential region zero and the
        32 digest bytes as the payload left them.
  - [ ] End to end from reset, as exp236's.
- [ ] **On the emulator (`check.sh`)**
  - [ ] exp223's `kernel.bin` with healthy, stuck-at-1 and biased streams: the pass path (HALT 0 after
        334,284 instructions) keeps the digest and clears the scratch; the fail path (HALT 1 after
        17,425) leaves both zero; each compared with the kernel run alone.
  - [ ] Broken monitors (a loop one word short, the digest kept on a failure, a fault that skips the
        memory scrub), each caught.
