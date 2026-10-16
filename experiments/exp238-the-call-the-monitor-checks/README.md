# exp238 — the call the monitor checks

<!-- SPDX-License-Identifier: Apache-2.0 -->

**A 200-instruction, 800-byte RISC-V M-mode monitor (`monitor.bin`) that answers two calls which do not
stop the payload — `HASHB` and `CHECKSIG` — and a Lean 4 proof of what its own words do when the
privileged model of exp235 runs them. It does not hash and does not verify: it owns the *pointers*. Before a
call is forwarded to the host's service port, every range it names is checked to lie wholly inside the
payload's 64 KiB box, by three comparisons that never add a pointer to a length, so a range whose end wraps
past 2^32 is refused like any other. A call that passes returns to the payload at the word after its
`ecall`, its registers as they were, and two counted instructions later; a call that does not is a fault —
the machine parks with `a0 = 1`, every other register zero, and the service port as it was. exp228's
881-instruction Tapscript kernel runs its 34 scripts, and 120 more, under it on an emulator, and every
verdict, every byte of the box and every request the host saw match the kernel run with no monitor at all.
Nothing here ran on silicon or on the Hazard3 RTL.**

Needs: **no board**. The third stone of the micro-monitor track: exp235 is the model, exp236 the monitor that
only halts, this one the monitor that answers. The design is in `docs/micro-monitor/`.

## What the monitor does

`monitor.S`, assembled at `0x80000000`. Words 0–72 — boot and the first four words of trap entry — are
exp236's, word for word; from word 73 on it is a new program, and none of exp236's theorems are about it.

```
0x80000040  _reset (boot, 53 steps)   as exp236: PMP 64 KiB NAPOT at 0x80010000, MPP <- U, every register
                                      zero but sp, counters on, mret
0x80000114  trap_handler              freeze counters, swap sp with mscratch, save t0..t3 at
                                      0x80008000..0x8000800c, read mcause
                                        mcause != 8                  -> handle_fault
0x80000174  handle_ecall              saved t0 == 1 -> handle_halt   (exp236's: report, scrub, park)
                                      saved t0 == 2 -> call_hashb    a0 = input, a1 = length, a2 = output
                                      saved t0 == 3 -> call_checksig a0 = key (32 B), a1 = signature (64 B)
                                      anything else -> handle_fault
0x80000194  call_hashb                [a0, a0 + a1) and [a2, a2 + 32) inside the box, else handle_fault;
                                      write a0, a1, a2, then the call number, to 0xc0000010..0xc000001c
0x800001e0  call_checksig             [a0, a0 + 32) and [a1, a1 + 64) inside the box, else handle_fault;
                                      write a0, a1, then the call number; a0 <- the word at 0xc000001c
0x8000022c  trap_return               mepc <- mepc + 4, t0..t3 back from the stack, sp swapped back,
                                      csrwi mcountinhibit, 0; mret
0x80000138  handle_fault              report FAULT, a0 <- 1, scrub_exit
0x8000027c  scrub_exit                zero the four saved words and mscratch, every register but a0
0x80000318  halt_loop                 wfi; j halt_loop
```

The bounds check on one range `[ptr, ptr + len)` is three comparisons, none of which adds:

```
ptr >= BOX_LO              bltu a0, lo           -> fault
ptr <= BOX_HI              bltu hi, a0           -> fault     (so hi - ptr cannot go below 0)
len <= BOX_HI - ptr        bltu (hi - ptr), len  -> fault
```

The service port, `0xc0000010..0xc000001c`, is the host's: the testbench here, a C caller on the chip. Three
argument words, then the call number — whose write is the request — and a read of the same word is the
answer. The host is trusted with nothing: it only ever sees ranges the monitor has already confined. The
monitor spends `t0..t3` and no other register, so the trap entry saves exactly those four. (The design note
asked for all of `x1..x31` saved; a monitor that touches four registers does not need to.)

**The counters.** The first instruction of the handler freezes them. The last two before `mret` release them.
So a call costs the payload's `minstret` exactly the `ecall`, the `csrwi` and the `mret` — three — whatever
the call, whatever its arguments, whatever the host did.

## What is proved (`proof/Calls.lean`)

All on Lean's own axioms. They are about `PrivMachine` fetching and executing `monitorCode` — the words of
`monitor.bin`, which `check.sh` holds against `monitor.S` assembled afresh.

