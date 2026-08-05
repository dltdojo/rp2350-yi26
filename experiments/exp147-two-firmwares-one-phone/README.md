# exp147-two-firmwares-one-phone — the whole A/B arc, read off an LED

> **Half verified on hardware, 2026-08-05.** The pair installs and the ROM boots
> the higher version: slot B (v2.0, slow blink) came up. Then **one byte** of
> slot A's VERSION word was changed — nothing else in the image — and the board
> booted slot A (fast blink) instead, reporting `v3.0 in flash (built as v1.0)`.
> That is the mechanism `ab.html`'s switch button uses, confirmed before anyone
> was asked to press it.
>
> **Not yet verified: the page itself.** Reading both halves over PICOBOOT,
> "try once", and "switch" have not been run from a browser on a board. That
> needs a person, a phone, and an LED, and this header says so until it has
> happened. See [Expected output](#expected-output).

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

## The two answers to "run the other one"

The arc found two, and they are not the same thing. `ab.html` puts them side by
side because the difference is the most useful thing on this page:

| | Try the other half **once** | **Switch** to it |
| --- | --- | --- |
| What it sends | `reboot(FLASH_UPDATE, other_half)` | rewrites four bytes, then `reboot(NORMAL)` |
| Flash written | **none at all** | one sector of the other half |
| Survives a reset | no — the LED goes back | yes — the ROM boots it every time |
| Where it comes from | [exp143](../exp143-the-image-that-is-never-bought/), the way into a try-before-you-buy image | [exp142](../exp142-two-images-one-version/), the only rule the ROM uses |
| If it goes wrong | nothing was written, so nothing can be wrong | the half being switched *to* is damaged; the half you are on still boots |

A person can see the difference without being told it: press **try once**, watch
the LED change, unplug and plug the board back in — and it has changed back.
Press **switch**, do the same, and it has not.

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

**It proves nothing new.** exp139, exp142, exp143, exp144 and exp146 are where
the findings are. This is the integration test that runs all of them at once,
and the honest name for it is a demonstration.

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
2. Put the board in BOOTSEL: `flash.html` from a phone, `yi26 bootsel` otherwise.
3. Install it with `pflash.html`. **The board now has a partition table**, so
   from here its BOOTSEL drive will take nothing (exp144) — `pflash.html` is how
   you reflash it, and `recover.html` erases the table if you want the drive
   back.
4. Look at the LED. Slow blink means slot B.
5. `flash.html` again, then `ab.html`: **Read both halves**, then either button.
6. Look at the LED again.

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

**The phone half goes here when it has happened**, and not before.

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
