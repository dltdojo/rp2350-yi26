# exp159-a-key-that-was-never-in-flash — ECDSA behind the wall

The third experiment on the [signing road](../README.md#the-signing-road), and
the **first one designed as a matrix from the start** — so it is also the worked
example of [`docs/the-board-is-the-loop.md`](../../docs/the-board-is-the-loop.md).
Four measurements, one per boot, one flash, about fifty seconds, nobody in the
room.

## The claim

> **A P-256 private key exists on this board in a place Non-secure code cannot
> read, it never existed in flash, and it produced a signature over a challenge
> nobody could have known at build time — checked by something that is not this
> firmware.**

Every clause is there because leaving it out is how the prior work this road was
filed against went wrong.

---

## How this was designed, in the order it happened

This section is the point of the experiment as much as the result is. The method
is in [the-board-is-the-loop](../../docs/the-board-is-the-loop.md) and
[debugging-without-a-board](../../docs/debugging-without-a-board.md); this is
what it looks like applied.

### 1. Establish the facts before offering any option

The repository's rule is *never offer an option built on an assumption*. Six
facts were measured or read before a line was designed, and **four of them
changed the design**:

| fact | how | what it changed |
| --- | --- | --- |
| RP2350 has no ECC hardware (it has `sha256` and `trng`) | read `rp-pac` | P-256 has to be software |
| `p256` builds for `thumbv8m.main-none-eabihf`, RFC6979 deterministic — no RNG needed to sign | compiled it | it is viable at all |
| P-256 signing costs **20,248 bytes of `.text`** | built it against an empty baseline | a number the ML-DSA experiment will be compared against |
| `ACCESSCTRL` gates **each of ten SRAM banks separately** | read `rp-pac` | ← **this is what makes hiding a key possible** |
| `SRAM`, `XIP_MAIN` and `ROM` default to *fully open*; `TRNG`, `SHA256` and `WATCHDOG` default to *Secure-privileged only* | read the PAC's own doc strings | ← decided where the key goes, where the mailbox goes, and why core 1 cannot reboot itself |
| `embassy-rp`'s `multicore` keeps using the SIO FIFO after launch | read its source | ← the gateway cannot be the FIFO |

### 2. Name the contradictions, not the request

Three, and each one forced part of the design.

#### C1 · exp156's wall is around a peripheral. A key is bytes.

[exp156](../exp156-a-wall-you-can-measure/) measured `ACCESSCTRL` denying
**I2C1** to Non-secure code — and explicitly rejected doing the same to SRAM:
*"denying Non-secure access to SRAM or to XIP would take core 1's own stack and
code away before it reached the thing being tested."*

That objection is correct, and it is fatal to the obvious design. The resolution
came from a fact, not from cleverness: the RP2350's 520 KB is **8 × 64 KB plus
two 4 KB banks of their own**, and `ACCESSCTRL` has a separate register for each.
So the key lives in **bank 8** at `0x2008_0000`, and core 1's stack stays in the
main region. Nothing core 1 needs is ever denied to it.

It also disposes of a question nobody here has answered — whether banks 0–7 are
striped across the main address range. **It stops mattering**, because those
banks are never touched.

> **They are striped, measured 2026-08-21 by
> [exp162](../exp162-how-wide-can-a-wall-be/).** Banks 0–3 go round the lower
> 256 KB four bytes at a time and banks 4–7 round the upper 256 KB, so one
> register denies four consecutive bytes and no more. Setting the question aside
> was the right call and the reasoning above understates what it bought: bank 8
> is not a convenient choice among nine, it is one of the only two banks on this
> part that gate a contiguous region at all.

#### C2 · A key compiled into the firmware makes the whole thing hollow

This is the one worth stopping on.

If the private key were a constant in the source, it would live in flash. And
`XIP_MAIN` **defaults to fully open access** — that is *how core 1 executes at
all*. So Non-secure code would read the key straight out of flash, and the wall
around bank 8 would be guarding a copy while the original sat in the open.

> **That is the defect this whole road was filed against, arriving from a
> direction nobody was watching.** The prior work claimed a key was protected by
> pointing at a function it had never gated. A compiled-in key would claim a key
> was protected by pointing at a bank the key was not only in.

So the key is generated **on the board, from the hardware TRNG, into bank 8, and
written nowhere else**. The firmware prints only the *public* key. What is in
flash is code.

`check.sh` greps for a key literal and fails the experiment if one appears,
because this is not something to leave to good intentions.

You can see it working in the captures: flash the same `.uf2` twice and the
public key is different both times.

#### C3 · The road said "hand-write an SG veneer and program the SAU"

It does not need one, and saying so retires a planned piece of work.

exp156 put the boundary **between the two cores** with
`ACCESSCTRL.FORCE_CORE_NS`. A boundary between cores has no veneer — there is no
call across a security state to gate, because the two states are two processors.
The gateway is a **mailbox**. No `global_asm!`, no SAU, no nightly.

The mailbox is **shared memory rather than the SIO FIFO**, and that is measured
rather than preferred: `embassy-rp`'s `multicore` keeps using the FIFO after
launch for its pause/resume tokens, so a second user would collide with it.

Shared memory works because `SRAM` defaults to fully open: Non-secure asks by
setting a flag, Secure answers by filling a buffer. **The secret is in a
different bank, and only one side can reach it.**

### 3. Let a register default decide, rather than choosing

`WATCHDOG` defaults to *Secure, Privileged only*. So a Non-secure core cannot
reach it, and [`breadcrumb::reboot`](../../crates/breadcrumb/) called from core
1's fault handler would fault **inside the fault handler**.

Core 1 therefore sets a flag in shared memory and parks; core 0 — still Secure,
still holding USB — notices and reports. That is exp156's shape, and here it was
*forced by a default* rather than argued for. Underneath it all the breadcrumb
harness is still the net for the case nothing else covers: a death that takes
**core 0**.

### 4. Write it as a matrix, so one flash answers everything

```text
  1  Secure core 0 reads the key out of bank 8     must work        (control)
  2  Non-secure core 1 reads bank 8, ALLOWED       must work        (control)
  3  Non-secure core 1 reads bank 8, DENIED        must be refused
  4  Non-secure asks for a signature, bank 8
     still shut                                    64 bytes back
```

One candidate per boot. If an early one fails the later ones report *not
reached* rather than the trip being wasted — which is what
[exp158](../exp158-four-keys-and-one-flash/) was built to make possible.

**Candidates 1 and 2 are not decoration.** A refusal on its own is one failed
access; the same core reading the same address a moment earlier is what makes
the refusal mean something. That is the shape exp156 needed eight rounds to
arrive at, and it was designed in here from the first draft.

Candidate 3 also **checks the experiment's own assumption**: `KEYSTORE_BANK = 8`
is a guess about which `ACCESSCTRL.SRAM[n]` register gates `0x2008_0000`. If it
were the wrong register, candidate 3 would not be refused and the run would say
so.

---

## The result

All four candidates behaved as expected, and the signature verifies off the
board. Two things fell out for free:

- **One P-256 signature takes 61 ms** on this part — a number the ML-DSA
  experiment will be measured against.
- **SRAM bank 8 survives a watchdog reset.** The key generated on boot 1 was
  still there on boots 2, 3 and 4 — the public key is identical across them.

## How to see it

```sh
./check.sh                       # exit 0; it asserts the matrix and verifies the signature
yi26 log --json --seconds 25     # the settled report, repeating every ten seconds
python3 ./verify.py < a-log.txt  # verify a pasted log by hand, no board needed
```

The run takes about **fifty seconds** and the port disappears three times, so
`yi26 log` returns fragments until it settles. `check.sh` polls for the settled
state.

LED: **slow** while the matrix is being walked, **fast** once it is done.

## Expected output

Pasted from a real run on a Pico 2, Ubuntu, 2026-08-20, flashed with
`yi26 pflash` and read across the board's own reboots. Trimmed to one line in
three for length; nothing is edited.

```console
[    3037 ms] exp159 up, boot #1. The matrix so far:
[    3037 ms]   1 Secure reads the key - not reached
[    3037 ms]   2 Non-secure reads it, allowed - not reached
[    3037 ms]   3 Non-secure reads it, DENIED - not reached
[    3037 ms]   4 Non-secure asks for a signature - not reached
[    3125 ms] new P-256 key from the TRNG, written to bank 8 and nowhere else.
[    3170 ms] PUBX 1cdee59e243f364b44362a5f44f8d4d720fcdeb816591529037a80d09172cf0d
[    3170 ms] PUBY 2fd9692598ae6c1343c9928602d38b63fe365942917b7503ac6e5fa3606a7ae2
[    8170 ms] candidate 1 Secure reads the key
[    8170 ms]   Secure read: magic 0x4b455931, first key word 0x2ce370f6
[    8170 ms] candidate 1 -> as expected

[    3074 ms] bank 8 still holds this run's key: it survived the reboot.
[    8120 ms] candidate 2 Non-secure reads it, allowed
[    8120 ms]   bank 8 to Non-secure: OPEN
[    9130 ms]   core 1: done=true faulted=false read=0x4b455931
[    9130 ms] candidate 2 -> as expected

[    8120 ms] candidate 3 Non-secure reads it, DENIED
[    8120 ms]   bank 8 to Non-secure: SHUT
[    9130 ms]   core 1: done=false faulted=true read=0x00000000
[    9130 ms] candidate 3 -> as expected

[    8120 ms] candidate 4 Non-secure asks for a signature
[    8120 ms]   bank 8 SHUT, and it stays shut while the key is used.
[    8156 ms] MSG  5ab2aad2311c8f5566935499d9aad296295492312b8dcfcc33bb4d99b1a6962d
[    8176 ms]   Non-secure asked for a signature: true
[    8237 ms]   Secure signed it in 61 ms.
[    8737 ms]   Non-secure read it back: 0x046c19d6 (want 0x046c19d6)
[    8737 ms] candidate 4 -> as expected

[    8707 ms] exp159 done after 4 boots. Nothing armed; still reflashable.
[    8707 ms]   1 Secure reads the key - as expected
[    8707 ms]   2 Non-secure reads it, allowed - as expected
[    8707 ms]   3 Non-secure reads it, DENIED - as expected
[    8707 ms]   4 Non-secure asks for a signature - as expected
[    8707 ms] PUBX 1cdee59e243f364b44362a5f44f8d4d720fcdeb816591529037a80d09172cf0d
[    8707 ms] PUBY 2fd9692598ae6c1343c9928602d38b63fe365942917b7503ac6e5fa3606a7ae2
[    8707 ms] MSG  5ab2aad2311c8f5566935499d9aad296295492312b8dcfcc33bb4d99b1a6962d
[    8707 ms] SIGR 046c19d6948f3542b081d26632a9ea87a8a22a88de752dead8fefa3f5cc2a70f
[    8707 ms] SIGS 1f66c98bd1b02cab01eae065f61c471cdffd3422b5deb4717ec5d16cd188f1fd
```

`./check.sh` on the same board:

```console
PASS  toolchain present (cargo, elf2flash)
PASS  firmware compiles (157136 byte ELF)
PASS  converts to UF2 (93184 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  no private key is compiled into the firmware
PASS  the key comes from the hardware TRNG at runtime
PASS  the firmware never writes ACCESSCTRL.LOCK
PASS  the product string is bounded at build time
PASS  the LED heartbeat starts before the USB stack
PASS  the run has a hard stop that disarms
PASS  board enumerated as 1209:0001
PASS  every candidate was attempted
PASS  every candidate behaved as expected
PASS  control: Secure read the key out of bank 8
PASS  control: Non-secure read it while the bank was OPEN
PASS  the wall: Non-secure was refused once the bank was SHUT
PASS  Non-secure got 64 bytes back with the bank still SHUT
PASS  the signature verifies off the board, and the check can fail
```

## Why the verification is off the board, and why it flips a bit

The road said *"let something else check them"*, and that phrasing is load-bearing.

A signature checked by its own signer proves the two **agree**. It does not prove
either is right: a shared bug in encoding, endianness or hashing cancels out
perfectly. So [`verify.py`](./verify.py) uses `cryptography` — a different
implementation, on a different machine, in a different language.

And it then flips one bit of the challenge and **requires the verification to
fail**. Without that, a verifier that returned "valid" unconditionally would pass
every run forever. [exp140](../exp140-a-checksum-that-passes/) is what this
repository calls a check that cannot fail.

`verify.py` is a separate file rather than buried in `check.sh` on purpose: it
takes a pasted log on stdin, so somebody who read the board on a phone can check
the result without a toolchain.

## What is not verified here

- **This is not secure boot, and it is not a secure element.** The key is in
  volatile SRAM: it dies at power-off, and it is regenerated on the next flash.
  Nothing here provisions, attests, or persists an identity.
- **Only reads were tested against the wall.** Nothing tries a Non-secure
  *write* to bank 8, a DMA transfer, or the debugger. `ACCESSCTRL` has bits for
  DMA and DBG and none of them were exercised.
- **`ACCESSCTRL.LOCK` is deliberately never written**, so every configuration
  here is one power cycle from ordinary — which also means **none of it survives
  a reset on its own**. A real device would have to face that register, and it
  cannot be undone by software.
- **The mailbox is not hardened.** Non-secure can ask for a signature over
  anything, as often as it likes. Rate limiting, request validation and what a
  Secure side should *refuse* to sign are all real questions and none is asked
  here.
- **Timing and power side channels are entirely unexamined.** `p256`'s
  arithmetic aims to be constant-time; nothing here measured whether it is on
  this part.
- **61 ms is one measurement of one signature** at the default clock, not a
  characterisation.

## The ideas to take away

1. **A boundary is only as good as the worst place the secret lives.** The wall
   around bank 8 is real and measured — and it would have been worthless with a
   key literal in the source, because flash is readable by the code the wall
   exists to stop. *Ask where else the thing you are protecting exists.*

2. **Let the register defaults design the system.** Three decisions here — where
   the key goes, where the mailbox goes, and why core 1 cannot reboot itself —
   came from reading six power-on defaults out of the PAC. That reading took
   minutes and removed a hand-written assembly veneer from the plan.

3. **Point the new instrument at a question with a known answer first.** exp158
   re-derived a key exp156 had already measured, precisely so the harness could
   be caught being wrong. Only after that was it aimed at something new — which
   is this.

## Next

**Done: [exp160](../exp160-a-secret-too-big-to-hide/).** The same wall, ML-DSA-65
behind it — and the answer went the other way from the one this section
expected. The post-quantum signing code is *smaller* (16,380 bytes of `.text`
against P-256's 20,356 on the same baseline), so code size was never the
question.

**The wall does not survive the swap.** It still refuses every Non-secure read of
bank 8, and Non-secure code reads the key anyway: one ML-DSA-65 signature spreads
369,456 bytes of working state across ordinary open SRAM and leaves two intact
copies of the seed in it. exp160's candidate 4 is this experiment's headline,
ported unchanged, and it **passes** — which is exactly why it is not the last
candidate.

The idea to take away above says *a boundary is only as good as the worst place
the secret lives*, and it was written about flash. exp160 is the same sentence
about the stack, with the copy put there by a dependency rather than by an
author.
