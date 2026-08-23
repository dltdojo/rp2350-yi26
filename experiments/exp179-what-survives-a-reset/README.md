# exp179 — what survives a reset

The [identity road](../README.md#the-identity-road) opens with a question the
rest of it waits on: **does anything in this chip's SRAM survive to be read by
user code?** If a region does, an SRAM PUF is at least possible here. If nothing
does, the road has a clean negative to point at instead of folklore.

The first rung, and it answers the other way round from the direction the road
was written in.

> **Verified on hardware, 2026-08-23.** After a power cycle — the cable out and
> back in, no reflash — three 4 KB windows of SRAM read **50.5%, 51.2% and
> 51.0% one-bits**, and **not one of 130 blocks across the whole 520 KB is
> zero**. The RP2350 **does not clear SRAM on power-on**. What does clear it is
> the **flashing path**: on the boot straight after `yi26 flash`, 127 of those
> 130 blocks are entirely zero.

## The record this corrects, and how

Earlier work on this chip read a 4 KB window at `0x2007_C000` and found
**exactly zero one-bits out of 32,768** — `0.00%` uniformity. That measurement
is not in doubt; this experiment reproduces it exactly, at the same address, on
the boot after a flash. What was drawn from it was that the RP2350 clears SRAM
before user code runs and therefore has no SRAM PUF, and this repository wrote
that down as background for the whole road.

**The measurement was of a board that had just been flashed.** Pull the cable
instead, and the same address reads 51.2%. The clearing belongs to the path that
puts firmware on the chip, not to the chip's power-on.

That is not a small correction and it is not a criticism of the earlier work:
the reading was right, the conditions were not recorded as part of it, and a
measurement whose conditions are not part of the claim is one somebody will
generalise. Which is what happened, here, in this repository's own prose.

## Three windows, because they are cleared by different things

| window | where | who could plausibly clear it |
| --- | --- | --- |
| `.uninit` | `0x2001_2a8` in this build — wherever the linker puts it, after `.bss` | the bootrom only. `cortex-m-rt` does not touch `.uninit`, and it is far below the stack |
| `0x2007_C000` | the last 16 KB of the 512 KB main SRAM | the bootrom, **or our own stack**, which starts at the top of RAM and grows down through it. Read only, never written |
| `0x2008_0000` | SRAM bank 8, **outside** the 512 KB the linker knows about | the bootrom only. Nothing this firmware links can land here — [exp159](../exp159-a-key-that-was-never-in-flash/) put a key here for that reason |

Three windows and not one, because the earlier reading could not tell three
causes apart and the same all-zero answer is consistent with all of them.

And then a **map**: every 4 KB block of the 512 KB, plus the two scratch banks,
tested for being entirely zero. That is what turned a point into a boundary —
`0x2007_C000` looked special until the map showed the zeroed region was
`0x20001000..0x2007f000`, which is *everything*, and that the last block was
non-zero only because the stack is in it.

## What each kind of reset does

| | power gone? | `.uninit` | `0x2007_C000` | bank 8 | zero blocks |
| --- | --- | --- | --- | --- | --- |
| straight after `yi26 flash` | no | zero | zero | zero | **127 of 130** |
| after a watchdog reset | no | **the marker** | zero | **the marker** | 124 of 130 |
| **after the cable came out** | **yes** | **50.5%** | **51.2%** | **51.0%** | **0 of 130** |

Read the three rows together, because no one of them is the finding:

- **A reset that keeps the power clears nothing.** The marker written before
  `breadcrumb::reboot()` is still there afterwards, in `.uninit` and in bank 8
  alike.
- **`0x2007_C000` stays zero across those warm boots** — not because anything
  cleared it a second time, but because nothing ever writes there. That is the
  trap the map removed.
- **Power really did go.** The marker is *gone* on the cold boot. A cold
  transcript that still showed `deadbeef` would be one where the cable came out
  and the rail did not, and `verify.py` fails on exactly that.

The marker is `DE AD BE EF`, which is **75% one-bits**. Deliberately not
something like `0xA5`: at 50% it would have been indistinguishable at a glance
from the healthy SRAM startup distribution this experiment was looking for, and
a marker that can be mistaken for the result is not a marker.

## `#[pre_init]` was the first design, and it does not compile here

The plan was to read before `cortex-m-rt` initialises RAM at all. That position
is taken: **`embassy-rp` defines `__pre_init` itself**, and for a reason worth
knowing — SIO is not reset by `scb::sys_reset()`, so a boot interrupted while
holding spinlock 31, the one the critical-section implementation uses, comes
back to a lock nobody will release. `pre_init` is the only place guaranteed to
run before user code could have taken a critical section, so that is where
embassy resets SIO. A second `__pre_init` is a duplicate symbol at link time,
and the error names the symbol rather than the reason.

It did not matter, because the probe is in `.uninit` — the section `cortex-m-rt`
is documented not to initialise — so "our own runtime zeroed it" is ruled out by
where the window lives rather than by when it is read. The survey runs as the
first thing `main` does, before `embassy_rp::init`, and the source lists exactly
what has run by then.

## What this does not establish

- **It is not a PUF yet.** One cold boot says the cells are not cleared and that
  the distribution is plausible. A PUF needs the *same* pattern to come back:
  that is intra-device stability across many power cycles, and this is one.
- **Nothing here says the pattern is unique to this board.** That needs boards,
  and this repository has two that are [never on the same bench](../../docs/debugging-on-a-phone.md).
- **A PUF also needs error correction**, and how much is a property of the noise,
  not of the idea. Nothing here measures noise.
- **One board, one cold boot, one temperature**, which nothing here recorded.
- **The 45–55% band is the earlier work's own criterion**, adopted here so the
  two are comparable. It is a sanity band, not a proof of entropy: a fixed
  pattern with half its bits set would pass it.

What this rung *is* is the gate the rest of the road was waiting on, and it is
open. [what survives a reset] has an answer, and it is: **on this chip, after
power, everything does.**

## Running it

```console
cargo build --release
elf2flash convert -b rp2350 target/thumbv8m.main-none-eabihf/release/exp179-what-survives-a-reset target/exp179.uf2
yi26 flash target/exp179.uf2
yi26 log --seconds 4        # repeat: the firmware resets itself twice
```

The firmware takes three boots on its own and then idles. To run the half that
needs a person: **pull the USB cable out, wait a couple of seconds, put it back**
— no BOOTSEL, no reflash — and read the log again. Boot #1 after that is the
measurement.

```console
./check.sh                                       # everything, from the checked-in record
python3 verify.py --cold capture-cold-boot.txt   # just the half that needed a hand
```

## Expected output

```text
PASS  python3 present
PASS  toolchain present (cargo, elf2flash)
PASS  firmware compiles (212820 byte ELF)
PASS  it reads the earlier work's exact window, so the numbers are comparable
PASS  and bank 8, which is outside everything the linker placed
PASS  and a probe in .uninit, the section cortex-m-rt does not initialise
PASS  0x2007c000 is read and never written — it is the running stack's own region
PASS  the marker is 75% one-bits, so it cannot be misread as healthy SRAM noise
PASS  it maps all of SRAM in 4 KB blocks, not only the three named windows
PASS  the source says what happened to the pre_init design
PASS  capture-after-flash.txt is checked in
PASS  capture-cold-boot.txt is checked in
PASS  capture-after-flash.txt carries at least two boots (found 5)
PASS  the first boot in it is boot #1
PASS  boot #1 reports all three windows
PASS  .uninit (ours): zero one-bits on the boot straight after flashing
PASS  0x2007c000 (the earlier window): zero one-bits on the boot straight after flashing
PASS  0x20080000 (bank 8): zero one-bits on the boot straight after flashing
PASS  127 of 130 4 KB blocks are entirely zero — the flashing path clears SRAM wholesale, which is the reading the earlier work took
PASS  after a watchdog reset the marker is still in .uninit and in bank 8 — so a reset that keeps the power clears nothing
PASS  and 0x2007c000 stays zero, because nothing writes there — not because anything clears it a second time
PASS  capture-cold-boot.txt carries at least two boots (found 3)
PASS  the first boot in it is boot #1
PASS  boot #1 reports all three windows
PASS  .uninit (ours): 50.5% one-bits, inside the 45–55% band the earlier work's own criteria call healthy
PASS  .uninit (ours) is neither zeroed nor our marker — which is what a real power cycle has to look like
PASS  0x2007c000 (the earlier window): 51.2% one-bits, inside the 45–55% band the earlier work's own criteria call healthy
PASS  0x2007c000 (the earlier window) is neither zeroed nor our marker — which is what a real power cycle has to look like
PASS  0x20080000 (bank 8): 51.0% one-bits, inside the 45–55% band the earlier work's own criteria call healthy
PASS  0x20080000 (bank 8) is neither zeroed nor our marker — which is what a real power cycle has to look like
PASS  not one of the 130 4 KB blocks is entirely zero after power returned
PASS  and the warm boots after it do show the marker — the control that says the firmware can see one when it is there
PASS  a board is running exp179 — yi26 log reads it, and pulling the cable re-runs the cold half
PASS  the README says which road this opens
PASS  the README carries both numbers — the one measured here and the one it explains
```

The two transcripts it rules on are checked in beside it:
[`capture-after-flash.txt`](./capture-after-flash.txt) and
[`capture-cold-boot.txt`](./capture-cold-boot.txt). The second is the one that
needed a hand.
