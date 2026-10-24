# exp237 — the enclave on the chip

<!-- SPDX-License-Identifier: Apache-2.0 -->

**A 162-word, 676-byte M-mode monitor, derived from exp236's, that runs exp229's secp256k1
field kernel in U-mode behind a 64 KiB NAPOT PMP entry, loaded by a C shell for the Pico 2 and
checked by what it reads back: the PMP registers as the core kept them, the kernel's result
words, every register after the monitor returns, and the monitor's own bytes after three payloads
attack it. Not run on a board. On the emulator, everything holds and nine broken monitors are
caught; what the silicon does is what a first capture is for.**

Needs: a **Pico 2**, a hand on **BOOTSEL** once to copy `exp237.uf2` on, and a **phone or computer
with Chrome** holding `enclave.html` to tap the USB permission. The checks that need none of it
(`./check.sh`) pass today.

## What this is not

- **Not proved.** exp236's Lean theorems are about `exp236/monitor.bin`, at `0x80000000`, which
  parks. `shell/monitor_chip.S` is a different program: another base, a mailbox in SRAM instead of a
  print port, and a return to its C caller with the caller's registers back. None of that is in
  Lean. What backs it is `emutest.py`.
- **Not run on the chip.** There is no `board/capture.txt`. The emulator counts every retired
  instruction as one cycle and has no USB; the chip may count the monitor's `csrwi`/`mret` framing
  differently (see *The counts*).
