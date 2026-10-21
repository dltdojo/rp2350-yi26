# exp245 — the bytes the proof blesses

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Status: TODO (scaffold).** The design plan and the conceptual discussion are in
[`DESIGN.zh-TW.md`](./DESIGN.zh-TW.md) and [`WHY.zh-TW.md`](./WHY.zh-TW.md).

## Overview

In Tokyo's Kanda Myojin shrine, engineers buy the *IT Information Security Omamori* (IT情報安全守護) —
a green PCB-styled charm with an IC silhouette, packaged with two stickers for laptops and servers.
In Taiwan's server rooms, engineers place a green pack of *Kuai Kuai* (綠色乖乖) on top of machines so
the light stays green. Both are physical tokens of comfort against crashes, leaks and failures.

Formal verification can become a digital *omamori* — **verification theater** — when a proof is treated
as a badge rather than read as a conditional statement. Every word of the machine code is fetched,
executed, counted in `minstret`, and backed by a Lean 4 theorem with zero `sorryAx` and zero custom
axioms, and mutating any of those words makes Lean refuse the proof — yet the bytes do nothing at all
for the security property a user believes is protected.

This experiment builds one RISC-V M-mode monitor (`monitor.bin`, extending the track of
[exp236](../exp236-the-wall-the-monitor-holds/), [exp238](../exp238-the-call-the-monitor-checks/),
[exp239](../exp239-the-scratch-the-monitor-scrubs/) and [exp240](../exp240-the-code-the-box-forbids-writing/))
that carries **four formally verified charms** (three structural boundary gaps + one literal IT
*omamori* seal):

1. **Charm 1 — The Literal IT Omamori Seal (`0x4F4D414D` `"OMAM"` / `0x4B554149` `"KUAI"`):**
   Boot writes the 8-byte sacred seal into the monitor's altar (`0x80008010..0x80008018`), and the
   trap handler verifies both words before reporting a clean `HALT`. Lean proves `seal_intact_on_halt`:
   no run can report a clean halt unless the sacred seal is intact. Yet the seal sits in M-mode memory
   that U-mode cannot reach anyway, while the payload's own code and data inside the box can be
   corrupted at will without disturbing a single bit of the seal.
2. **Charm 2 — The Shadowed PMP Wall (`pmpaddr1` / `pmpcfg0` Entry 1):**
   Boot configures PMP Entry 1 to make the payload's code window `[0x80010000, 0x80010080)` read-execute
   only (`W = 0`). Lean proves `entry1_forbids_code_store`: `pmpEntryCheck` on Entry 1 rejects every
   store into the code window, and a mutant that sets `W = 1` on Entry 1 is refused by Lean. Yet Entry 0
   is `exp236`'s 64 KiB `RWX` entry (`[0x80010000, 0x80020000)`), and RISC-V's priority rule
   (*lowest-numbered matching entry wins*) means Entry 0 grants the store before Entry 1 is ever
   consulted. Self-modifying code overwrites the payload's instructions and exits cleanly.
3. **Charm 3 — The Ceremonial Scrub (`[+0x2180, +0x21a0)` Sacred Key Slot):**
   On exit, the monitor runs a verified zeroing loop over the 32-byte "Sacred Key Slot" at
   `[0x80012180, 0x800121a0)`. Lean proves `sacred_slot_zeroed`: on every halt and every fault, all 32
   bytes of the slot are zero when the machine parks. Yet the payload's actual working secret lives on
   its stack at `[0x8001ffc0, 0x80020000)` — inside the proof's `Frame` (the "untouched" clause that
   sounds like a preservation guarantee) — and survives intact for the next caller to read.
4. **Charm 4 — The Echoed Rubber-Stamp (`VERIFY_CHARM` Syscall, `t0 = 4`):**
   A non-halting syscall checks that a 32-byte buffer lies inside the box, writes the call number `4`
   to the service port word `0xc000001c`, reads `a0` back from `0xc000001c`, and checks `a0 != 0`.
   Because the formal model treats the service port as plain RAM, Lean proves `verify_charm_always_passes`:
   any in-box call returns `a0 = 4` (non-zero, "verified") — proving a rubber stamp by modeling MMIO as
   ordinary memory.

Needs: **no board** (scaffold, and the finished experiment).

## Documents in this directory

- [`WHY.zh-TW.md`](./WHY.zh-TW.md) — Concept discussion: Kanda Myojin's *IT Information Security Omamori*,
  Taiwan's green *Kuai Kuai*, Verification Theater, and why a machine-checked theorem can be 100% true
  and 0% protective.
- [`DESIGN.zh-TW.md`](./DESIGN.zh-TW.md) — Detailed technical design plan: memory map, assembly layout of
  `monitor.S`, the exact Lean 4 theorem statements and `mutants.txt` entries, and the emulator attack
  suite that breaks all four charms while every theorem holds.

## TODO

- [ ] **`monitor.S` & `monitor.bin`**: assemble the 4-charm monitor (~185 words) and pin its SHA-256.
- [ ] **`proof/Bless.lean` & `proof/gen.py`**: prove all four charm theorems alongside the monitor's
      end-to-end execution theorems on `Lean`'s own axioms (`propext`, `Classical.choice`, `Quot.sound`).
- [ ] **`proof/mutants.txt`**: ~16 mutants showing Lean actively guarding the useless bytes (refusing
      a wrong magic constant, a writable Entry 1, a short scrub loop, or a skipped port check).
- [ ] **`suite/charms_audit.py`**: pair each charm's theorem with the concrete exploit payload on the
      emulator that bypasses it while the theorem's postcondition holds verbatim, plus the counter-fix
      referenced from `exp238` / `exp239` / `exp240`.
- [ ] `check.sh`, `run.sh`, `capture.txt`, index row updated from scaffold to completed.