| theorem | says |
| :--- | :--- |
| `bounds_ok_iff` | the three comparisons pass **exactly** when `0x80010000 ≤ ptr` and `ptr + len ≤ 0x80020000`, the sum taken in the naturals: a range that wraps past 2^32 does not pass |
| `monitor_boot` | exp236's, for these words: 53 steps from reset give `UBoxed 0x80010000 0x80020000` at `0x80010000`, every register zero but `sp` |
| `monitor_hashb_ok` | at the trap vector, `mcause = 8`, saved `t0 = 2`, both ranges in the box: 43 steps, back in U-mode at `mepc + 4`, **every** register as it was, `minstret + 2`, the service port holding `a0`, `a1`, `a2` and `2`, memory outside the monitor's stack words, the report words and the port untouched — the payload's box included |
| `monitor_checksig_ok` | the same for `t0 = 3`: 45 steps, every register but `a0` as it was, the port holding the key, the signature and `3`; `a0` is the word the monitor read back from the port |
| `monitor_hashb_oob_fault`, `monitor_checksig_oob_fault` | **a call that is not wholly in the box is refused**: whichever range is out — below the box, past it, straddling an end, or one whose end wraps — the machine parks with `a0 = 1`, every other register zero, and the service port as it was: the host is never asked. Twelve theorems, one per check, behind each |
| `monitor_halt`, `monitor_fault_cause`, `monitor_fault_syscall` | as exp236's, for these words: 61, 63, 71 steps |
| `monitor_cycle` | a running payload runs `n` steps or traps; the trap ends in the park loop (`a0 = 1`, or a HALT's own exit code) or in the payload running again, `Served`: the word after its `ecall`, its registers, two instructions on the counter |
| `safe_for`, `monitor_end_to_end` | however many calls the payload makes, and whatever their arguments: from reset, boot, then every trap parks the machine or hands the payload back, running and boxed, with the monitor's words in place |

Each short run is one theorem — a chunk, a few instructions ending at its first store — and every chunk has
the same statement and the same proof, so `proof/gen.py` writes them from a table, joins them (the phases,
the calls, the faults) and writes `Calls.lean`; `proof/tail.lean` is the hand-written rest. `check.sh` fails
if `Calls.lean` is not what the generator writes. Boot is exp236's six chunks, copied from its proof and
checked again here on these words.

## What is not proved, and what it rests on

- **The model is not the chip.** As exp236: `Priv.lean` is a reading of the Hazard3 documentation; nothing
  here ran on the RTL or on an RP2350.
- **The service port is memory.** The proof treats `0xc0000010..0xc000001c` as memory, as exp236 treats its
  report words. So it proves *what the monitor writes there and what it reads back*, not what a host does. In
  particular nothing is proved about `a0` after `CHECKSIG` except that it is the word read from the port: the
  model reads back the request it just wrote.
- **The monitor does not hash and does not verify.** That `HASHB` writes the SHA-256 of the input and that
  `CHECKSIG` answers 1 for a good BIP340 signature is the host's job (here `suite/host.py`, with hashlib and
  exp228's verifier), proved nowhere in this experiment.
- **The box is not read-protected from the host.** The host runs with M-mode's authority; what the monitor
  guarantees is that every range it is *asked* about is inside the box. What the host then does with a good
  range is the host's.
- **`mepc + 4` at the top of the box.** An `ecall` in the last word of the box returns to `0x80020000`, which
  is outside the box: the next fetch faults and the monitor parks, which the theorems cover as a trap.
- **Payload memory is not scrubbed**, as exp236.
- **The counters** are shown for the model. exp228's round-4 capture on a Pico 2 counted the model's
  instructions + 4 for its harness + 4 per call; this experiment's emulator run alone matches that, so the
  *emulator* agrees with the board about the payload without the monitor. How many counted instructions a call
  costs the payload with *this monitor* on the chip is not measured.
- **Chip port.** exp237's `monitor_chip.S` is derived from exp236's, unproved, and has none of this. A chip
  port of *this* monitor is a later experiment with a declared, mechanically-checked difference from
  `monitor.S`.

## The checks

1. `monitor.py --check`: `monitor.S` assembles to `monitor.bin` byte for byte, the SHA-256 matches,
   200 ≤ 200 words, and `monitorCode` in the proof is the binary's words in order.
2. `Calls.lean` checks, with no errors and no warnings, on Lean's own axioms.
3. **Eight mutants** (`proof/mutants.txt`), each refused by Lean in the chunk or phase it breaks: an input
   floor dropped, a length tested by adding, 16 bytes of output room, 32 bytes of signature room, a return
   that does not step past the `ecall`, counters never released, an unoffered call that returns, a saved word
   left on the stack.
4. `proof/Calls.lean` is what `proof/gen.py` writes.
5. **exp228's kernel under the monitor** (`suite/kernel_cases.py`): each of its 34 scripts, and 120 drawn by
   exp228's fuzzer, runs three ways — alone with no monitor, under the monitor, and in the specification
   (`script.py`, with BIP340). The exit code, the whole 64 KiB box, the host's requests and `minstret` must
   agree: `minstret` under the monitor is the run alone + 2 + 2 per call.
6. **Payloads that lean on the calls** (`suite/attack_cases.py`): 43 refused with the host never asked
   (below the box, past it, straddling either end, a length of 2^32 − 1, wrapping lengths, wrapping pointers,
   the monitor's own words and stack, unoffered call numbers), 8 served to the last byte, the registers a call
   must leave alone, a hundred calls in a row at an exact `minstret`, and 10 that fault with the hardware's cause.
7. **Twenty-five broken monitors** (`suite/broken_monitors.py`): `monitor.S` with one change — a check
   dropped, a length checked by adding, a register the return forgets, a counter released too late or too
   soon, a saved word left behind — each must fail the attack or the kernel suite.

The test host is deliberately credulous: it does what the arguments say, with M-mode's authority, at any
address. A monitor that fails to check is caught by what the host was made to do.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
@@CAPTURE@@
```