- Not exp236's instruction count: the 162 words here are the words of `monitor_chip.S` that are not
  `.org` padding, counted by `gen.py` — they are not the 147 an earlier revision of this file printed
  (that was the file's size divided by four, padding included, and it was a constant in the C).

## What is new, and what is not

| | Where it comes from |
| :--- | :--- |
| the privileged machine model and Lean U-mode refinement proofs | exp235: `lean/Rv32/Privileged.lean`, `proof/PrivilegedRefinement.lean` |
| the idea of the monitor, its specification and theorems | exp236: `proof/Monitor.lean`, `lean/Rv32/Sandbox.lean` — **for exp236's monitor, not this one** |
| the secp256k1 field arithmetic kernel (`kernel.bin`, 2080 bytes) | exp229: `kernel.bin` |
| the chip startup, flash packaging and zero-allocation USB CDC logging | `tools/hazard3/shell`: `start_chip.S`, `link_chip.ld`, `uf2check.py`, `speak.h` |
| the emulator the monitor is run on | `tools/monitor/emulator.py` (exp236's) |
| the silicon monitor | **here**: `shell/monitor_chip.S` |
| three attack payloads and a canary, the C launcher and its register probe | **here**: `shell/payload_*.S`, `shell/enclave.c`, `shell/board_chip.c`, `shell/mem_layout.h` |
| the offline test with mutants | **here**: `emutest.py` |
| the WebUSB page and its test | **here**: `enclave.html`, `page_test.mjs` |

## Memory map

`shell/mem_layout.h` is the one place the addresses are written; the monitor and the payloads
include it. The shell's own `.bss` starts at `0x20000000` and its stack grows down from
`0x20030000`, so the monitor and the sandbox sit above both.

```
0x20000000 ..           the shell's .bss (report, USB state)      <- not touched by the monitor
0x20030000              top of the shell's stack
0x20040000              monitor base            (64 KiB window, zeroed before the copy)
  +0x00                   _start: j _reset
  +0x20                   launch_enclave(): the C-callable entry
  +0x400                  report: tag exit_code minstret mcycle mcause mepc mtval
  +0x420                  boot readback: pmpcfg0, pmpaddr0
  +0x440                  host context: sp ra gp tp s0..s11 mcountinhibit
  +0x8000                 trap stack (mscratch while the payload runs)
0x20050000 .. 0x2005ffff  sandbox, 64 KiB, one NAPOT entry (pmpaddr0 = 0x08015fff, pmpcfg0 = 0x1f)
  +0x0000                 payload code (the kernel)
  +0x0800                 PRIME; +0x900 op, +0x904 a, +0x924 b, +0x944 result (exp229's layout)
0x20060000              sandbox stack top
```

`pmpcfg0 = 0x1f` is NAPOT, RWX, **not** locked, so it constrains U-mode and leaves M-mode alone.

## What `launch_enclave` does

1. Saves the caller's `sp ra gp tp s0..s11` and `mcountinhibit` at `+0x440`.
2. Freezes the counters, writes `pmpaddr0`/`pmpcfg0`, **reads both back** into `+0x420`.
3. Sets `mtvec`, `mscratch`, `mepc = 0x20050000`, `mstatus.MPP = U`, zeroes the counters and all
   registers, unfreezes, `mret`.
4. On the payload's trap the handler freezes the counters, and reports: `ecall` with `t0 = 1` is a
   HALT (tag `HALT`, exit code `a0`); anything else — an access fault, an `ecall` with another number —
   is a FAULT (tag `FAUL`, `a0 = 1`, with `mcause`, `mepc`, `mtval`).
5. Then it takes nothing of the payload's with it: the two saved words and `mscratch` zeroed, PMP
   entry 0 cleared, the caller's `mcountinhibit`, `sp ra gp tp s0..s11` restored, every other
   caller-saved register but `a0` zeroed, `ret`.

An earlier revision zeroed `s0..s11` too and restored only `sp` and `ra`; the C caller then read its
own saved values back as zero. `probe_launch` in `enclave.c` exists so that cannot go unnoticed: it
loads `s1..s11` with known values before the call and counts the ones that did not come back.

## What the shell checks

Every line of the report is a number read back from the machine:

| line | what it was read from, and what must hold |
| :--- | :--- |
| `ENCLAVE … pmpcfg0=… pmpaddr0=… pmp=` | the monitor read both CSRs back after writing them: `0x1f` and `0x08015fff`, else `pmp=BAD` |
| `OP add/sub/mul` | `a0 = 0`, tag HALT, the eight result words equal to Python's, `minstret` within 0..8 of exp229's count (331, 238, 1903) and the same on a second run, every caller-saved register zero after the return |
| `TEST scrub` | a canary payload puts `0xa5a5a5a5` in every register it can and halts with exit code `0x5a`: `a0` comes back `0x5a` and the other thirteen caller-saved registers zero |
| `TEST fault_read` | a payload reads the monitor's code: FAULT, `mcause = 5` |
| `TEST fault_write` | a payload overwrites it: FAULT, `mcause = 7`, and the monitor's bytes unchanged |
| `TEST fault_badcall` | a payload makes `ecall` 7: FAULT, `mcause = 8`, `a0 = 1` |
| `STATUS` | `PASS` only if all of the above held; `FAIL first=N` names the first that did not |

`mtval` is printed but not required. Hazard3 hardwires it to 0 (`hdl/hazard3_csr.v`, `doc/sections/csr.adoc`), so
on the chip it reads 0 for every fault, and the emulator now says the same (fixture-emulator.txt).

`send()` drops a line whole unless a page holds the port open, so the report is **printed again and
again** (the LED between), and the page starts a new one at each `ENCLAVE` line. A page opened mid-way
shows nothing until the next report starts.

The LED: one flash, 3 s dark: all held. 2 s on, then N flashes: check N did not (1 a kernel op, 2 PMP
readback, 3 scrub, 4 read, 5 write, 6 bad call).

## The counts

exp229's Lean model counts 331, 238 and 1903 instructions for add, sub and mul; its RTL run reads
335/241/1907 with its own harness. Here the counters start at the `csrwi` before `mret`, so the figure
includes a few instructions of framing. The emulator says two (`csrwi` + `mret`; it also counts the
trapping `ecall`, and not the handler's first instruction) — 333, 240, 1905. The chip may differ, so
the shell accepts `minstret − model` in 0..8, requires it to repeat exactly, and the page does the same.
The silicon's own figure belongs here, pasted, when someone has run it; an earlier revision of this
file printed 331 as if measured.

## Run it

```sh
./check.sh      # everything that needs no board; ~1 minute
./run.sh        # the same, recorded to capture.txt
python3 emutest.py --lines   # the report the emulator gives, in the firmware's format
```

`fixture-emulator.txt` is that report. It is **the emulator's, not a board's**, and `cycles` in it are
the emulator's one-per-instruction. `check.sh` fails if it is not what `emutest.py` prints now, and if
a key in it is one `board_chip.c` does not print — the Python and the C format the same lines by hand.
Paste a real capture as `board/capture.txt` and `check.sh` runs the page's checks on it too.

## Expected output

Pasted from `capture.txt`, recorded by `./run.sh` from commit fd4dcb7. This is **the half that needs
no board**: the emulator, the page's checks and the build. There is no capture from a Pico 2 yet.

```text
=== exp237 — the enclave on the chip ===
recorded at 2026-10-16T06:16:02Z from commit fd4dcb7

>>> the shell, for the chip
Generated build/payload.h (monitor: 676 B, 162 words, kernel: 2080 B)
build/exp237.bin  16036 bytes, the build allows 16384
build/exp237.uf2  32256 bytes  sha256 c10a277e29d6f39f6b0d38233166d96f8484315c2099c5300367007462a8bd7a

>>> the checks
PASS  no lifeline, and it says why: a C shell, not crates/lifeline — BOOTSEL by hand is the way back
PASS  the monitor, run on the emulator, does everything enclave.c asks of the chip
PASS  probe_launch as built for the chip: the canary's registers come back zero, the callee-saved ones restored
PASS  probe_launch counts a callee-saved register the monitor did not restore
PASS  mutant refused: s0 not restored
PASS  mutant refused: gp not restored
PASS  mutant refused: a caller-saved register left
PASS  mutant refused: t1 left holding the context
PASS  mutant refused: mscratch left
PASS  mutant refused: counters left frozen
PASS  mutant refused: pmp wide open
PASS  mutant refused: pmp never set
PASS  mutant refused: every ecall is a halt
PASS  fixture-emulator.txt is what emutest.py prints now
PASS  every key of the fixture's lines is one board_chip.c prints
PASS  the page's script parses (node --check)
PASS  findCdc is tools/pages/log.html's, byte for byte
PASS  the PMP readback is 0x1f and 0x08015fff
PASS  three kernel operations reported
PASS  the canary left no register non-zero
PASS  all three attacks were refused
PASS  the firmware says PASS
PASS  the report is complete and every number holds
PASS  a report whose start was missed is not complete
PASS  mutant is a change: minstret under the model
PASS  refused: minstret under the model
PASS  mutant is a change: minstret far over the model
PASS  refused: minstret far over the model
PASS  mutant is a change: minstret not repeatable
PASS  refused: minstret not repeatable
PASS  mutant is a change: model is not exp229's
PASS  refused: model is not exp229's
PASS  mutant is a change: a0 not zero
PASS  refused: a0 not zero
PASS  mutant is a change: an operation failed
PASS  refused: an operation failed
PASS  mutant is a change: PMP readback is not the NAPOT entry
PASS  refused: PMP readback is not the NAPOT entry
PASS  mutant is a change: PMP flagged bad
PASS  refused: PMP flagged bad
PASS  mutant is a change: a caller-saved register left non-zero
PASS  refused: a caller-saved register left non-zero
PASS  mutant is a change: a callee-saved register not restored
PASS  refused: a callee-saved register not restored
PASS  mutant is a change: the canary exit code is not the payload's
PASS  refused: the canary exit code is not the payload's
PASS  mutant is a change: the read attack did not fault with a load access fault
PASS  refused: the read attack did not fault with a load access fault
PASS  mutant is a change: the write attack left the monitor changed
PASS  refused: the write attack left the monitor changed
PASS  mutant is a change: the bad call was taken for a halt
PASS  refused: the bad call was taken for a halt
PASS  mutant is a change: an attack is missing
PASS  refused: an attack is missing
PASS  mutant is a change: STATUS PASS over a failed test
PASS  refused: STATUS PASS over a failed test
PASS  mutant is a change: STATUS FAIL
PASS  refused: STATUS FAIL
SKIP  board/capture.txt: no capture from a board has been pasted
PASS  the shell builds for the chip into 16036 of the 16384 bytes it may use
PASS  all 63 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 16 KiB of flash, 0x10000000..0x10004000
PASS  together they are exactly the 16036-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20030000
PASS  the UF2 is byte for byte the committed one: c10a277e29d6f39f…
```
