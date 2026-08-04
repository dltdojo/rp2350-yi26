# exp143-the-image-that-is-never-bought — a rollback made of not asking to stay

> **Verified on hardware, 2026-08-05.** Slot B carries a firmware marked
> *try-before-you-buy* and a higher version than slot A. A plain reset boots
> **A** — an unbought provisional image is not a current image. A flash update
> boot starts B, on a clock the ROM armed at **16,775,289 µs**; B says it will
> not buy, and the board is taken back to A. Then the same B, rebuilt to call
> `explicit_buy`, cleared its own TBYB bit out of flash (`0x90210142` →
> `0x10210142`, return code `0`, 37 ms) and has been the firmware ever since.
> See [Expected output](#expected-output).

[exp142](../exp142-two-images-one-version/) let the ROM choose between two
images by version. That is half of what makes a field update survivable; this is
the other half. An update that can be *chosen* can still be a brick — the
question is what happens when the new image is chosen and **does not work**.

The usual answer is machinery: a health check, a boot counter, a watchdog you
write, a bootloader that decides. The RP2350 answers it with one bit and one
call, and the rollback is built out of an image **not asking to stay** — not out
of a broken image, and not out of a failure anybody has to detect.

Needs: any RP2350 board, and the exp102 toolchain. No browser. Nothing here
needs a person: the board drives both halves of the experiment itself.

## What try-before-you-buy actually is

One bit — `IMAGE_TYPE_TBYB`, `0x8000` — in an image's own `IMAGE_DEF`. Setting
it makes three things true at once, and the first one is the surprise:

1. **A plain reset will not boot that image**, however high its version. It is
   not the current image; it is a candidate.
2. **The only way in is a flash update boot** — `reboot(FLASH_UPDATE,
   update_base)`, reboot type `0x4`, with the address of the image to try.
3. **Once in, a clock is running.** The ROM arms the watchdog, and when it runs
   out the board resets and the ROM boots the other slot again.

The image stops being provisional by calling `explicit_buy`, which **rewrites
that bit out of the flash sector the image is running from**. Nothing else
clears it. So a rollback needs no failure detection: an image that crashes,
hangs, or simply never gets round to buying is treated exactly the same, and the
board comes back on the firmware that was already working.

## Who starts the trial

Something has to perform the flash update boot, and in the field that something
is the firmware that just wrote the new image. So that is what slot A does here:
it comes up, says what it is, and fifteen seconds later hands the board over.

```rust
rom_data::reboot(REBOOT_FLASH_UPDATE | REBOOT_NO_RETURN, 50, B_BASE_XIP, 0);
```

`update_base` is `0x10011000` — the XIP address of image B's partition, where
`partimg ab` puts it. Which of the two plausible readings `update_base` wants —
the XIP address or the raw flash offset `0x00011000` — was not something this
repository could cite, so [`src/main.rs`](./src/main.rs) tries the XIP address
first and logs what came back before trying the other. It never had to: the XIP
address works, and the call does not return.

The fifteen seconds are not decoration. They are the window in which
`yi26 bootsel` can catch a cycling board — and if that is not enough, sending
the board anything at all (`yi26 send hold`) stops it from starting another
trial.

## The clock, measured

A trial boot reads its own watchdog before anything else runs, and prints it:

```text
watchdog as the ROM left it: enable=true, time=16775289 us, load=0 us
```

That is 16,775,285 µs of the watchdog's 16,777,215 µs (`0xffffff`) maximum — the
ROM arms the trial clock at essentially the largest value the hardware has. Six
seconds later the same registers read:

```text
watchdog now: enable=true, time=7699304 us (9075985 us gone since boot)
```

Two samples that differ by exactly the elapsed time. One reading is a number;
two readings are a clock, and a clock is what makes this a trial. **About 16.8
seconds** is a generous window — USB enumeration costs about one — which is why
nothing in this experiment races the watchdog or feeds it. An ordinary boot of
the *same binary* reads `time=0`: the clock is the trial, not the boot.

**`WATCHDOG.REASON.TIMER` is not the evidence it looks like.** It is set after an
ordinary `yi26 pflash` too, because the ROM's own reboot goes through the
watchdog. It says "a watchdog reset started this boot" and never "a trial ran
out"; the two are not distinguishable from that bit, so the log says only what
the bit means.

## The buy

`explicit_buy` is a ROM call that writes flash — and the sector it rewrites is
the one the running code is executing from, which is why it wants 4 KiB of
4 KiB-aligned scratch RAM to hold that sector while it goes:

```rust
#[repr(C, align(4096))]
struct Scratch([u8; 4096]);
static mut BUY_SCRATCH: Scratch = Scratch([0; 4096]);

let rc = cortex_m::interrupt::free(|_| unsafe {
    rom_data::explicit_buy(core::ptr::addr_of_mut!(BUY_SCRATCH) as *mut u8, 4096)
});
```

Interrupts are off across the call: the flash is being erased under XIP, and an
interrupt handler fetched from that flash mid-erase is the classic way to lose a
board. If that goes wrong the image crashes — which is a trial that ends without
a buy, which is the safe side of this experiment. **The failure mode of getting
the buy wrong is the rollback.**

Two things were measured about the call and neither is guessable from the
header: it took **37 ms**, and it **disabled the trial clock itself**
(`enable=false` afterwards), so a bought image does not have to stop its own
watchdog to avoid being reset for winning.

## Reading the bit rather than trusting the flag

Both images know at build time whether they were *built* provisional. Neither
one trusts that, because after a buy the bytes in flash and the flag in the
source no longer agree:

```rust
fn image_type_in_flash() -> u32 {
    let p = core::ptr::addr_of!(IMAGE_DEF) as *const u32;
    unsafe { core::ptr::read_volatile(p.add(1)) }
}
```

The USB product string is built from *that*, so `yi26 port` alone tells you
which of the three states the board is in — `exp143 slot A`, `exp143 slot B
provisional`, `exp143 slot B bought` — with no log and no open port. This is the
instrument for the experiment, because a trial image is on the bus for sixteen
seconds and then the port vanishes under whatever was reading it.

## One source, three images

Same code, four build inputs, in [`build.rs`](./build.rs):

```sh
EXP143_SLOT=A EXP143_MAJOR=1                              cargo build --release
EXP143_SLOT=B EXP143_MAJOR=2 EXP143_TBYB=1 EXP143_BUY=0   cargo build --release
EXP143_SLOT=B EXP143_MAJOR=2 EXP143_TBYB=1 EXP143_BUY=1   cargo build --release
```

The two arms of the experiment are the same binary with the same bugs; only the
declaration changes. Nothing is broken in the arm that rolls back.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — the TBYB bit in the `IMAGE_DEF`, the watchdog
  read by hand, the flash update boot, and the buy.
- [`build.rs`](./build.rs) — slot, version, provisional, buys: four declarations.
- [`../../tools/partimg`](../../tools/partimg/) — `ab` mode, unchanged from
  exp142: the table at sector 0, A at sector 1, B at sector 17.

## Two ways to do it

```sh
./run.sh      # guided: build both arms, flash, and watch the board be taken
              # back from B twice — then the same B, buying itself
./check.sh    # verdict: the static half needs no board; the board half reads
              # whichever arm is running
```

## Expected output

Captured **2026-08-05**, over two flashes.

**Arm 1 — B never buys.** Which image is enumerated, sampled once a second (this
is what `run.sh` prints):

```text
  +0s  (gone)
  +1s  exp143 slot A
 +16s  (gone)
 +16s  exp143 slot B provisional
 +33s  (gone)
 +33s  exp143 slot A
 +48s  (gone)
 +48s  exp143 slot B provisional
 +65s  (gone)
 +65s  exp143 slot A
```

Slot A first, though B is v2.0 against A's v1.0 — the provisional image lost the
version comparison it would have won. Then fifteen seconds of A, sixteen of B,
and back, over and over: an image that is never bought is never kept.

Slot A's log:

```text
exp143 up. slot A v1.0, permanent.
I am slot A, version 1.0.
IMAGE_TYPE in flash = 0x10210142 — TBYB clear (permanent)
watchdog as the ROM left it: enable=true, time=0 us, load=0 us
get_partition_table_info(PT_INFO) -> 4
get_b_partition(0) -> 1 (1 = there is a B side to try)
trying the other slot in 12 s — send anything (yi26 send hold) to stop it
yi26: read failed: Broken pipe
```

Slot B's, during a trial:

```text
exp143 up. slot B v2.0, provisional (TBYB).
I am slot B, version 2.0.
IMAGE_TYPE in flash = 0x90210142 — TBYB set (provisional)
watchdog as the ROM left it: enable=true, time=16775289 us, load=0 us
this is a trial boot, and the clock above is the trial. Deciding in 6 s.
watchdog now: enable=true, time=7699304 us (9075985 us gone since boot)
not buying. Nothing is wrong with me — I simply never call it.
From here the ROM takes the board back to the other slot.
idle: slot B v2.0 — IMAGE_TYPE 0x90210142, TBYB set (unbought)
yi26: read failed: Broken pipe
```

Both captures end the same way, and the broken pipe is not an error: it is the
port going away mid-read. On A's log that is the handover — A rebooting the
board into the trial. On B's it is the clock running out. The two halves of the
cycle, each seen from the host side as its own reader being cut off.

**Arm 2 — the same B, buying itself.**

```text
IMAGE_TYPE in flash = 0x90210142 — TBYB set (provisional)
watchdog as the ROM left it: enable=true, time=16774615 us, load=0 us
this is a trial boot, and the clock above is the trial. Deciding in 6 s.
watchdog now: enable=true, time=7698575 us (9076040 us gone since boot)
calling explicit_buy — it rewrites the sector I am running from
explicit_buy -> 0
IMAGE_TYPE in flash is now 0x10210142 — TBYB CLEARED (bought)
watchdog after the buy: enable=false, time=7698496 us
bought. This slot is now the one a plain reset boots — and here is
the proof, in 10 s: a plain reset, and see who comes back.
```

Ten seconds later it resets itself, once, and comes back as itself:

```text
exp143 up. slot B v2.0, permanent.
IMAGE_TYPE in flash = 0x10210142 — TBYB clear (permanent)
nothing to buy: the TBYB bit is already clear, so this image was
bought in an earlier boot and the ROM started it the ordinary way.
A bought image is just an image.
idle: slot B v2.0 — IMAGE_TYPE 0x10210142, TBYB clear (bought)
```

`yi26 port` agrees: `exp143 slot B bought`. Same binary, same partition, same
version — one bit less, and the slot that could not survive a reset is now the
one every reset boots.

## Make it yours

1. Give the provisional image something to *fail* at: buy only if some check
   passes, and make the check fail. Nothing about the rollback changes, which is
   the point — the ROM never learns why.
2. Delete the `explicit_buy` call from the buying build and watch the arms
   become identical. The buy is one call; everything else in both images is the
   same code.
3. Take the sixteen seconds seriously: move the decision past the clock
   (`TRIAL_TALK` above 17 s) and watch the image be taken back mid-sentence.
4. Try `update_base = 0x00011000` (the raw flash offset) instead of the XIP
   address and read the return code the firmware logs. The experiment already
   prints it; only one of the two readings starts a trial.
5. Work out why a *downgrade* is the dangerous case for `explicit_buy` — the ROM
   documents that it may erase the first sector of the other partition when the
   image being bought is older than its neighbour.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| The board never leaves slot A | The flash update boot failed | The log prints the return code and then tries the other `update_base`; check B's partition really starts at `0x10011000` |
| The board never leaves slot B, unbought | No trial clock was armed | The firmware says so and resets itself; check the `TBYB` bit is really in B's `IMAGE_DEF` (`objdump -s -j .start_block`, expect `42012190`) |
| `yi26 bootsel` cannot catch a cycling board | It only answers while a slot is up | Slot A is up ~15 s per cycle; retry, or `yi26 send hold` while A is up |
| `yi26 log` ends in `Broken pipe` | The trial ended under the reader | Expected in arm 1. `check.sh` tolerates it |
| `explicit_buy` returns non-zero | The scratch buffer is too small or misaligned | It needs 4 KiB, aligned to 4 KiB — see `Scratch` in `src/main.rs` |
| The board is dark after a forced experiment | An image the ROM will not start | BOOTSEL press, then `yi26 nuke` and reflash — exp139's lesson |

## Next

Under [the update road](../README.md#the-update-road): the drag-and-drop that
lands in the right slot — one file dropped, and the correct half written, with
no `for_slotA` / `for_slotB` in the filename. The ROM has a call for that too
(`get_uf2_target_partition`), and this experiment's pair is what it would be
writing into.
