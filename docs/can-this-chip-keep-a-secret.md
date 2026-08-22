# Can this chip keep a secret?

Eight experiments on the [signing road](../experiments/README.md#the-signing-road)
asked one question in different ways: **can an RP2350 hold a private key that
its own firmware cannot read?** They were built in order, each one measuring
what the last one assumed, and between them they answer it.

This document is the answer. It exists because the answer is spread across
eight READMEs, three of them long, and because a reader deciding whether to
build something on this part deserves it in one place with the scope attached.

Every number here was measured on a Raspberry Pi Pico 2 and is linked to the
experiment that measured it. Nothing here is new work.

---

## The answer, with its scope attached

| the secret | the mechanism | result |
|---|---|---|
| 32 bytes **at rest** | `ACCESSCTRL` | **kept.** Every Non-secure read of the bank was refused |
| the same 32 bytes **while ECDSA P-256 uses them** | `ACCESSCTRL` | **kept.** The working set fits behind the wall |
| the same 32 bytes **while ML-DSA-65 uses them** | `ACCESSCTRL` | **lost.** The expanded key is 65,696 bytes and lands in open stack |
| 65,696 bytes, at any moment | `ACCESSCTRL` | **impossible.** One register can deny four contiguous bytes |
| 65,696 bytes, at any moment | **the SAU** | **not measured** |

So the honest one-line answer is:

> **Yes for a small secret, and no for a post-quantum one — with `ACCESSCTRL`,
> which is the only mechanism this repository has ever made refuse anything.**

The last row is the frontier and is discussed in
[What is still open](#what-is-still-open). It is not a loophole anybody should
build on yet.

---

## How the question came to be asked

The road started from two experiments built elsewhere, `exp107-trustzone-ecdsa`
and `exp108-trustzone-mldsa`, which sign a hash inside what they call the Secure
World. Reading them decided the shape of everything after:

- **They are one experiment, not two.** Their sources differ by a package name
  and one dependency line — `p256` becomes `ml-dsa`. So the cryptography is a
  variable and the thing worth building is whatever holds still while it changes.
- **The boundary they demonstrate is not enforced.** There is no SAU
  programming in either. What they prove is that a function can be *called*. The
  claim they are named for is that a key cannot be *read*, and that claim was
  untested.

So the road put the wall first and the cryptography last, and
[exp140](../experiments/exp140-a-checksum-that-passes/) is the argument for why:
a check that cannot fail has not passed.

---

## The evidence, in the order it arrived

### OTP stores; it does not hide

[exp154](../experiments/exp154-somewhere-to-put-a-key/) swept all **4096 OTP
rows** through the HAL on a stock Pico 2 and printed what each one said:
**23 programmed, 4073 blank, and not one row refused a read** — to ordinary
firmware with no privilege of any kind.

It also settled what the prior work was reading. Rows `0xE80`–`0xE8F`, which
`exp107`/`exp108` take a device key from, are blank, so a firmware that falls
back to a compiled-in test key **falls back every time, on every board**.

> **OTP is a place to store a key, not a place that hides one.** Whatever
> conceals a key on this part has to be built.

### There is a wall, and it can be measured

[exp156](../experiments/exp156-a-wall-you-can-measure/) built the smallest thing
that could be one: one core, one address, **three** reads, with exactly one
thing changed between each pair. Secure with the wall open, Non-secure with the
wall open, Non-secure with it shut — the first two return `0x44570140` and the
third takes a bus fault.

The middle read is the lesson and it cost a whole round. Without it the
experiment reported a wall it had not built: the peripheral it chose already
denied Non-secure at power-on, so the "deny" write wrote the value that was
already there.

> **A boundary you did not build is not a boundary you measured.** Open it
> before you shut it.

### A small key works, end to end

[exp159](../experiments/exp159-a-key-that-was-never-in-flash/) put a P-256 key
in **SRAM bank 8** — one of the RP2350's two 4 KB banks, which `ACCESSCTRL`
gates separately from the main 512 KB — and signed a challenge the board could
not have known at build time. Secure reads the key; Non-secure reads it while
the bank is open; Non-secure **faults** once it is shut; and with it still shut,
Non-secure asks over a mailbox and gets 64 bytes back. **61 ms per signature.**

**The key is never in flash, and that is the finding rather than a detail.**
`XIP_MAIN` defaults to fully open, so a key compiled into the source would be
readable by exactly the code the wall exists to stop.

This is the road's one unqualified success, and it is still true.

### The same wall, a much larger signature

[exp160](../experiments/exp160-a-secret-too-big-to-hide/) swapped in ML-DSA-65
and found the swap costs nothing where everyone expects it to. The
post-quantum signing path is **16,380 bytes of `.text` against P-256's 20,356**
on an identical baseline — the *smaller* code.

What it costs is RAM, and the wall does not survive it. exp159's boundary still
refuses every Non-secure read of bank 8 in the same run — and Non-secure code
read the private key anyway, out of **369,456 bytes of ordinary open stack** one
signature leaves behind. Two intact copies of the 32-byte seed.

The key at rest is 32 bytes. **In use it is a 65,696-byte object, 160 bytes
larger than the biggest thing anyone then believed `ACCESSCTRL` could gate.**

And exp159's headline, ported unchanged, **passes** in the same run. An
experiment that stopped there would have shipped a hollow success.

### The wall is sixteen thousand times narrower than that

[exp162](../experiments/exp162-how-wide-can-a-wall-be/) asked whether a wider
wall could cover the working set, and the answer reframed the mechanism.

**`ACCESSCTRL.SRAM[n]` does not gate the *n*th 64 KB block.** Banks 0–3 are
word-interleaved across the lower 256 KB and banks 4–7 across the upper, so
**the longest run of consecutive addresses one register can deny is four
bytes**. Shutting `SRAM[0]` takes four bytes out of every sixteen across half
the SRAM — out of `.data`, out of `.bss`, out of whatever stack is running
there.

So there is no arrangement of the eight that produces a contiguous protected
region of *any* size in the main 512 KB. The only contiguous ones are **banks 8
and 9, 4 KB each**, which are not among the eight — and which is why exp159
worked at all. Bank 8 was chosen for a convenience, and it was the only thing
that could have worked.

> The limit is not 64 KB and a 65,696-byte key is not a near miss.

### So: use it, then wipe it — and here is what that costs

[exp163](../experiments/exp163-how-long-is-a-secret-in-the-open/) took the only
remedy left and refused to measure it with the program that did the signing. **A
second core, demoted, reads all 512 KB in a loop** — about 9.7 ms a pass — from
before the signature starts until after the wipe ends.

- **The window is not part of the signature; it is the signature.** The seed was
  visible **32 times inside one 147 ms signing**, and with nothing wiping it,
  167 more times over the next 800 ms.
- **The wipe works and is cheap.** 3,392 µs for 508,520 bytes — **2.3% of the
  signature** — after which the watcher sees nothing and a byte-granular sweep
  of every address in main SRAM finds nothing.
- **Wiping only the signing function's own 240,160-byte frame is enough for the
  seed**, even though the signature drives the stack 423,164 bytes deep.
- **The expensive part is not the cleanup.** Keeping only the seed behind the
  wall means expanding it into a full key every time, and that is **85,916 µs of
  a 136,175 µs signature: 63% of the work.**

> Everything exp159 and exp160 built is true, and true only **between**
> signatures.

### And it was never TrustZone

[exp164](../experiments/exp164-the-wall-nobody-read/) read the Armv8-M **SAU**,
which none of the five experiments above had ever looked at, and corrected a
word all of them used.

A core demoted with `ACCESSCTRL.FORCE_CORE_NS` **reads the Secure System Control
Space and gets core 0's values**, and its `TT` response is core 0's response bit
for bit, `S` bit included — and then faults on a bank `ACCESSCTRL` has shut,
which is the control proving the demotion was real.

> **`FORCE_CORE_NS` marks the bus, not the core.** What these experiments call a
> "Non-secure core" is Non-secure to a bus filter and Secure to the
> architecture.

Every measurement above stands. What changes is that they demonstrate a
**bus-level access filter**, not Armv8-M state separation — and the two are not
the same thing to anybody reading them for a lesson about TrustZone.

---

## What actually works, if you are building something

Three mitigations are measured. Two of them work.

| | what it costs | where |
|---|---|---|
| **Use a key whose working set fits the wall.** P-256's does; ML-DSA-65's does not | it is classical, not post-quantum. 61 ms a signature | [exp159](../experiments/exp159-a-key-that-was-never-in-flash/) |
| **Use the key, then wipe.** A second core watching the whole of SRAM sees nothing afterwards | 2.3% to wipe, and **63%** to rebuild the key from its seed each time | [exp163](../experiments/exp163-how-long-is-a-secret-in-the-open/) |
| **Do not put a private key on the board.** If the board's job is to *check* signatures rather than make them, none of this applies | nothing — see below | [exp166](../experiments/exp166-whose-firmware-will-it-accept/) |

**P-256 with a wipe is a complete answer for a real product**, and it is built
and verified here. It is not nothing, and the road's string of negative results
should not be read as one.

Things that are **not** mitigations, measured rather than assumed:

- **OTP.** Every row is readable by ordinary firmware ([exp154](../experiments/exp154-somewhere-to-put-a-key/)).
- **Compiling the key in.** `XIP_MAIN` is fully open ([exp159](../experiments/exp159-a-key-that-was-never-in-flash/)).
- **More `ACCESSCTRL` registers.** They interleave; there is no wider wall to build ([exp162](../experiments/exp162-how-wide-can-a-wall-be/)).
- **Sweeping your own memory afterwards to check.** That measures your sweep, not your exposure ([exp163](../experiments/exp163-how-long-is-a-secret-in-the-open/)).

---

## What is still open

**The SAU has never been made to refuse anything.**

[exp165](../experiments/exp165-who-gets-the-last-word/) wrote the first SAU
region this repository has ever written and found that SAU regions are
**32-byte aligned and any length** — exactly the property `ACCESSCTRL` lacks. A
single region covering a 65,696-byte working set is legal in the encoding.

That is not a hole in the answer above, for three reasons, and they should be
read together:

1. **exp165 never probed the main 512 KB**, because that is where its own stack
   and statics live. Whether an SAU region is honoured there is unmeasured.
2. **Two of exp165's four probes were overruled in silence** — the bootrom and
   `SIO_NS` — so something above the SAU has the last word in at least some of
   the address space, and nobody here has named it.
3. **An SAU region refuses only Non-secure code**, and putting a core into
   genuine Non-secure state needs a Non-secure-Callable region, a hand-written
   `SG` veneer, banked stack pointers and a second vector table. `ACCESSCTRL`
   refuses a demoted core with none of that.

> **The SAU is not a cheaper wall. It is a wider wall behind a much larger
> door, and nobody has opened the door.**

That work has its own road now — see
[the attribution road](../experiments/README.md#the-attribution-road) — because
it is a different subject at a different difficulty, and because it is not on
the way to anything the signing road needs.

Also unmeasured, and worth naming so nobody assumes either way:

- **the debugger.** `ACCESSCTRL` has a `DBG` bit and no experiment has touched
  it. Every "Non-secure code cannot read this" result here is about a CPU.
- **DMA.** The bit is locked out by the bootrom, which exp160 measured, and
  nothing has tried to work around that.
- **`ACCESSCTRL.LOCK`.** Deliberately never written, so every configuration here
  is one power cycle from ordinary — and none of it survives a reset by itself.
- **power and timing side channels.** Nothing here is a claim about those, and
  a 3.9× variation in ML-DSA signing time across five board measurements is a
  reminder that rejection sampling is visible from outside.

---

## The mistake worth carrying

The road these eight experiments belong to is named **"whose firmware will it
accept"**. Every one of them is about keeping a *private* key.

Those are different problems, and the difference is not subtle once it is
written down:

> **Signing needs a secret. Verifying needs only integrity.**

A verifier holds a **public** key. It does not care that `ACCESSCTRL` gates four
bytes, that ML-DSA's working set is 65,696 bytes, or that the demoted core was
never Non-secure. Every obstacle in this document is real and **none of it
applies to the question the road was named after.**

That went unnoticed for eight experiments —
[exp166](../experiments/exp166-whose-firmware-will-it-accept/) is the one that
asked the road's own question, and it needed no wall at all. Its own ceiling is
a different problem entirely: the public key is 65 bytes of ordinary flash, and
anybody who can write flash can change which firmware the board accepts.

**Both halves are worth having. Only one of them was hard, and it was not the
one anybody spent eight experiments on.**
