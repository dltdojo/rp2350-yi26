# exp163 — how long is a secret in the open

A Non-secure core reads the whole 512 KB over and over while a Secure core
signs. It sees the ML-DSA seed **32 times inside one 147 ms signature**,
**nothing at all** after a 3.4 ms wipe, and costs the signature it is watching
**8.2%**.

> **A correction, from [exp164](../exp164-the-wall-nobody-read/).** Where this
> experiment says "Non-secure core", it means Non-secure **to ACCESSCTRL**.
> exp164 read the SAU and found that a core demoted with
> `ACCESSCTRL.FORCE_CORE_NS` still reads the Secure System Control Space and
> still gets `S=1` from the `TT` instruction: the register marks the core's bus
> traffic, not its architectural security state. Every measurement below stands
> exactly as written — the wall refuses, and it refuses for the reason given.
> What changes is that this is a **bus-level access filter**, not Armv8-M state
> separation, and a reader after a TrustZone lesson should know which one they
> are looking at.

The fifth experiment on the [signing road](../README.md#the-signing-road), and
the remedy [exp160](../exp160-a-secret-too-big-to-hide/) asked for after
[exp162](../exp162-how-wide-can-a-wall-be/) took the other answer away.

## What it is for

Four experiments got here:

- **exp159** put a P-256 key in SRAM bank 8, shut the bank to Non-secure code,
  and had the board sign a challenge it could not have known at build time. The
  wall refused every read. It passed.
- **exp160** put an ML-DSA-65 key behind the same wall. The wall still refused
  every read — and Non-secure code read the key anyway, out of the 369 KB of
  open stack that one post-quantum signature leaves behind. Two copies of the
  32-byte seed, in memory nothing was protecting.
- **exp162** asked whether a wider wall could cover them, and measured that
  `ACCESSCTRL.SRAM[n]` does not gate the *n*th 64 KB block at all. Banks 0–3 are
  word-interleaved across the lower 256 KB, banks 4–7 across the upper. **The
  longest run of addresses one register can deny is four bytes.**

So one answer remains: **use the key, then wipe.** This experiment measures
whether that works, what it costs, and — the question exp160 could not ask —
**how long the key is readable while it is being used.**

It does not answer that by sweeping its own memory afterwards. exp160 swept, and
a sweep run by the program that did the signing tells you what that program's
sweep can see. Here **a second core, demoted to Non-secure, reads all 512 KB in
a loop** — about 9.7 ms per pass, measured — from before the signature starts
until after the wipe ends. The finding is the shape of what it saw: nothing,
then the key, then nothing again, and exactly where the second nothing begins.

## The instrument is deliberately stronger than the threat

Candidate 1 shows that the demoted core cannot read bank 8. Candidates 3–6 then
**copy the seed into bank 9, where that same core can read it**. That is not a
hole; it is the design.

A watcher that had to *recognise* an ML-DSA private key by its structure would
be measuring its own cleverness. This one is handed the answer and told where to
look, which makes it better than any real attacker at the one job it has. So
when it goes quiet after the wipe, the quiet is worth something — and when it
sees the key 32 times during a signature, that is a **floor**, not a ceiling.

Two consequences worth stating plainly:

- The bank 9 copy is the harness's, not the leak's. It is outside the 512 KB
  being scanned and swept, so it never counts as a finding — and in a real
  design it would not exist.
- The seed also stays in bank 8 the whole time, because that is where a design
  like this keeps it. "Zero copies after the wipe" means zero copies **in the
  main SRAM**, which is the only place exp162 says cannot be protected.

## Three things this had to get right

### 1. The harness must not be the leak

The watcher scans the **whole** main SRAM, so any copy of the seed the harness
made would be found and counted. So the seed never exists as bytes outside the
region that gets wiped:

- `sign_once` reads it out of bank 8 into its own frame, inlined, and that frame
  is what every candidate paints, wipes and sweeps.
- The needle goes bank 8 → bank 9 a word at a time **through registers**. There
  is no `[u8; 32]` in `publish_needle`, on purpose.
- Core 0's own sweep compares against bank 8 a byte at a time rather than
  holding a copy to compare with.
- The buffer the TRNG fills on the first boot is **overwritten before it is left
  behind**. SRAM survives a watchdog reset, so those 32 bytes would still have
  been lying there when candidate 3 swept for them four boots later — and the
  harness would have been reported as a leak.

**Candidate 3 is what makes that checkable**: the watcher runs for a second and a
half with nothing signing, over 272 passes of the full 512 KB, and must see
nothing. It saw nothing.

### 2. The watcher must not live where it is looking

Core 1's stack and its mailbox are in **bank 9** — the second of the two 4 KB
banks, which exp162 established are the only ones not interleaved. That puts it
outside the 512 KB it scans, so it can never find its own needle, and outside
bank 8, so it never needs the access candidate 1 proves it does not have.

A `static mut CORE1_STACK` would have been placed by the linker in the main
SRAM, inside both the scanned region and the wiped one.

### 3. Phase boundaries must be exact

"Was it visible after the wipe?" cannot be answered by comparing pass numbers
across a race. Core 0 bumps an **epoch**; core 1 clears its counters at the top
of its next pass and acknowledges; core 0 waits for the acknowledgement before
going on. Every sighting therefore belongs to exactly one phase.

## The seven candidates

One per boot, one flash, driven by [`breadcrumb`](../../crates/breadcrumb/) —
the run reboots itself between candidates and the results ride through in bank
9.

| # | what it does | expected |
|---|---|---|
| 1 | the demoted core reads bank 8 | **DENIED** |
| 2 | the demoted core reads `TIMER0` | **DENIED** |
| 3 | the watcher runs, nothing signs | sees **nothing** |
| 4 | the watcher watches one signature, nothing is wiped | sees it, during **and** after |
| 5 | the same, and the region is wiped | sees it during, **nothing** after |
| 6 | the same, and only `sign_once`'s own frame is wiped | *measured, not graded* |
| 7 | the price, with nobody watching | the numbers a design would pay |

Candidates 4, 5 and 6 run the same code up to **one call**. That is the whole
argument: if candidate 4 did not see the key afterwards, candidate 5's silence
would not be the wipe's doing.

Candidate 6 is deliberately ungraded. "Is wiping just the frame enough?" is the
open question exp160 ended on, and a check that demands a particular answer to
an open question is not a check.

### Candidate 2 is a finding, not just a control

`ACCESSCTRL.TIMER0` **defaults to Secure access from any master**. A Non-secure
core on a stock RP2350 cannot read the microsecond counter — it faults. That is
why the watcher counts its own passes instead of timestamps, and it is measured
here rather than quoted from the datasheet.

It is also the strongest available proof that the watcher really is Non-secure:
two independent refusals from two unrelated peripherals.

## The result

Everything below is one run on a Pico 2, 2026-08-21. All seven candidates came
back `as expected`.

### The key is readable for the whole time it is in use

Candidate 4, no wipe:

```
signed in 147374 us, 423164 bytes deep; watcher saw it 32 times.
first at 0x20044498, passes 64..79 of sign 63..79.
```

The signature spanned the watcher's passes 63 to 79. The watcher saw the key in
passes **64 to 79** — from its first full pass after the key was expanded until
the signature finished. Then, with nothing wiping it, **167 more sightings**
over the next 800 ms, and core 0's byte-granular sweep of the whole 512 KB found
**2 copies** at `0x20044498` — the same count exp160 found by a completely
different method.

The window is not a slice of the signature. **It is the signature.**

### The wipe closes it, and costs almost nothing

Candidate 5 — identical to candidate 4 up to one call:

```
signed in 147407 us, 423164 bytes deep; watcher saw it 32 times.
wiped in 3392 us; afterwards the watcher saw it 0 times.
the byte-granular sweep of all 512 KB found 0 (first 0x00000000).
```

**3,392 µs to wipe 508,520 bytes — 2.3% of the signature it follows.** After it:
zero sightings by a Non-secure core reading continuously, and zero copies found
by a byte-granular sweep of every address in the main SRAM.

Two instruments, two cores, two granularities, same answer.

### exp160's open question: the frame **is** enough

Candidate 6 wipes only `sign_once`'s own stack frame — **240,160 bytes**,
measured on the board by reading `MSP` on entry rather than copied from another
experiment's disassembly.

```
sign_once's own frame measured 240160 bytes; wiping exactly that.
wiped in 1603 us; afterwards the watcher saw it 0 times.
the byte-granular sweep of all 512 KB found 0 (first 0x00000000).
```

**Zero copies**, even though the signature drove the stack **423,164 bytes**
deep — 183,004 bytes past the bottom of the frame that was wiped. Every copy of
the seed lives inside `sign_once`'s own frame; the 183 KB below it is scratch
that the seed never reaches.

That halves the price again: 1,603 µs instead of 3,392. Read the caveat in
[What is not verified here](#what-is-not-verified-here) before relying on it —
this is a statement about the 32-byte seed in this build, not about every piece
of secret material.

### The price of the only design that is left

Candidate 7, nobody watching:

```
expand 85916 us, sign 136175 us, wipe 3392 us.
```

exp162 means the expanded 65,696-byte key cannot be protected, so a design that
protects anything has to keep **only the 32-byte seed** behind the wall and
expand it again for every signature. That expansion is **85,916 µs of a
136,175 µs signature — 63% of the work.**

The wipe, by comparison, is 2.5%. **The expensive part of this design is not
cleaning up. It is that the key has to be rebuilt every time.**

### What being watched costs

Fixed message, fixed seed, deterministic FIPS-204 signing: candidates 4, 5, 6
and 7 do byte-identical work and print the same signature fingerprint
`f3173e8a1cb23f35…`. So their times subtract.

| | signing time |
|---|---|
| candidates 4, 5, 6 — a Non-secure core reading 512 KB in a loop | 147,374 / 147,407 / 147,404 µs |
| candidate 7 — nobody watching | 136,175 µs |

**+11,199 µs, or +8.2%**, and the three watched measurements agree to within
33 µs. An attacker doing nothing but reading memory slows down the thing it is
reading by about a twelfth, on a chip where both cores share one bus.

## What it cost to find out

Four flashes, and the first two rounds went to the instrument rather than the
subject.

### Round 1: five candidates measured a signature that was never made

Every candidate that touched the region came back `KILLED CORE 0`. And when the
ELF was finally examined instead of guessed at, `.bss` had come out **517 bytes
smaller than `SIGNATURE` and `PUBLIC_KEY` together**.

Both statics are written by `sign_once` and read by nobody. LLVM removed them,
and with them any reason to compute the signature at all. Five candidates were
measuring the memory left behind by a signature that never happened — and
candidate 4 would have reported a leak of zero copies and *passed*, as a
success, for the wrong reason.

The fix is two lines that print a fingerprint of each. That is not decoration;
it is the only use in the program that the optimiser cannot argue with.
`check.sh` now reads both sizes out of the ELF with `nm` on every run.

The deaths were fixed in the same round by moving the top of the region
**4 KB** below the stack pointer instead of 256 bytes: interrupts stay on while
half a megabyte is being written, and an exception frame taken mid-wipe lands
just below the stack pointer. **This was not isolated to one variable** —
two things changed at once and the run went green — so the mechanism above is
the reading of the evidence, not a measurement of it.

### Round 2: the timings could not be subtracted

It ran, and the numbers were useless for comparison: 148, 178, 265 and 296 ms
for four signatures. ML-DSA is **rejection-sampled**, so the work depends on the
message, and exp160 had already measured 3.9× between two of them. "Candidate 4
took 178 ms and candidate 7 took 296 ms" says nothing about what a watcher costs
when the two did different amounts of work.

Fixing the message and the seed makes the four signings **byte-identical**. The
spread went from 148 ms to 33 µs, and the four fingerprints agreeing is now also
how a reader can tell the signature was really computed.

### Round 3: "during" was not during

`during` was being read after two 25 ms fingerprint lines and a walk through
half a megabyte of `low_water`. The key is still lying in the dead frame through
all of that, so the count included sightings from after the signature had
finished: **46 sightings spanning passes 65..87 of a signature that ended at
pass 82.**

Those sightings are real. They are just not what a number called "while it was
in use" is allowed to count. Round 4 reads all five counters immediately after
`sign_once` returns, and the window closed to **64..79 of sign 63..79**.

## Running it

```console
cd experiments/exp163-how-long-is-a-secret-in-the-open
cargo build --release
elf2flash convert -b rp2350 \
  target/thumbv8m.main-none-eabihf/release/exp163-how-long-is-a-secret-in-the-open \
  target/exp163.uf2
yi26 bootsel && yi26 pflash target/exp163.uf2
yi26 log --seconds 150            # seven boots, about two minutes
./check.sh                        # 31 checks
```

Nothing here needs a hand on the board once it is flashed, and nothing here
writes flash or OTP. Every candidate reboots itself; the run ends disarmed and
reflashable.

To check a log you already have, on any machine, with nothing installed:

```console
python3 verify.py < capture.txt
```

`verify.py` reconciles **two independent records of the same run**: what each
candidate logged over USB at the moment it measured, and what bank 9 carried
through six watchdog resets to the final report. A wrong record layout, a bank
that did not survive, or a report reading the wrong offsets shows up as a
disagreement instead of as a plausible-looking table.

## Expected output

Pasted from a real run on a Pico 2, Ubuntu, 2026-08-21. Trimmed for length;
nothing is edited. The full 204-line run is checked in as
[`capture.txt`](./capture.txt).

```console
[    3250 ms] inherited FORCE_CORE_NS=0x00000000 SRAM8=0x000000ff; both reset.
[    3250 ms] bank 8 still holds this run's seed: it survived the reboot.
[    3250 ms] region: 0x20002bb0..0x2007ee18, 508520 bytes.
[    3250 ms] message (fixed, public): "exp163: the same message, always"

[    8250 ms] candidate 3 the watcher runs, nothing signs
[    8254 ms]   wiped in 3394 us. sweeping all 512 KB.
[    8293 ms]   inherited copies still in SRAM: 0 (first 0x00000000)
[    8906 ms]   watcher up: 62 passes, 0 sightings with nothing signing.
[   10974 ms]   the byte-granular sweep of all 512 KB found 0 (first 0x00000000).
[   10974 ms] candidate 3 -> as expected

[    8250 ms] candidate 4 the watcher watches one signature
[    9092 ms]   SGHD f3173e8a1cb23f351299310ca767fba0e0dde012dceefc6cc04f364c5a04f861
[    9114 ms]   signed in 147374 us, 423164 bytes deep; watcher saw it 32 times.
[    9114 ms]   first at 0x20044498, passes 64..79 of sign 63..79.
[   10002 ms]   wiped in 0 us; afterwards the watcher saw it 167 times.
[   10002 ms]   the byte-granular sweep of all 512 KB found 2 (first 0x20044498).
[   10002 ms] candidate 4 -> as expected

[    8250 ms] candidate 5 the same, and the region is wiped
[    9114 ms]   signed in 147407 us, 423164 bytes deep; watcher saw it 32 times.
[    9971 ms]   wiped in 3392 us; afterwards the watcher saw it 0 times.
[    9971 ms]   the byte-granular sweep of all 512 KB found 0 (first 0x00000000).
[    9971 ms] candidate 5 -> as expected

[    8250 ms] candidate 6 only the signing frame is wiped
[    9114 ms]   signed in 147404 us, 423164 bytes deep; watcher saw it 32 times.
[    9114 ms]   sign_once's own frame measured 240160 bytes; wiping exactly that.
[    9975 ms]   wiped in 1603 us; afterwards the watcher saw it 0 times.
[    9975 ms]   the byte-granular sweep of all 512 KB found 0 (first 0x00000000).
[    9975 ms] candidate 6 -> as expected

[    8250 ms] candidate 7 the price, with nobody watching
[    8611 ms]   expand 85916 us, sign 136175 us, wipe 3392 us.
[    8611 ms]   stack went 423164 bytes deep; copies left afterwards: 0
[    8611 ms] candidate 7 -> as expected

[    3250 ms] exp163 done after 8 boots. Nothing armed; still reflashable.
[    3250 ms]   1 Non-secure reads bank 8, DENIED - as expected
[    3275 ms]   2 Non-secure reads the clock, DENIED - as expected
[    3300 ms]   3 the watcher runs, nothing signs - as expected
[    3325 ms]   4 the watcher watches one signature - as expected
[    3350 ms]   5 the same, and the region is wiped - as expected
[    3375 ms]   6 only the signing frame is wiped - as expected
[    3400 ms]   7 the price, with nobody watching - as expected
[    3425 ms] the numbers, out of bank 9:
[    3651 ms]   4 stale=0 quiet=0 during=32 after=167 sweep=2
[    3676 ms]       passes=168 seen 64..79 of sign 63..79
[    3701 ms]       sign=147374 us wipe=0 us expand=0 us depth=423164 B
[    3726 ms]   5 stale=0 quiet=0 during=32 after=0 sweep=0
[    3776 ms]       sign=147407 us wipe=3392 us expand=0 us depth=423164 B
[    3801 ms]   6 stale=0 quiet=0 during=32 after=0 sweep=0
[    3851 ms]       sign=147404 us wipe=1603 us expand=0 us depth=423164 B
[    3926 ms]       sign=136175 us wipe=3392 us expand=85916 us depth=423164 B
[    3976 ms] VERDICT: a Non-secure core saw the key 32 times while it was in use,
[    4001 ms]   and 0 times after the wipe; the 512 KB sweep then found 0.
[    4026 ms]   wiping only the 240160-byte frame leaves 0 copies behind.
```

`./check.sh` on the same board:

```console
PASS  toolchain present (cargo, elf2flash)
PASS  firmware compiles (220696 byte ELF)
PASS  converts to UF2 (92672 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  the firmware never writes ACCESSCTRL.LOCK
PASS  the firmware writes nothing permanent (no flash, no OTP)
PASS  the signature and public key survive optimisation (3309 + 1952 bytes in .bss)
PASS  core 1's stack and mailbox are in bank 9, outside what it scans
PASS  seed_from_bank8 is inlined into the frame that gets wiped
PASS  the needle goes bank 8 -> bank 9 through registers, never an array
PASS  the buffer the TRNG filled is wiped, volatile, on the boot that fills it
PASS  the wipe writes volatile, so it cannot be optimised out
PASS  the paint is not zero, so a wipe and an untouched word differ
PASS  every candidate signs the same fixed message
PASS  the bank 9 layout is checked at build time
PASS  the product string is bounded at build time
PASS  the LED heartbeat starts before the USB stack
PASS  the run has a hard stop that disarms
PASS  verify.py replays the recorded capture
PASS  the corrupted-capture test actually corrupts something
PASS  verify.py rejects a capture where the wipe left something (got DISAGREE)
PASS  board enumerated as 1209:0001
PASS  every candidate was attempted
PASS  no candidate killed the reporting core
PASS  all seven candidates behaved as expected
PASS  control: the wall refuses the demoted core
PASS  control: that core cannot read TIMER0 either
PASS  control: a watcher with nothing to find finds nothing
PASS  a Non-secure core read the key while a Secure core was using it
PASS  and after the wipe it read nothing, in 512 KB, twice over
PASS  the board's own records hold up, re-checked off the board
```

Two of the three PASS lines about `verify.py` are the same guard from opposite
sides: it agrees with a real capture, and it stops agreeing when one number in
that capture is changed. The third asserts that the change was actually made,
because exp160 shipped a corruption test that corrupted nothing and read as a
pass for it.

## What is not verified here

- **Only the 32-byte seed was searched for.** The expanded key — `s1`, `s2`,
  `t0`, and every intermediate the signature computes from them — is secret too,
  and nothing here looks for it. "Zero copies after the wipe" means zero copies
  **of the seed**. Candidate 6's result in particular ("the frame is enough")
  says the seed does not travel past `sign_once`'s frame; it does not say the
  same about anything derived from it.
- **The wipe covers the main SRAM only.** The seed stays in bank 8, by design.
  A copy of it is in bank 9 because this harness put it there for the watcher —
  a real design would not.
- **The watcher is word-aligned.** It compares a word at each 4-byte boundary, to
  be fast enough to resolve a 147 ms signature at all. A copy at an odd offset
  would be invisible to it. Core 0's byte-granular sweep of all 512 KB is what
  covers that case, and it agrees at every step.
- **The watcher is a detector, not a discoverer.** It is handed the seed. It
  proves the bytes are readable, not that an attacker would find them.
- **One board, one part, one build, one seed per flash.** The 8.2% is what *this*
  watcher costs; a different access pattern would cost differently. The 63%
  expansion share is this crate at `opt-level = "s"`.
- **Nothing here involves DMA, the debug port, or power analysis.** The only
  attacker modelled is code running Non-secure on core 1.
- **Bank 9 surviving seven watchdog resets is an observation.** It did, in this
  run and every other; nothing in the datasheet was consulted for it, and the
  final report prints "no record" rather than nothing if it ever does not.
- **The round 1 diagnosis is a reading of the evidence.** Two variables changed
  together and the deaths stopped. See [What it cost to find
  out](#round-1-five-candidates-measured-a-signature-that-was-never-made).

## Four things to take away

1. **A wall that only holds while the key is idle is not a wall.** Across a
   147 ms signature, the key was continuously readable by a core with no
   privilege at all. Everything exp159 and exp160 built is true, and true only
   between signatures.
2. **The remedy is real and it is cheap.** 3.4 ms, 2.3% of a signature, and two
   instruments agree that nothing is left. The reason to be uneasy about it is
   not its cost — it is that it runs *after* the window it cannot close.
3. **A static nobody reads is a computation nobody performs.** `.bss` was 517
   bytes short and five candidates were measuring nothing. The check that would
   have caught it on day one is two sizes out of the ELF, and it now runs every
   time.
4. **Fix the message before you subtract the times.** Rejection sampling made
   four measurements of the same thing differ by 148 ms. With the message fixed
   they differ by 33 µs, and an 11 ms effect becomes visible that was completely
   buried before.

## Next

The instrument this experiment built is more interesting than the finding it was
built for, and it points at two things:

- **Search for the expanded key, not the seed.** The watcher would need a needle
  it can recognise in `s1` or `t0`, and the answer to "does the frame contain
  it?" may well be different. That is the question candidate 6 is one honest
  step short of.
- **Close the window instead of cleaning up after it.** Nothing on this part can
  make the 65,696-byte working set unreadable — exp162 settled that. But the
  window measured here is 147 ms of *wall clock*, and the only reason the
  watcher gets 16 passes inside it is that both cores are running. What a
  Secure-only sequence would look like, and whether it is even expressible with
  `FORCE_CORE_NS` and no SAU, is not something this road has asked yet.
