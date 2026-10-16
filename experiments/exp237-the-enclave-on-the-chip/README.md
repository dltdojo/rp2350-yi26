# exp237 — the enclave on the chip

<!-- SPDX-License-Identifier: Apache-2.0 -->

**The formally verified Micro-Monitor on physical RP2350 Pico 2 silicon: a 147-instruction,
588-byte M-mode monitor hosting exp229's proved secp256k1 field arithmetic kernel inside a
hardware-enforced 64 KiB NAPOT PMP sandbox at `0x20010000`. Built entirely in pure C and RV32
assembly with zero dynamic allocation or Rust runtime dependencies into a 12 KiB flash image.
The monitor executes the full enclave lifecycle on silicon: configuring PMP Domain 1, switching
to U-mode via `mret`, trapping ecall completions back to M-mode, recording cycle counts and
exact instruction retirement counts (add: 331 insts, sub: 238 insts, mul: 1903 insts), and
zeroizing all caller-saved registers before returning cleanly to the C shell. USB CDC / WebUSB
stream verified via `enclave.html`.**

Needs: a **Pico 2**, a hand on **BOOTSEL** once to copy `exp237.uf2` on, and a **phone or computer
with Chrome** holding `enclave.html` to tap the USB permission.

## What is new, and what is not

| | Where it comes from |
| :--- | :--- |
| the privileged machine model and Lean U-mode refinement proofs | exp235: `lean/Rv32/Privileged.lean`, `proof/PrivilegedRefinement.lean` |
| the formal monitor specification and theorems | exp236: `proof/Monitor.lean`, `lean/Rv32/Sandbox.lean` |
| the secp256k1 field arithmetic kernel (`kernel.bin`, 2080 bytes) | exp229: `kernel.bin` |
| the chip startup and flash packaging | `tools/hazard3/shell`: `start_chip.S`, `link_chip.ld`, `uf2check.py` |
| the zero-allocation USB CDC logging stack | `tools/hazard3/shell/speak.h` |
| the silicon monitor implementation (`shell/monitor_chip.S`, 147 instructions) | **here**: `shell/monitor_chip.S` |
| the pure C launcher and test harness | **here**: `shell/enclave.c`, `shell/mem_layout.h`, `shell/board_chip.c` |
| the WebUSB test appliance | **here**: `enclave.html`, `page_test.mjs` |

## Memory Map

Physical SRAM partitions on the RP2350 (Hazard3 core):

```
0x20000000 .. 0x2000ffff  Domain 0: M-mode Micro-Monitor (64 KiB)
  0x20000000              Monitor base address
  0x20000020              launch_enclave() C callable entry point
  0x20000040              _reset cold boot entry point
  0x20000114              trap_handler (mtvec)
  0x20000400              Mailbox: status report (a0, minstret, mcycle, fault flag)
  0x20000420              Host context save area (sp, ra)
  0x20008000              Trap scratch stack (mscratch)

0x20010000 .. 0x2001ffff  Domain 1: U-mode Enclave Sandbox (64 KiB NAPOT)
  0x20010000              Payload entry point & code (exp229 kernel)
  0x20010800              Operands (op, a, b, R buffers)
  0x20020000              Payload U-mode top of stack

0x20020000 .. 0x20030000  Host C Shell Stack & BSS
  0x20030000              MSTACK (top of host stack)
```

## Monitor Lifecycle on Silicon

```
1. C Launcher (M-mode) copies monitor_chip.bin to 0x20000000 and payload to 0x20010000.
2. C Launcher calls launch_enclave() at 0x20000020.
3. launch_enclave:
   - Saves host sp and ra to mailbox (0x20000420 / 0x20000424).
   - Writes pmpaddr0 = 0x08005fff (64 KiB NAPOT matching 0x20010000..0x2001ffff).
   - Writes pmpcfg0 = 0x1f (NAPOT, RWX, locked).
   - Sets mtvec = 0x20000114, mscratch = 0x20008000.
   - Clears minstret and mcycle counters.
   - Sets mepc = 0x20010000, mstatus.MPP = 0 (User mode).
   - Scrubs all general-purpose registers (x1, x3..x31 = 0, sp = 0x20020000).
   - Executes mret to transition into U-mode inside the PMP sandbox.
4. Payload executes exp229 secp256k1 field arithmetic (add / sub / mul).
   - Attempts to access memory outside 0x20010000..0x2001ffff trigger PMP access faults.
   - On completion, payload executes ecall with a0 = 0.
5. trap_handler:
   - Freezes counters (mcountinhibit = 5).
   - Swaps sp with mscratch.
   - Saves t0 and t1, inspects mcause.
   - If mcause == 8 (Environment call from U-mode) and saved t0 == 1 (SYS_HALT):
       writes clean HALT report, minstret, and mcycle to mailbox.
     Else:
       writes FAULT report, a0 = 1.
   - Scrubs all caller-saved registers (x1..x9, x11..x31 = 0).
   - Restores host sp and ra from mailbox.
   - Executes ret back to C Launcher in M-mode with return status in a0.
```

## Hardware Execution Results

Every secp256k1 field operation matches exp229's Lean formal verification theorems down to the exact instruction count:

```text
ENCLAVE boot=ok monitor=147_insts pmp=64k_napot
OP add a0=0 minstret=331 cycles=370 status=OK
OP sub a0=0 minstret=238 cycles=266 status=OK
OP mul a0=0 minstret=1903 cycles=1979 status=OK
STATUS PASS secrets_scrubbed=ok
```

- Addition: exact 331 instructions retired (`minstret = 331`).
- Subtraction: exact 238 instructions retired (`minstret = 238`).
- Multiplication: exact 1903 instructions retired (`minstret = 1903`).
- Secret scrubbing: all caller registers zeroized on exit from enclave.

## Expected output

Pasted from `capture.txt`, recorded by `./run.sh`:

```text
=== exp237 — the enclave on the chip ===
recorded at 2026-10-16T05:52:48Z from commit 6694915

>>> the shell, for the chip
Generated build/payload.h (monitor: 588 B, kernel: 2080 B)
build/exp237.bin  12088 bytes, the build allows 16384
build/exp237.uf2  24576 bytes  sha256 077351453efa1e448136ea9c41d5ab1c53d3dc5662c892c56e351840989936ea

>>> the checks
PASS  no lifeline, and it says why: a C shell, not crates/lifeline — BOOTSEL by hand is the way back
PASS  the page's script parses (node --check)
PASS  findCdc is tools/pages/log.html's, byte for byte
PASS  enclave boots with boot=ok
PASS  PMP sandbox configured as 64k_napot
PASS  monitor verified at 147 instructions
PASS  all 3 secp256k1 operations reported
PASS  enclave overall status is PASS
PASS  all secret registers scrubbed
PASS  enclave execution complete and verified
PASS  catches wrong minstret count
PASS  catches non-zero a0 return
PASS  catches failed operation status
PASS  the shell builds for the chip into 12088 of the 16384 bytes it may use
PASS  all 48 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 16 KiB of flash, 0x10000000..0x10004000
PASS  together they are exactly the 12088-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20030000
PASS  the UF2 is byte for byte the committed one: 077351453efa1e44…
PASS  board/capture.txt exists and records verified physical silicon capture
```
