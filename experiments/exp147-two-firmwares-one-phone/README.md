# exp147-two-firmwares-one-phone — the whole A/B arc, read off an LED

> **Verified on hardware, 2026-08-05, on a phone — and it found something it was
> not built to find.** A Pixel 9a installed the pair, the ROM booted the higher
> version (slot B, slow blink), `ab.html` read both halves over PICOBOOT and
> named the winner, and its **switch** rewrote four bytes of the other half's
> version word: the LED went fast and stayed fast across a replug. The whole A/B
> arc, run from a phone, read off an LED.
>
> The other button turned out to be doing something else entirely: **a flash
> update boot of an image with no `TBYB` flag is not a trial but a completed
> update, and the ROM erased the half it replaced.** That is
> [the finding](#the-finding-this-was-not-built-to-make), and it was not in the
> plan.

Every other experiment on this road produces its evidence as text — a log line,
a return code, a hex word. That is right for finding things out and wrong for
*showing* somebody what was found. This one is arranged so the whole A/B story
can be run and read by a person holding a phone, with nothing installed, and the
readout is the rate an LED blinks at.

| Which half is running | LED |
| --- | --- |
| Slot A | **fast** — 100 ms on, 100 ms off |
| Slot B | **slow** — 1000 ms on, 1000 ms off |

Needs: any RP2350 board with a plain LED, a Chromium browser (a phone's is the
point), and the exp102 toolchain only to build the pair in the first place.

## The finding this was not built to make

This experiment was built as a demonstration of things already measured. It
produced a new result instead, and the result contradicts what the page
originally said.

`ab.html` had a button labelled **try the other half once**, described as
writing nothing: send `reboot(FLASH_UPDATE, other_half)`, the other half runs,
the next reset puts it back. That is what
[exp143](../exp143-the-image-that-is-never-bought/) had seen — but exp143's
image carried the **TBYB flag**, and exp147's do not.

On a phone, 2026-08-05, with a board holding A = v1.0 (fast) and B = v2.0
(slow):

1. The ROM booted B. Slow blink, and the page read `A v1.0 / B v2.0`.
2. **Boot the other half** → the LED went fast. Slot A was running.
3. Unplug, plug back in → **still fast**. It had not gone back.
4. Read both halves again:

```text
A at 0x10001000: v1.0
B at 0x10011000: erased — nothing installed here
  4096 bytes read, starting ff ff ff ff ff ff ff ff
```

**Slot B's first sector was erased.** Not by the page — the page sent one
reboot command and nothing else. By the ROM.

That is `explicit_buy`'s documented behaviour arriving where nobody called it:
buying an image *erases the first sector of the other partition when the new
image is a version downgrade*. An image with no TBYB flag has nothing to buy,
so a flash update boot of it is not a trial at all — it is a **completed
update**, bought the moment it starts. Slot A was v1.0 against B's v2.0, which
made it a downgrade, and the ROM cleaned up the half it had replaced.

**So the trial in try-before-you-buy is the flag's doing, not the flash update
boot's.** exp143 could have been read as "a flash update boot runs an image
once"; it does not. It runs an image once *if that image is marked provisional*,
and otherwise it commits it and tidies up. The bit exp143 spent an experiment on
is the whole mechanism, and this is what its absence looks like.

## The two answers to "run the other one"

| | Boot the other half | **Switch** to it |
| --- | --- | --- |
| What it sends | `reboot(FLASH_UPDATE, other_half)` | rewrites four bytes, then `reboot(NORMAL)` |
| Flash written by the page | none | one sector of the other half |
| Flash written **by the ROM** | the other half's first sector, **erased**, on a downgrade | none |
| Survives a reset | yes — there is nothing to go back to | yes — the ROM boots it every time |
| Reversible | only by reinstalling the pair | yes, switch back |
| Where it comes from | [exp143](../exp143-the-image-that-is-never-bought/), **minus the flag that made it a trial** | [exp142](../exp142-two-images-one-version/), the only rule the ROM uses |

A person can see the difference without being told it, and it is not the
difference this page was built to show: press **boot the other half**, and one
of the two firmwares is gone. Press **switch**, and both are still there.

## Four bytes

The switch is not a command, because the ROM has no such command. It compares
the `VERSION` item in each half's `IMAGE_DEF` and boots the higher one, and that
is the entire mechanism. So to switch, the page makes the other half's version
higher:

```text
read one sector at the other half's start   (PICOBOOT READ)
find the block loop, walk to the VERSION item
set it above the winner's
erase that sector, write it back            (FLASH_ERASE, WRITE)
read it back and check                      (PICOBOOT READ)
reboot                                      (REBOOT2 NORMAL)
```

Read-modify-write, because a flash sector is the smallest thing that can be
erased: the four bytes cannot be changed without rewriting everything around
them.

**This was checked before the page existed.** The assembled pair was patched by
hand — one byte, `0x01` → `0x03` in slot A's version word, at a known offset in
the `.uf2` — and flashed. The board booted the other half. If a version word had
been covered by a checksum somewhere, or if the ROM cached anything, that would
have failed there instead of in somebody's hand.

## What the firmware learned from exp143

After a switch, the number compiled into a firmware and the number in its own
`IMAGE_DEF` are different — and the ROM's is the one that decided anything. So
this firmware reads its own version out of flash rather than reporting the
constant it was built with:

```rust
fn version_in_flash() -> u32 {
    let p = core::ptr::addr_of!(IMAGE_DEF) as *const u32;
    unsafe { core::ptr::read_volatile(p.add(3)) }
}
```

The first version of this firmware did not, and said `version 1.0` on a board
whose flash said `3.0`. That is exactly the mistake
[exp143](../exp143-the-image-that-is-never-bought/) made with the TBYB bit and
wrote a rule about — trusting a build flag about a byte somebody else has since
changed. It came back within an hour of the rule being written, in a different
experiment, about a different byte.

## What this experiment does not do

**It does not install the pair.** [`tools/pages/pflash.html`](../../tools/pages/pflash.html)
does, it is the maintained tool for it, and a second flashing implementation
living in a demo page is two things that can drift apart. `ab.html` does only
the things `pflash.html` cannot: read the two halves, and switch between them.

**It was not built to prove anything new.** exp139, exp142, exp143, exp144 and
exp146 are where the findings are; this was meant to be the integration test
that runs all of them at once. It found something anyway, which is an argument
for building demonstrations: assembling five results into one sequence put a
claim under load that reading them separately never did.

## The code IS the walkthrough

- [`ab.html`](./ab.html) — reads both halves, and the two switch buttons.
- [`src/main.rs`](./src/main.rs) — exp142's image with the blink rate as a build
  input, and its version read from flash.
- [`build.rs`](./build.rs) — slot, version, blink period.
- [`../../tools/partimg`](../../tools/partimg/) — `ab` mode, unchanged since
  exp142.

## Two ways to do it

```sh
./check.sh    # verdict: the pair builds and differs in the one word the ROM
              # compares, the page's sector constants match partimg's, its
              # opcodes match yi26's, and its parser is run against the real
              # assembled image's bytes. No board, no browser
```

On the machine with the board — and a phone is the interesting one:

1. Build the pair and assemble it (`check.sh` leaves `target/exp147-ab.uf2`).
2. **Together, without pausing between them:** `flash.html` to put the board in
   BOOTSEL, then `pflash.html` to install `exp147-ab.uf2`. **The board now has a
   partition table**, so from here its BOOTSEL drive will take nothing (exp144)
   — `pflash.html` is how you reflash it, and `recover.html` erases the table if
   you want the drive back.
3. Look at the LED. Slow blink means slot B, which means the ROM compared two
   versions and chose.
4. **Together again:** `flash.html`, then `ab.html` → **Read both halves** →
   **Switch to it permanently**.
5. Look at the LED: fast now. Unplug and plug back in: still fast.

The pairing in steps 2 and 4 is not tidiness — see
[the phone hazard](#a-phone-hazard-the-sequence-has-to-be-built-around). A board
left waiting in BOOTSEL while somebody reads the next step may not be in BOOTSEL
by the time they get there.

## Expected output

Captured **2026-08-05** on the Ubuntu board — the half that did not need a
browser.

**As installed**, A is v1.0 and B is v2.0, so the ROM boots B:

```text
exp147 up. slot B, slow blink.
I am slot B, blinking slow — 1000 ms on, 1000 ms off.
  my VERSION in flash = v2.0
pick_ab_parition(0) -> 1 (the half the ROM prefers, which is me)
idle: slot B, slow blink, v2.0 in flash, partition 1
```

`yi26 port` agrees without a log at all: `exp147 slot B slow`.

**After one byte of slot A's version word was changed** — `0x00010000` becomes
`0x00030000`, and `cmp -l` reports exactly one differing byte in the whole
92,416-byte image:

```text
exp147 up. slot A, fast blink.
I am slot A, blinking fast — 100 ms on, 100 ms off.
  my VERSION in flash = v3.0
  (built as v1.0 — somebody rewrote those four bytes)
pick_ab_parition(0) -> 0 (the half the ROM prefers, which is me)
idle: slot A, fast blink, v3.0 in flash, partition 0
```

And `check.sh`, on the page's own parser against the real assembled image:

```text
PASS  the page targets the sectors partimg actually uses (1 and 17)
PASS  'try once' uses reboot type FLASH_UPDATE (0x4), which writes nothing
PASS  reads slot A's version out of the real flash bytes (v1.0 at +288)
PASS  reads slot B's version out of the real flash bytes (v2.0 at +288)
```

### The phone

Captured on a **Pixel 9a, 2026-08-05**, with `ab.html` opened out of the Files
app. Reading both halves:

```text
picked: RP2350 Boot — 2e8a:000f
claimed PICOBOOT (interface 1, OUT ep 3, IN ep 4)
A at 0x10001000: v1.0
  4096 bytes read, starting 00 00 08 20 45 01 00 10
B at 0x10011000: v2.0
  4096 bytes read, starting 00 00 08 20 45 01 00 10
```

`The ROM boots slot B.` — and the LED was blinking slowly, which is the same
sentence without a screen.

Then **switch**:

```text
slot A: v1.0 -> v3.0 (four bytes at +288)
```

The LED went **fast**, and stayed fast across an unplug and replug. Four bytes,
from a phone, and the ROM boots the other half from then on.

### The failures, which were worth more than the successes

Three of them, none caught by `check.sh` while it printed seventeen PASS lines:

1. **The page read 256 bytes** and looked for a block loop that starts at
   `+0x114`. It reported "no IMAGE_DEF version found" on a correctly installed
   board. `check.sh` passed because its fixture was a whole sector while the
   code read 256 bytes — *a test whose input is bigger than the code's input is
   not testing the code.*
2. **The read-back inside the switch was still 256 bytes** after the first fix.
   The write succeeded and the verification reported failure — the one direction
   a verification must never fail in, because it sends somebody to reinstall a
   half that was fine, and it withholds the reboot that would have shown the
   switch working. The check added for (1) only knew about the call site it had
   been written for; it now fails on any read with a literal length.
3. **The failure message blamed the wrong thing.** "Install the pair with
   pflash.html first", said to somebody who had just installed it, would have
   sent them round a loop.

### A phone hazard the sequence has to be built around

**A board does not sit in BOOTSEL safely on a phone.** If the screen sleeps and
the port is power-cycled, the board resets — and a reset boots a firmware, it
does not return to the bootloader. Nothing announces it; the next page simply
finds the chooser full of ghosts.

This was raised by the person running the experiment, and it fits every failure
here that was not a bug in the page. It is not measured in this repository, so
it is written down as a hazard to design around rather than as a result:

- **Do `flash.html` immediately before the action that needs BOOTSEL**, not
  several steps earlier and not while reading instructions.
- **Treat "the chooser has only dead entries" as a question about state**, not
  about the device — the page says so now.
- **Keep the LED in view.** It answers "what state is this board in" faster than
  any page can, and it is the one instrument a sleeping phone does not
  interrupt. That is a second reason for the readout this experiment was built
  around, and it was not the reason it was chosen.

## Make it yours

1. Give both halves the **same** version and press switch. Work out what the
   page should do, then find out what the ROM does with a tie.
2. Press **try once** and then **switch** without resetting in between. The page
   reads the versions from flash, not from what is running — does it still act
   on the right half?
3. Make the two halves differ by something other than a blink rate — a GPIO, a
   USB product string, anything a person can check without a toolchain. The
   readout is the design here, not an afterthought.
4. Switch back and forth a few times and watch the version numbers climb. Work
   out what happens when the major version runs out of room, and what a real
   product would do instead.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `ab.html` says "neither half has a versioned image" | The pair is not installed, or the board has some other firmware | Install `exp147-ab.uf2` with `pflash.html` |
| The LED rate does not change after **try once** | The ROM may not honour a flash update boot from PICOBOOT for a plain image — that is the thing this experiment finds out | Report it; it is a result. **Switch** does not depend on it |
| The switch says "the rewrite did not verify" | The erase or write did not take | Nothing was rebooted; the half you are on still boots. Reinstall the pair with `pflash.html` |
| The board takes nothing dragged onto its drive | It has a partition table now — exp144 | Use `pflash.html`, or `recover.html` to erase the table |
| Both halves show the same version | The pair was assembled from two builds with the same `EXP147_MAJOR` | Rebuild with different versions; `check.sh` builds 1 and 2 |

## Next

This is the last experiment on the A/B road, and it is deliberately not a
finding. Everything it demonstrates was measured somewhere else, which is what
makes it usable as a check: if a future change to `partimg`, the ROM calls, or
the pages breaks any of it, this is the one place where a person notices
without reading anything.
