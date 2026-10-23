# exp238 — the call the monitor checks

<!-- SPDX-License-Identifier: Apache-2.0 -->

**A 200-word, 800-byte RISC-V M-mode monitor (`monitor.bin`) that answers two calls which do not
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
| `monitor_cycle` | a running payload runs `n` steps or traps, and the trap has an `Outcome`: parked after a fault (`a0 = 1`, the service port as it was), parked after a HALT (`a0` the payload's own exit code), or `Served` — the call's ranges were in the box, the host was asked exactly the payload's arguments and call number, and the payload is running again at the word after its `ecall` with its registers and two instructions on the counter |
| `ends_refuses` | **a call with a range out of the box can only end the first way**: `OutOfBox` (an `ecall` for `HASHB` or `CHECKSIG` whose ranges are not wholly in the box) gives the park loop with `a0 = 1` and the service port as it was. `Outcome` carries this as a conjunct, so every trap the end-to-end theorem reaches states it |
| `safe_for`, `monitor_end_to_end` | however many calls the payload makes, and whatever their arguments: from reset, boot, then every trap has an `Outcome` — the machine parks, or a call whose ranges were in the box is served and the payload is running again, boxed, with the monitor's words in place — and **a call with a range out of the box parks the machine with `a0 = 1` and the host never asked** |

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
- **The reports are not proved.** The print and exit ports are memory in the model, so of the words a report
  stores at `0xc0000004` only the last is left, and the frame leaves both ports out: no theorem says what was
  reported, or what the exit port holds, only that `a0` holds the exit code. The report's words, the exit port and
  `minstret` as reported are checked on the emulator alone ([the audit](../../docs/2026-10-23-1116-emulator-verdicts-vs-theorems-audit-zh-tw.md), G1 and G2).
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
=== exp238 — the call the monitor checks ===
recorded at 2026-10-17T03:57:08Z from commit 5d17005

>>> the micro-monitor binary and size budget
PASS  monitor.bin (800 bytes, 200 words) is monitor.S assembled, matches monitor.sha256, is within 200 words, and is proof/Calls.lean's monitorCode

>>> the formal theorems, and what they rest on
'Exp238.monitorCode_length' does not depend on any axioms
'Exp238.monitor_boot' depends on axioms: [propext, Quot.sound]
'Exp238.bounds_ok_iff' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp238.monitor_halt' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp238.monitor_fault_cause' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp238.monitor_fault_syscall' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp238.monitor_hashb_ok' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp238.monitor_hashb_oob_fault' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp238.monitor_checksig_ok' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp238.monitor_checksig_oob_fault' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp238.ends_refuses' depends on axioms: [propext, Quot.sound]
'Exp238.monitor_cycle' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp238.monitor_end_to_end' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong monitors: each must be refused
hashb_input_floor_dropped  HASHB lets an input start below the box                                  refused in hashb_b1
hashb_length_by_addition   HASHB tests ptr + len, which wraps, instead of what is left of the box   refused in hashb_s3
hashb_output_room_16       HASHB checks room for 16 bytes of output, not 32                         refused in hashb_s6
checksig_signature_32      CHECKSIG checks room for 32 bytes of signature, not 64                   refused in checksig_s6
return_repeats_the_ecall   the return does not step past the ecall                                  refused in return_1
counters_not_released      the return never releases the counters                                   refused in return_3
unknown_call_succeeds      a call the monitor does not offer returns to the payload                 refused in call_unknown
scrub_keeps_saved_t2       the scrub leaves the saved t2 on the M-mode stack                        refused in scrub_1c

>>> exp228's kernel and its scripts, under the monitor
PASS  34 scripts run by exp228's kernel under the monitor: verdict, box and request log as run alone, minstret = alone + 2 + 2*calls, 7 calls served, each wholly inside the box
PASS  the run alone counted what the Pico 2 counted (34 cases, + 4 + 4*calls)
PASS  120 fuzzed scripts, the same: 10 calls served
      case                          minstret  calls
      one                                109      0
      2+3=5                              416      0
      7-9=-2                             425      0
      1add of 0x7fffffff                 408      0
      1sub of -0x7fffffff                407      0
      dup drop nip over swap             695      0
      sha256 of a witness                457      1
      sha256 of nothing                  489      1
      pay to key hash                    544      2
      pay to key                         325      1
      empty signature pushes false       472      0
      negative zero is false              81      0
      nop                                125      0
      1negate                            339      0
      bad opcode                          65      0
      pushdata1                           29      0
      push past the end                   31      0
      underflow                           70      0
      overflow                          1182      0
      overflow by dup                     90      0
      5-byte operand                     103      0
      non-minimal operand                100      0
      non-minimal zero                    91      0
      verify false                        67      0
      key the wrong size                 228      0
      signature the wrong size           238      0
      signature invalid                  246      1
      a second signature                 609      1
      two left                            97      0
      none left                           25      0
      false left                          59      0
      equalverify unequal                195      0
      the whole stack, all 32            476      0
      2+2=5, as in 1984                  367      0

>>> payloads that lean on the calls
PASS  64 payloads that lean on the calls: 43 refused with the host never asked, 8 served to the last byte as the run with no monitor serves them,
      the registers a call must leave alone (both calls), 100 calls in a row at an exact minstret, 10 that fault with the hardware's cause:
      refused  hashb: input in the monitor's code
      refused  hashb: input is the M-mode stack
      refused  hashb: input one byte below the box
      refused  hashb: input in system SRAM
      refused  hashb: input in the MMIO words
      refused  hashb: input starts at the end of the box
      refused  hashb: input one byte past the end
      refused  hashb: input is the box and a byte more
      refused  hashb: input of 2^32-1 bytes
      refused  hashb: input of 2^31 bytes
      refused  hashb: input wraps past 2^32 to a low address
      refused  hashb: input wraps to the middle of the box
      refused  hashb: input in the box, length wraps back into it
      refused  hashb: input in the box, length wraps to the pointer minus one
      refused  hashb: output over the monitor's code
      refused  hashb: output over the M-mode stack
      refused  hashb: output over the trap vector
      refused  hashb: output one byte below the box
      refused  hashb: output 31 bytes from the end
      refused  hashb: output at the end of the box
      refused  hashb: output wraps past 2^32
      refused  hashb: output is the top word
      refused  hashb: output zero
      refused  checksig: key in the monitor's code
      refused  checksig: key is the M-mode stack
      refused  checksig: key one byte below the box
      refused  checksig: key 31 bytes from the end
      refused  checksig: key at the end of the box
      refused  checksig: key wraps past 2^32
      refused  checksig: key zero
      refused  checksig: signature in the monitor's code
      refused  checksig: signature is the M-mode stack
      refused  checksig: signature one byte below the box
      refused  checksig: signature 63 bytes from the end
      refused  checksig: signature at the end of the box
      refused  checksig: signature wraps past 2^32
      refused  checksig: signature is the top word
      refused  call 0 (HASH of exp228's model) is not offered
      refused  call 4
      refused  call 0xffffffff
      refused  call 0x102: only the low bits are 2
      refused  call 0x80000002
      refused  call 0x1000000001: HALT's number plus 2^32
      served   hashb: the last 32 bytes of the box, into the same 32
      served   hashb: nothing, at the end of the box
      served   hashb: nothing, anywhere in the box
      served   hashb: the whole box, the payload's own code included
      served   hashb: one odd byte
      served   checksig: key and signature at the very end
      served   checksig: key and signature at the very start
      served   checksig: signature at the very end

>>> monitors with one thing wrong: each must be caught
PASS  25 broken monitors, each caught by the attack and kernel suites:
      hashb_input_floor_dropped          HASHB lets an input start below the box
      hashb_input_ceiling_dropped        HASHB lets an input start past the box
      hashb_length_dropped               HASHB never checks the length against what is left of the box
      hashb_length_by_addition           HASHB checks ptr + len <= BOX_HI, and the sum wraps
      hashb_output_floor_dropped         HASHB lets the output start below the box
      hashb_output_ceiling_dropped       HASHB lets the output start past the box
      hashb_output_room_dropped          HASHB lets the 32-byte output run off the end of the box
      hashb_output_16_bytes              HASHB checks room for 16 bytes of output, not 32
      checksig_key_floor_dropped         CHECKSIG lets the key start below the box
      checksig_key_room_dropped          CHECKSIG lets the 32-byte key run off the end of the box
      checksig_signature_floor_dropped   CHECKSIG lets the signature start below the box
      checksig_signature_32_bytes        CHECKSIG checks room for 32 bytes of signature, not 64
      checksig_is_hashb                  call 3 is taken for call 2
      unknown_call_succeeds              a call the monitor does not offer returns to the payload
      return_repeats_the_ecall           the return does not step past the ecall
      return_skips_two_words             the return steps over the word after the ecall too
      return_leaves_t1                   the return does not put the payload's t1 back
      return_leaves_t3                   the return does not put the payload's t3 back
      return_keeps_monitor_sp            the return leaves the monitor's sp in the payload
      counters_not_released              the return never releases the counters
      counters_released_early            the return releases the counters two instructions sooner
      extra_instruction_counted          the return spends one more counted instruction
      scrub_keeps_saved_t2               the scrub leaves the saved t2 on the M-mode stack
      scrub_keeps_saved_t3               the scrub leaves the saved t3 on the M-mode stack
      fault_does_not_scrub               a fault parks without scrubbing

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  monitor.bin (800 bytes, 200 words) is monitor.S assembled, matches monitor.sha256, is within 200 words, and is proof/Calls.lean's monitorCode
PASS  Calls.lean checks, with no errors and no warnings
PASS  all 13 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  hashb_input_floor_dropped: the proof refuses a version where HASHB lets an input start below the box
PASS  hashb_length_by_addition: the proof refuses a version where HASHB tests ptr + len, which wraps, instead of what is left of the box
PASS  hashb_output_room_16: the proof refuses a version where HASHB checks room for 16 bytes of output, not 32
PASS  checksig_signature_32: the proof refuses a version where CHECKSIG checks room for 32 bytes of signature, not 64
PASS  return_repeats_the_ecall: the proof refuses a version where the return does not step past the ecall
PASS  counters_not_released: the proof refuses a version where the return never releases the counters
PASS  unknown_call_succeeds: the proof refuses a version where a call the monitor does not offer returns to the payload
PASS  scrub_keeps_saved_t2: the proof refuses a version where the scrub leaves the saved t2 on the M-mode stack
PASS  proof/Calls.lean is what proof/gen.py writes
PASS  34 scripts run by exp228's kernel under the monitor: verdict, box and request log as run alone, minstret = alone + 2 + 2*calls, 7 calls served, each wholly inside the box
PASS  the run alone counted what the Pico 2 counted (34 cases, + 4 + 4*calls)
PASS  120 fuzzed scripts, the same: 10 calls served
      case                          minstret  calls
      one                                109      0
      2+3=5                              416      0
      7-9=-2                             425      0
      1add of 0x7fffffff                 408      0
      1sub of -0x7fffffff                407      0
      dup drop nip over swap             695      0
      sha256 of a witness                457      1
      sha256 of nothing                  489      1
      pay to key hash                    544      2
      pay to key                         325      1
      empty signature pushes false       472      0
      negative zero is false              81      0
      nop                                125      0
      1negate                            339      0
      bad opcode                          65      0
      pushdata1                           29      0
      push past the end                   31      0
      underflow                           70      0
      overflow                          1182      0
      overflow by dup                     90      0
      5-byte operand                     103      0
      non-minimal operand                100      0
      non-minimal zero                    91      0
      verify false                        67      0
      key the wrong size                 228      0
      signature the wrong size           238      0
      signature invalid                  246      1
      a second signature                 609      1
      two left                            97      0
      none left                           25      0
      false left                          59      0
      equalverify unequal                195      0
      the whole stack, all 32            476      0
      2+2=5, as in 1984                  367      0
PASS  64 payloads that lean on the calls: 43 refused with the host never asked, 8 served to the last byte as the run with no monitor serves them,
      the registers a call must leave alone (both calls), 100 calls in a row at an exact minstret, 10 that fault with the hardware's cause:
      refused  hashb: input in the monitor's code
      refused  hashb: input is the M-mode stack
      refused  hashb: input one byte below the box
      refused  hashb: input in system SRAM
      refused  hashb: input in the MMIO words
      refused  hashb: input starts at the end of the box
      refused  hashb: input one byte past the end
      refused  hashb: input is the box and a byte more
      refused  hashb: input of 2^32-1 bytes
      refused  hashb: input of 2^31 bytes
      refused  hashb: input wraps past 2^32 to a low address
      refused  hashb: input wraps to the middle of the box
      refused  hashb: input in the box, length wraps back into it
      refused  hashb: input in the box, length wraps to the pointer minus one
      refused  hashb: output over the monitor's code
      refused  hashb: output over the M-mode stack
      refused  hashb: output over the trap vector
      refused  hashb: output one byte below the box
      refused  hashb: output 31 bytes from the end
      refused  hashb: output at the end of the box
      refused  hashb: output wraps past 2^32
      refused  hashb: output is the top word
      refused  hashb: output zero
      refused  checksig: key in the monitor's code
      refused  checksig: key is the M-mode stack
      refused  checksig: key one byte below the box
      refused  checksig: key 31 bytes from the end
      refused  checksig: key at the end of the box
      refused  checksig: key wraps past 2^32
      refused  checksig: key zero
      refused  checksig: signature in the monitor's code
      refused  checksig: signature is the M-mode stack
      refused  checksig: signature one byte below the box
      refused  checksig: signature 63 bytes from the end
      refused  checksig: signature at the end of the box
      refused  checksig: signature wraps past 2^32
      refused  checksig: signature is the top word
      refused  call 0 (HASH of exp228's model) is not offered
      refused  call 4
      refused  call 0xffffffff
      refused  call 0x102: only the low bits are 2
      refused  call 0x80000002
      refused  call 0x1000000001: HALT's number plus 2^32
      served   hashb: the last 32 bytes of the box, into the same 32
      served   hashb: nothing, at the end of the box
      served   hashb: nothing, anywhere in the box
      served   hashb: the whole box, the payload's own code included
      served   hashb: one odd byte
      served   checksig: key and signature at the very end
      served   checksig: key and signature at the very start
      served   checksig: signature at the very end
PASS  25 broken monitors, each caught by the attack and kernel suites:
      hashb_input_floor_dropped          HASHB lets an input start below the box
      hashb_input_ceiling_dropped        HASHB lets an input start past the box
      hashb_length_dropped               HASHB never checks the length against what is left of the box
      hashb_length_by_addition           HASHB checks ptr + len <= BOX_HI, and the sum wraps
      hashb_output_floor_dropped         HASHB lets the output start below the box
      hashb_output_ceiling_dropped       HASHB lets the output start past the box
      hashb_output_room_dropped          HASHB lets the 32-byte output run off the end of the box
      hashb_output_16_bytes              HASHB checks room for 16 bytes of output, not 32
      checksig_key_floor_dropped         CHECKSIG lets the key start below the box
      checksig_key_room_dropped          CHECKSIG lets the 32-byte key run off the end of the box
      checksig_signature_floor_dropped   CHECKSIG lets the signature start below the box
      checksig_signature_32_bytes        CHECKSIG checks room for 32 bytes of signature, not 64
      checksig_is_hashb                  call 3 is taken for call 2
      unknown_call_succeeds              a call the monitor does not offer returns to the payload
      return_repeats_the_ecall           the return does not step past the ecall
      return_skips_two_words             the return steps over the word after the ecall too
      return_leaves_t1                   the return does not put the payload's t1 back
      return_leaves_t3                   the return does not put the payload's t3 back
      return_keeps_monitor_sp            the return leaves the monitor's sp in the payload
      counters_not_released              the return never releases the counters
      counters_released_early            the return releases the counters two instructions sooner
      extra_instruction_counted          the return spends one more counted instruction
      scrub_keeps_saved_t2               the scrub leaves the saved t2 on the M-mode stack
      scrub_keeps_saved_t3               the scrub leaves the saved t3 on the M-mode stack
      fault_does_not_scrub               a fault parks without scrubbing
```
