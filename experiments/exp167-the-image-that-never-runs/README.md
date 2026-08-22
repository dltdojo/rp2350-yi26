# exp167 — the image that never runs

[exp143](../exp143-the-image-that-is-never-bought/) built a rollback out of an
image **not asking to stay**. This builds a refusal out of an image **never
being started**, and the pair is the point: two independent failures, two
independent mechanisms, and neither one detects anything.

> **Verified on hardware, 2026-08-22.** Slot A holds a public key and no
> private one. Three requests are refused — one signed by another key, one
> naming an address the chip will not answer, one cut short — and slot B does
> not run. The fourth is signed correctly, slot A performs a flash update boot,
> slot B comes up provisional on a **16,775,256 µs** trial clock, never buys,
> and the ROM takes the board back to slot A. See
> [Expected output](#expected-output).

And on the way it found the thing that decides the design, which nobody in this
repository had asked: **a running image cannot read the other slot.**

## "Verify, then buy" is the wrong shape

The obvious reading of this experiment is that the new image checks its own
signature before calling `explicit_buy`.

> **But whoever supplies the image also supplies that check.** An image that
> does not verify itself simply calls `explicit_buy` and stays.

A candidate cannot be trusted to check its own signature. The check has to
happen in the image that is **already running**, before it performs the flash
update boot — the attacker supplies B, and does not supply A.

That reshapes the experiment into two independent gates:

| what is wrong | what stops it | what the reader sees |
|---|---|---|
| the signer is not the one slot A trusts | slot A's signature check | **slot B never runs** |
| the signer is right and the image is broken | the ROM's TBYB bit | slot B runs, never buys, and the board comes back |

Neither gate detects a failure. The first refuses before anything starts; the
second, in exp143's words, treats *"an image that crashes, hangs, or simply
never gets round to buying"* exactly alike. **That is why they compose.**

## The thing that decides the design

Slot A has to hash slot B to check a signature over it. `partimg` puts slot B at
flash offset `0x11000`, and [exp143](../exp143-the-image-that-is-never-bought/)
passes exactly that address to `reboot(FLASH_UPDATE, …)`, so it looked settled.

**exp143 passes that address to the ROM. It never reads it.** Nothing in this
repository ever had.

The first build of this firmware read it, and the board stopped:

- USB stayed enumerated and `/dev/ttyACM0` stayed present;
- fifteen seconds of an open port with DTR asserted produced **zero bytes**;
- closing the port hung, because that is a control transfer;
- `yi26 bootsel` reported *"the board did not reach BOOTSEL mode"* — the
  1200-baud touch is `SET_LINE_CODING`, and nothing was answering control
  requests.

A hand on the BOOTSEL button was the only way back.

### What was actually happening, read rather than guessed

The RP2350's QMI translates every XIP address through one of **eight
apertures**, each with a base and a size in 4 KiB units. `rp-pac` quotes the
datasheet on what lies past one:

> Offsets greater than SIZE return a bus error, and do not cause a QSPI access.

A bus error is a HardFault; `panic-halt` stops the core; a stopped core answers
no control requests. Every symptom above, in one sentence from a register
description.

So the apertures are printed on every boot instead of walked into:

```
  ATRANS0: base=0x1 size=0x10 -> phys 0x001000..0x011000, 64 KiB
  ATRANS1: base=0x11 size=0x0 -> phys 0x011000..0x011000, 0 KiB
  ATRANS2: base=0x11 size=0x0 -> phys 0x011000..0x011000, 0 KiB
  ATRANS3: base=0x11 size=0x0 -> phys 0x011000..0x011000, 0 KiB
  ATRANS4: base=0x0 size=0x400 -> phys 0x000000..0x400000, 4096 KiB
  ATRANS5: base=0x400 size=0x400 -> phys 0x400000..0x800000, 4096 KiB
  ATRANS6: base=0x800 size=0x400 -> phys 0x800000..0xc00000, 4096 KiB
  ATRANS7: base=0xc00 size=0x400 -> phys 0xc00000..0x1000000, 4096 KiB
```

> **The ROM gives a running image a 64 KiB window onto its own partition, and
> closes the ones that would reach the other slot.** `ATRANS0` is slot A —
> sixteen sectors from sector 1. `ATRANS1`, `ATRANS2` and `ATRANS3` are sized to
> **zero**: every access through them is a bus error, and slot B is behind them.

That the aperture really is the partition is checked twice, by the board:

- virtual `0x0000` hashes to what the host computes for **physical `0x1000`**,
  which is `base = 1` exactly;
- virtual `0xf000` — the last sector the aperture reaches — hashes to
  `f47a8ec3…`, which is the SHA-256 of 4096 `0xff` bytes. Slot A's image ends
  before there, so the aperture is showing **erased flash**, which is what a
  real flash read looks like and what an unbacked one does not.

### `ATRANS4`–`ATRANS7` are a second chip select, and this board has one flash

Four apertures of 4 MiB tile 16 MiB, which is one chip select's worth. Reads
through them do **not** fault and do **not** return flash:

| address | one boot | the next |
|---|---|---|
| `0x11011000` | `b8e41507…` | `59d14954…` |

**Same address, different boot, different bytes.** A flash read is identical
every time. This is a bus with nothing on the end of it, which is exactly what
`ATRANS4`–`ATRANS7` describe on a board with a single flash chip.

The board reports that read as a `READ` rather than pretending otherwise,
because it *is* a completed read — and the transcript then says what it is worth.

### The guard, which is what the wedge bought

`addressable()` computes which aperture would answer an address, **reads that
aperture's `SIZE` from the chip**, and does the arithmetic — before anything is
dereferenced. A range that would fault is refused in words, by a board that is
still talking:

```
  one sector past aperture 0 0x0010000 REFUSED: the region leaves the window this image reads
  slot B, where it lives     0x0011000 REFUSED: the region leaves the window this image reads
```

`check.sh` fails if a raw slice ever appears above that check, and fails if the
guard is given a hard-coded limit instead of reading the register.

## What this costs the road

**Slot A cannot verify slot B where it lies.** The design this experiment set
out to build does not work on this part, and the reason is a deliberate choice
by the ROM rather than an oversight anywhere.

Three ways out, and only the first is measured here:

1. **Verify something the aperture reaches.** That is what the four requests
   below do, and it proves the gate end to end — the cryptography, the framing,
   the trial, the rollback — over bytes of slot A.
2. **Reprogram `ATRANS1` to point at slot B.** The registers are writable. It is
   also editing the address space the editing code is executing out of.
3. **Verify before the image is in flash**, which is the update path a field
   device actually has: the host sends the image, slot A checks it in RAM, and
   only then writes it. That is the next experiment, and it is the first one
   here that would write flash.

## The four requests

`sign.py` builds each one; every mode can come out the other way.

| mode | what it changes | which layer must refuse it |
|---|---|---|
| `wrong-key` | signed by a second test key | **cryptography** |
| `unreadable` | names slot B where it really lives | **plumbing** — and without reading it |
| `truncated` | the frame cut to 53 bytes | **plumbing** |
| `good` | nothing | none: it starts the trial |

`unreadable` is the one worth arguing about, and it is the guard's exam: a
verifier that read first and checked afterwards would pass every other test in
this directory and take the board down on this one.

The region is chosen from a seed taken at run time, so the bytes signed are ones
nobody picked when the firmware was built —
[exp159](../exp159-a-key-that-was-never-in-flash/)'s bar for a signer, pointed
at a verifier, as in [exp166](../exp166-whose-firmware-will-it-accept/).

## The digest is what makes the verdict checkable

Slot A prints the SHA-256 of the region it read **before** its verdict and
whether or not the answer is yes; the host prints its own over the same named
bytes; `verify.py` requires them equal. A verifier that reports only pass or
fail can be trusted and cannot be checked.

The one case with no digest is `unreadable`, and that absence is itself
checked: a digest there would mean the board dereferenced an address it had not
proved was backed.

## The ceiling, unchanged from exp166

**The trusted key is 65 bytes of ordinary flash inside slot A, and anybody who
can write flash can replace slot A.** The signature governs the **update path**,
not the bench. Closing that needs a fuse this road does not burn, and
[exp166](../exp166-whose-firmware-will-it-accept/) demonstrates the point by
finding the key inside its own `.uf2` with a byte search.

## What it cost to find out

Six flashes and **one hand on the BOOTSEL button** — the first this road has
needed since exp156.

- **The wedge**, above. Its whole value is the guard it turned into, and the
  bisection that found it: the read went behind a build flag defaulting off,
  one flash proved everything else worked, and the next one asked the dangerous
  question with the LED counting stages in case the log went quiet again.
- **`usb-log` dropped lines three times**, at 25 ms and at 60 ms of pacing.
  `report_boot` emitted six lines with no pacing at all, filling the sixteen-deep
  queue before the interesting ones arrived. Every `log!` in slot A is now paced
  at 80 ms. This is the fourth experiment on this road to pay for that queue.
- **`verify.py` crashed instead of failing** on a transcript with a missing
  verdict — a check that stops checking the moment it finds something wrong. It
  now reports and continues.

## What is not verified here

- **Slot A never verifies slot B.** See [above](#what-this-costs-the-road). The
  gate is proved over bytes slot A can reach.
- **The aperture-selection rule is not derived.** The register values are read
  and checked against the probes; the rule that maps a virtual offset to an
  aperture needs the RP2350 datasheet, which this repository does not have.
  `verify.py` prints it as `OPEN`, as exp164 and exp165 do for the Armv8-M
  manual.
- **`ATRANS4`–`ATRANS7` are interpreted, not proved.** Two boots giving
  different bytes at one address rules out flash; naming what *is* there is a
  reading of the datasheet nobody here has done.
- **One board, one partition layout.** `ATRANS0`'s 16 sectors are `partimg`'s
  choice; a different table gives a different window and the same lesson.
- **Nothing is installed.** Slot B is already in flash, put there by the same
  `pflash` that put slot A there. This experiment decides whether it **runs**.
- **The private keys here are test keys, published below**, and are never on a
  board.

## The test keys

Both are published on purpose, both are worthless, and neither is on the board.
They are exp166's, deliberately: the same key, the same frame, the same host
shape, so a reader who has seen one has seen both.

```
trusted (slot A carries the public half)
  private  a7c08e6335cc688ced091da7f381971aee587d3783f9924233d85e488a034fe0
"somebody else" (used only by the wrong-key request)
  private  a03a8c8cd7659136f840ea68ae7005c25c5a84d3a236efd557ecf4eb6086f174
```

## Running it

```console
cd experiments/exp167-the-image-that-never-runs
./check.sh          # builds both slots, assembles, flashes, drives a whole round
```

One round by hand, printing both voices:

```console
./drive.sh 4242     # seed is optional; the clock is the default
```

To check a transcript you already have, on any machine, with nothing installed:

```console
python3 verify.py < capture.txt
```

`verify.py` re-derives the aperture decode from the raw `BASE`/`SIZE` fields,
requires every probe's outcome to follow from the aperture that would answer it,
requires the board's digest to equal the host's, requires each refusal to come
from the right layer, requires exactly one request to have started a trial and
that it be the one the host signed, and requires slot B to have run,
declined to buy, and been taken back.

## Expected output

Pasted from a real run on a Pico 2, Ubuntu, 2026-08-22. Trimmed; the full
transcript, both voices, is [`capture.txt`](./capture.txt).

```console
[    4161 ms]   aperture 0, first sector   0x0000000 READ  a0b4ff790604035f28866a69
[    4244 ms]   aperture 0, last sector    0x000f000 READ  f47a8ec3e9aff2318d896942
[    4324 ms]   one sector past aperture 0 0x0010000 REFUSED: the region leaves the window this ...
[    4404 ms]   slot B, where it lives     0x0011000 REFUSED: the region leaves the window this ...
[    4486 ms]   the same, via aperture 4   0x1011000 READ  f9105a633895eb3cf01fb76e
[    4566 ms]   slot B is at flash offset 0x11000, and nothing here can read it.
[    4807 ms] nobody signed is an image that never runs.

>>> host: mode=wrong-key expect=REFUSED trial=false ... sha256=1954ffcb...
[   12208 ms]   sha256 = 1954ffcb42137978fd27457f11e90cc23cf3dc3fc9708f6abb5ccb40bb6b92e9
[   12288 ms]   REFUSED (cryptography): the signature is not this key's, over these bytes
[   12368 ms]   no trial. Slot B will not run.

>>> host: mode=unreadable expect=REFUSED trial=false virtual=0x11000 ...
[   15235 ms]   REFUSED (plumbing): the region leaves the window this image reads
[   15315 ms]   no trial. Slot B will not run.

>>> host: mode=good expect=ACCEPTED trial=true ... sha256=1954ffcb...
[   21658 ms]   sha256 = 1954ffcb42137978fd27457f11e90cc23cf3dc3fc9708f6abb5ccb40bb6b92e9
[   21738 ms]   ACCEPTED: slot B is signed by the key this image trusts
[   21858 ms] reboot(FLASH_UPDATE, update_base=0x10011000) — see you on the other side

[      75 ms] exp167 up. slot B v2.0, provisional (TBYB).
[    3155 ms] IMAGE_TYPE in flash = 0x90210142 — TBYB set (provisional)
[    3155 ms] watchdog as the ROM left it: enable=true, time=16775256 us, load=0 us
[    9315 ms] not buying. Nothing is wrong with me — I simply never call it.

>>> host: and the board is back on: exp167 slot A
```

`./check.sh` on the same board:

```console
PASS  every address is checked against its aperture before it is dereferenced
PASS  there is exactly one raw slice in the firmware
PASS  the guard reads the aperture rather than trusting a constant
PASS  no timeout starts a trial: only a verified signature does
PASS  there is exactly one place that starts a trial
PASS  verify.py rejects a probe that read what its aperture forbids (got DISAGREE)
PASS  verify.py rejects a second request that started a trial (got DISAGREE)
PASS  a live round re-derives off the board, digests and apertures included
PASS  slot B's real address is refused in words, by a board still talking
PASS  a correctly signed request starts the trial
PASS  slot B ran, and only after a signature
PASS  slot B never bought, and the ROM took the board back
```

## Four things to take away

1. **A candidate cannot check its own signature.** The obvious design hands the
   decision to the code being decided about. Whatever verifies has to be the
   thing already running.
2. **Two gates that detect nothing compose better than one that detects
   something.** Wrong signer: never starts. Right signer, broken: starts, does
   not ask to stay, and the ROM undoes it. No health check, no boot counter, no
   bootloader anybody wrote.
3. **A running image does not get the whole flash.** It gets one aperture onto
   its own partition, and the apertures that would reach the other slot are
   sized to zero. Six experiments passed that address to the ROM without ever
   reading it, and the difference cost a hand on a button.
4. **A refusal you can read beats a fault you cannot.** The same address, before
   and after: a wedged chip that could only be recovered with the button, and a
   sentence printed by a board that is still answering. The register was
   readable the whole time.

## Next

**Verify before the image is in flash.** The aperture finding says slot A cannot
check slot B where it lies, and the honest response is the update path a field
device actually has: the host sends the image over CDC, slot A verifies it in
RAM against the same key, and **only then** writes it to slot B. That is the
first experiment on this road to write flash, and everything it needs is
measured — [exp146](../exp146-a-page-that-writes-flash/) wrote flash from a
phone over PICOBOOT, and this experiment's gate, framing and trial machinery
carry over unchanged.

Smaller, and cheap: **reprogram `ATRANS1`.** The registers are writable and
slot B is one `BASE`/`SIZE` pair away from being addressable. It is also editing
the address space the editing code runs out of, so it belongs with a firmware
that can say what it did before it does it.
