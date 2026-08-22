# exp162-how-wide-can-a-wall-be — where the eight banks actually are

The fifth experiment on the [signing road](../README.md#the-signing-road), and
the one [exp160](../exp160-a-secret-too-big-to-hide/) asked for in its last
paragraph: *settle whether banks 0–7 map to the address range in a way that
would let a >64 KB secret region exist at all.* exp160 also wrote down what a
"no" would mean, before it knew the answer:

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

> **If the answer to the last one is no, then this chip cannot hide an ML-DSA
> private key in use**, and that is a finding the road should record before
> anything is built on the assumption that it can.

It is a no, and it is worse than the sentence that predicted it.

## The claim

> **`ACCESSCTRL.SRAM[n]` does not gate the *n*th 64 KB block. Banks 0–3 are
> word-interleaved across the lower 256 KB and banks 4–7 across the upper 256 KB,
> so the longest run of consecutive addresses any one register can deny to
> Non-secure code is four bytes — measured on a Pico 2 by a demoted core, one
> address at a time, with the controls that make a refusal mean something.**

There is no cryptography here at all, which is deliberate: exp156 measured a
wall with no cryptography in it precisely so that a failure could only be about
the wall, and this is that shape one layer along.

---

## What it costs the road

| | exp160 believed | exp162 measured |
| --- | --- | --- |
| what one `SRAM[n]` register gates | one contiguous 64 KB bank | **4 contiguous bytes**, repeating every 16 |
| largest region deniable to Non-secure, in one piece | 64 KB | **4 bytes** in the main SRAM |
| how much a 65,696-byte signing key misses by | 160 bytes | it is not a near miss |
| the largest place a secret can actually live | — | **bank 8 or bank 9**, 4 KB each, and they are not one of the eight |

exp160's second idea to take away says:

> **The granularity of your protection is a hard limit on what you can
> protect.** 65,696 bytes against a 65,536-byte bank is not a tuning problem.

The sentence is right and the number in it is wrong by a factor of sixteen
thousand. **A register does not gate a block; it gates every fourth word of a
256 KB half.** Shutting `SRAM[0]` takes four bytes out of every sixteen across
the whole lower half — out of `.data`, out of `.bss`, out of the stack of
whatever is running Non-secure — so there is no arrangement of these eight
registers that produces a contiguous protected region of *any* size in the main
512 KB.

**Which means exp159's keystore was never standing on what its README said.**
exp159 put its key in bank 8 for a stated reason — "core 1's stack stays in the
main region" — and treated the choice of a 4 KB bank as a convenience. It was
the only thing that could have worked. Bank 8 and bank 9 are the two banks that
are *not* interleaved, and this run demonstrates it in passing: core 1's stack
and this experiment's mailbox are both in bank 8, and they keep working through
candidate 15, which denies all eight of the others.

---

## How this was designed, in the order it happened

### 1. Establish the facts first

Six, before a line was written, and two of them removed a design each.

| fact | how | what it changed |
| --- | --- | --- |
| `rp-pac`'s doc for `ACCESSCTRL.SRAM[n]` names the register "SRAM0" and gives **no address** | read the PAC | the map cannot be read, only measured |
| `rp2350-linker`'s `RAM` region is `0x2000_0000` for **512K** | read `memory.x` | banks 8 and 9 are outside everything the linker places, which is what makes them usable here |
| `ACCESSCTRL.LOCK` reads `0x0000_0004` — **bit 2, DMA, locked by the bootrom** | exp160 measured it | ← killed the obvious fault-free probe: a denied DMA transfer reports an error in a register instead of faulting a core, and that bit cannot be changed |
| `Stack<N>` is `#[repr(C, align(32))]` around a public `[u8; N]` | read `embassy-rp` | core 1's stack can be a forged reference at a fixed address, with no linker script |
| `spawn_core1` writes to statics in the main SRAM, and its `fifo_read()` returns only after core 1 has copied the entry closure | read `multicore.rs` | ← fixed the **order**: launch first, wall second |
| `spawn_core1` leaves `SIO_IRQ_FIFO` enabled on core 1, and its handler is embassy's | read `multicore.rs` | core 1 masks interrupts before it does anything else |

### 2. Ask what has already been answered

exp156 established that `ACCESSCTRL` writes need `0xACCE` in bits 31:16, that
`FORCE_CORE_NS` demotes a core that is already running, and that the boundary
belongs between the two cores so the fault lands on a core that is not holding
USB. exp159 established that bank 8 is real, that `SRAM[8]` gates it, and that
it survives a watchdog reset. exp158 established the one-candidate-per-boot
harness. None of it was re-derived.

### 3. Name the contradictions

#### C1 · Every core that could ask the question needs somewhere to stand

The measurement is *which addresses does a Non-secure core get refused*, and the
last candidate refuses all eight banks. A core 1 with its stack in the main
512 KB dies on its own prologue, and the run reports a refusal it caused rather
than one it measured.

So core 1 gets bank 8: the low 3 KB is its stack, the rest is the mailbox, its
code runs from flash — which `XIP_MAIN` leaves fully open — and its first
instruction masks interrupts, so that no handler of embassy's touches the main
SRAM on its behalf while the wall is up.

**That turns the last candidate into its own control.** It can only answer at
all if nothing it needs is in banks 0–7.

#### C2 · exp159's reason for the mailbox does not survive here

exp159 put its mailbox in the **main** SRAM and said why: `SRAM` defaults to
fully open, so Non-secure writes there with nothing programmed. That reason is
correct and it is unavailable here, because the main SRAM is what gets shut.
Bank 8 defaults open too, so the property carries and only the address changes.

#### C3 · The launch and the wall cannot happen in that order

`spawn_core1` and embassy's `core1_startup` write to statics in the main SRAM.
A core launched into an already-shut main SRAM dies on the launch. So the
sequence is: **launch with everything open and Secure → raise the wall → demote
→ release**. The first draft had the wall first, and the only reason it never
produced a wrong reading is that it was found by reading `multicore.rs` rather
than by watching a board fail.

#### C4 · A firmware that grades its own measurements presumes the answer

Twelve of the fifteen candidates have **no expected outcome**. Candidates 1, 2
and 15 are controls and are graded; the rest record what happened — allowed or
denied, one bit, which is all a reading is — and the interpretation happens at
report time.

That distinction earned itself immediately. See below.

### 4. Write it as a matrix

```text
   1  nothing shut,   read 0x20000000    must be ALLOWED   (control)
   2  bank 0 shut,    read 0x20000000    must be DENIED    (control)
   3  bank 0 shut,    read 0x20010000    measured   <- the headline
   4  bank 0 shut,    read 0x20000004    measured   \
   5  bank 0 shut,    read 0x20000008    measured    | how wide a piece
   6  bank 0 shut,    read 0x20000010    measured    | one register owns
   7  bank 0 shut,    read 0x20000020    measured   /
   8  bank 1 shut,    read 0x20000004    measured   \
   9  bank 2 shut,    read 0x20000008    measured    | which register owns
  10  bank 3 shut,    read 0x2000000c    measured   /  the words next door
  11  bank 4 shut,    read 0x20000000    measured   \
  12  bank 0 shut,    read 0x20040000    measured    | is the upper half a
  13  bank 4 shut,    read 0x20040000    measured   /  different four?
  14  bank 2 shut,    read 0x20000040    measured   <- separates two maps
  15  all eight shut, read 0x2007fffc    must be DENIED    (control)
```

**Candidates 1 and 2 are exp156's whole lesson.** A refusal on its own is one
failed access; the same core reading the same address a moment earlier with one
register bit different is what makes it a measurement. exp156 needed eight
rounds to get there and nearly published a wall the bootrom had left standing.

**Candidate 3 is the headline in one reading.** If `0x2001_0000` is refused
while only bank 0 is shut, bank 0 is not the first 64 KB, and nothing about
"each bank is a block" survives.

**Candidate 14 exists for one reason**: without it, the two 32-byte-grain
arrangements predict identical readings, and naming one of them would be
picking. That was found by enumerating all thirteen and checking for collisions,
not by believing there were none — and `verify.py` re-checks it every run before
it looks at a single reading.

---

## The first round could not name the answer, and said so

This experiment was flashed three times, and the first two rounds are worth
recording rather than tidying away.

**Round one asked nine candidates and carried a table of five precomputed
patterns** — contiguous, and four stripe widths. The board came back with a
reading that matched none of them and printed:

```text
[    8075 ms]   NO ARRANGEMENT FITS. The four grain readings and the 0x20010000 pair
[    8075 ms]   disagree with every map this experiment can express. That is a finding
[    8075 ms]   and not a pass: read the nine lines above and do not trust the summary.
```

That is the instrument working, and it is the direct payoff of C4. Nine of the
nine candidates were correct measurements; what was wrong was the *question*,
because a five-row table cannot express a map where the eight banks are split
into two groups of four. A firmware that had graded those candidates would have
called a correct run a failure.

Round two replaced the table with **arithmetic** — thirteen arrangements
generated from `ways` and `grain`, each asked to predict all fifteen readings —
and added the six probes that tell them apart. Every reading it produced was
right, and it printed none of them, because twenty lines went into a queue that
is sixteen deep and drops the newest. That is the failure exp160 documented
against itself, arriving in the experiment that had read the write-up.

Round three paces the two long blocks at 25 ms a line. Nothing else changed.

> **Two rounds went to the report and none to the subject.** The reading has
> been the same since the first flash. That is [`the-board-is-the-loop`](../../docs/the-board-is-the-loop.md)'s
> arithmetic in miniature and the lesson is its lesson: the thing that costs
> rounds is rarely the measurement.

---

## The result

All fifteen candidates were reached, the three controls held, and **exactly one
of the thirteen arrangements predicts all fifteen readings**:

```text
banks 0-7 are two halves, 4-way, 4-byte grain.
```

`SRAM[0]` gates `0x2000_0000`, `0x2000_0010`, `0x2000_0020` … and **not**
`0x2000_0004` or `0x2000_0008`, which belong to `SRAM[1]` and `SRAM[2]`. It also
gates `0x2001_0000`, 64 KB up — which is the reading that ends the contiguous
map — and it does **not** reach `0x2004_0000`, which is `SRAM[4]`'s. So:

- **banks 0–3 are word-interleaved across the lower 256 KB**, four bytes each in
  turn
- **banks 4–7 are word-interleaved across the upper 256 KB** the same way
- the longest run of consecutive addresses any one register denies is **4 bytes**

Two things fell out for free:

- **`FORCE_CORE_NS` and `ACCESSCTRL.SRAM[0]` do not survive a watchdog reset.**
  Every one of the sixteen boots read them back as `0x00000000` and `0x000000ff`
  — the second being the power-on default the PAC documents, *fully open*.
  exp159 and exp160 both re-wrote these registers on every boot without ever
  asking whether they had to; they had to.
- **Bank 8 does survive it**, for the third experiment running. The mailbox magic
  written on boot 1 was still there on boots 2 through 16.

## How to see it

```sh
./check.sh                        # exit 0; asserts the controls and the verdict
yi26 log --seconds 40             # the settled report, repeating every five seconds
python3 ./verify.py < capture.txt # re-derive the verdict by hand, no board needed
```

The run takes about **three and a half minutes** and the port disappears fifteen
times, so `yi26 log` returns fragments until it settles. `check.sh` polls for the
settled state.

LED: **slow** while the matrix is being walked, **fast** once it is done.

## Expected output

Pasted from a real run on a Pico 2, Ubuntu, 2026-08-21, flashed with
`yi26 flash` and read across the board's own reboots. This is the settled report
block, which repeats every five seconds; it is checked in as
[`capture.txt`](./capture.txt) and `check.sh` replays it through `verify.py`.

```console
[    3450 ms] exp162 done after 16 boots. Nothing armed; still reflashable.
[    3450 ms]   1 nothing shut, read 0x20000000 - allowed (as expected)
[    3475 ms]   2 bank 0 SHUT, read 0x20000000 - DENIED (as expected)
[    3500 ms]   3 bank 0 SHUT, read 0x20010000 - DENIED (measured)
[    3525 ms]   4 bank 0 SHUT, read 0x20000004 - allowed (measured)
[    3550 ms]   5 bank 0 SHUT, read 0x20000008 - allowed (measured)
[    3575 ms]   6 bank 0 SHUT, read 0x20000010 - DENIED (measured)
[    3600 ms]   7 bank 0 SHUT, read 0x20000020 - DENIED (measured)
[    3625 ms]   8 bank 1 SHUT, read 0x20000004 - DENIED (measured)
[    3650 ms]   9 bank 2 SHUT, read 0x20000008 - DENIED (measured)
[    3675 ms]   10 bank 3 SHUT, read 0x2000000c - DENIED (measured)
[    3700 ms]   11 bank 4 SHUT, read 0x20000000 - allowed (measured)
[    3725 ms]   12 bank 0 SHUT, read 0x20040000 - allowed (measured)
[    3750 ms]   13 bank 4 SHUT, read 0x20040000 - DENIED (measured)
[    3776 ms]   14 bank 2 SHUT, read 0x20000040 - allowed (measured)
[    3801 ms]   15 all eight SHUT, read 0x2007fffc - DENIED (as expected)
[    3826 ms] VERDICT: exactly one arrangement predicts all fifteen readings.
[    3851 ms]   banks 0-7 are two halves, 4-way, 4-byte grain.
[    3876 ms]   The longest run of addresses one register gates is 4 bytes.
[    3901 ms]   So one register does NOT gate one 64 KB block: it gates one 4-byte
[    3926 ms]   piece in every 4, scattered from one end of its half to the other.
[    3951 ms]   Shutting it takes 4 bytes out of every 16 across 256 KB, including out
[    3976 ms]   of the stack of whatever is running Non-secure.
[    4001 ms]   THE ANSWER exp160 ASKED FOR IS NO, and it is worse than exp160 feared:
[    4026 ms]   the limit is not 64 KB, it is 4 bytes. Not one contiguous byte more than
[    4051 ms]   that can be denied to Non-secure code anywhere in the main 512 KB, so a
[    4076 ms]   65,696-byte ML-DSA-65 signing key cannot go behind ACCESSCTRL at all.
[    4101 ms]   What exp159's keystore stands on is bank 8, which is none of these eight:
[    4126 ms]   core 1's stack and this mailbox are in it and they survived candidate 15,
[    4151 ms]   with all eight shut. That is the only kind of place a secret can live.
```

`./check.sh` on the same board:

```console
PASS  toolchain present (cargo, elf2flash)
PASS  firmware compiles (214556 byte ELF)
PASS  converts to UF2 (59392 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  the firmware never writes ACCESSCTRL.LOCK
PASS  the firmware writes nothing permanent (no flash, no OTP)
PASS  core 1's stack and the mailbox are both in bank 8
PASS  every candidate opens all eight banks before shutting any
PASS  twelve of the fifteen candidates are ungraded measurements
PASS  the product string is bounded at build time
PASS  the LED heartbeat starts before the USB stack
PASS  the run has a hard stop that disarms
PASS  the fifteen probes tell all thirteen arrangements apart
PASS  verify.py replays the recorded capture
PASS  the corrupted-capture test actually corrupts something
PASS  verify.py rejects a capture with one reading flipped (got NOFIT)
PASS  board enumerated as 1209:0001
PASS  every candidate was attempted
PASS  no candidate killed the reporting core
PASS  the three controls behaved as expected
PASS  control: a demoted core reads the main SRAM when nothing is shut
PASS  control: the same read is refused once this firmware shuts bank 0
PASS  control: the eight registers reach the top of the 512 KB
PASS  exactly one arrangement of the eight banks fits the readings
PASS  the readings imply the board's verdict, derived off the board
```
## What is not verified here

- **Only reads, and only by a CPU.** Nothing tries a Non-secure *write*, a DMA
  transfer, or the debugger. `ACCESSCTRL` has bits for DMA and DBG; the DMA bit
  is locked out by the bootrom (exp160 measured it) and the DBG bit is
  untouched.
- **The map is named from a family of thirteen, not from all possible maps.**
  Every arrangement here is "cut the range into equal contiguous chunks and
  interleave `ways` banks at `grain` bytes inside each". A real map outside that
  family that happens to predict all fifteen readings would be reported as the
  arrangement it collides with. Fifteen readings is not a proof of a map; it is
  fifteen readings and one surviving hypothesis.
- **Which bank the mailbox is in is not separated from bank 9.** Core 1's stack
  and the mailbox demonstrably live outside all eight — that is candidate 15 —
  but nothing here distinguishes `SRAM[8]` from `SRAM[9]` for the addresses they
  occupy, because the probe that would do it kills the core doing the probing.
- **The SAU was not tried, and nobody here had read it yet.** Everything above
  measures `ACCESSCTRL`'s granularity. The Armv8-M unit that actually attributes
  memory went unexamined until [exp164](../exp164-the-wall-nobody-read/), and
  [exp165](../exp165-who-gets-the-last-word/) later found its regions are
  32-byte-aligned and any length — no four-byte floor. That does not overturn
  anything here; it means **"the longest run one register can deny" is a fact
  about this register**, and the same question asked of the SAU is open. exp165
  did not probe the main 512 KB either, so it is open in the place that matters.
- **`ACCESSCTRL.LOCK` is deliberately never written**, so every configuration
  here is one power cycle from ordinary — which also means **none of it survives
  a reset on its own**.
- **The off-board check is weaker than exp159's and says so.** exp159 sent its
  signature to a different implementation of the same standard. There is no
  second implementation of an SRAM bank map, so `verify.py` gives the same
  arithmetic written again in another language, from the address rather than
  from the firmware's table. It catches a transcription error, a wrong probe
  address, or a verdict that does not follow from the readings above it. It does
  not catch both files being wrong about the same idea.

## The ideas to take away

1. **Do not let a table decide what answers are possible.** Round one's five
   precomputed patterns were not a shortcut for the arithmetic; they were a
   silent assumption about the shape of the answer, and the chip was outside it.
   A prediction derived from the question can be wrong about the world. A table
   can also be wrong about *what was asked*.

2. **A measurement and a verdict are different things, and the firmware should
   know which it is holding.** Twelve of fifteen candidates here are ungraded on
   purpose. It cost nothing to write and it is the only reason round one
   reported a correct run as a correct run.

3. **Ask what the mechanism protects before choosing what to protect with it.**
   exp159 and exp160 both built on "a bank is 64 KB of adjacent addresses",
   which nobody had measured and which is false. Two experiments' worth of
   arithmetic rested on it. The measurement that settles it is fifteen reads and
   needs no cryptography at all.

4. **The thing that costs rounds is rarely the subject.** Three flashes: one for
   a table that could not express the answer, one for a queue that dropped it,
   one that printed it. The readings were identical in all three.

## Next

**Done: [exp163](../exp163-how-long-is-a-secret-in-the-open/)**, and it took
both halves of what this section asked for.

The remedy works and is cheap: **3,392 µs to wipe 508,520 bytes, 2.3% of the
signature it follows**, after which a Non-secure core reading the whole 512 KB
in a loop sees nothing and a byte-granular sweep finds nothing. It also measured
the window this experiment implied but could not see: across one 147 ms
signature the key was **continuously readable** by that core — 32 sightings in
passes 64 to 79 of a signature that spanned 63 to 79. The wall is not narrow in
space only. While the key is in use there is no wall at all.

And the question this section sharpened — *what is bank 8 good for, if
65,696 bytes fit in neither 64 KB nor 4 KB* — has a number now. A 32-byte seed
fits, and expanding it back into a key costs **85,916 µs of a 136,175 µs
signature: 63% of the work, on every signature.** That is what bank 8 is good
for, and that is its price.
