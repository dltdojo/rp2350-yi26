# exp157-a-note-for-the-next-boot — a firmware that says where it died

[exp156](../exp156-a-wall-you-can-measure/) took **seven flash cycles**, each one
somebody's walk to a bench, and two of them produced a fact about the subject.
Two went on making the experiment run at all. Two went on making the LED able to
say *where* it died rather than *that* it died. One was lost to a report that
said "it kept blinking", when slow and fast mean different things.

[`docs/the-board-is-the-loop.md`](../../docs/the-board-is-the-loop.md) does that
arithmetic and asks for a different instrument. This is the first half of it.

## The claim

> **A firmware killed in a way that takes USB and the log with it comes back and
> says which step it died in — and which kind of death it was.**

Two kinds, because they are the two that happen and they had been
indistinguishable from each other and from silence:

- a **hang** — exp156's very first round, `spawn_core1` waiting forever on a core
  that could not answer. No exception fires. The board simply stops, and *dark*
  is also what a firmware that never started looks like.
- a **fault** — exp156's later rounds.

## It has to be able to fail, or it has proved nothing

A harness that always answers "step 3" cannot be caught being wrong, and
[exp140](../exp140-a-checksum-that-passes/) is this repository's name for that.
So the firmware kills itself **at different steps, in different ways**, and the
report has to name each correctly:

| boot | what it does | what the next boot must say |
| --- | --- | --- |
| 1 | runs all eight steps | completed — **the control** |
| 2 | **hangs** at step 3 | `HANG in step 3` |
| 3 | **faults** at step 6 | `FAULT in step 6` |
| 4 | runs all eight steps | completed — **recovery is not damage** |
| 5 | stops, and reports for as long as it is powered | |

The two controls are not decoration. Without a boot that finished, *"it says
where it died"* cannot be told from *"it always says something died"*, and a
harness that can only report failure cannot report success.

## How it works

`WATCHDOG.SCRATCH0`–`SCRATCH3` are four words that **survive a watchdog reset** —
the documented mechanism the bootrom itself uses for `reset_usb_boot()`. Sixteen
bytes, written before each step and never after, so the number that survives
names the step that did not come back.

```text
  SCRATCH0   a one-shot handoff token
  SCRATCH1   which boot this is
  SCRATCH2   the step being attempted RIGHT NOW
  SCRATCH3   one byte per boot: how that boot ended
```

`SCRATCH4`–`SCRATCH7` are **the bootrom's**, so nothing here touches them.

The reusable half is [`crates/breadcrumb`](../../crates/breadcrumb/), so the next
experiment gets it by adding a dependency rather than by copying this one.

### Why the token is one-shot

The first design trusted a note whenever `WATCHDOG.REASON` said a watchdog
caused the boot, reasoning that a power-on or a flash leaves it at zero.
**That was measured wrong inside one run.** The 1200-baud reflash touch reboots
*through the watchdog*, so `REASON` says "watchdog" on precisely the boot that
must inherit nothing — the first boot of a newly flashed firmware. It reported a
previous build's history as its own and skipped its entire scenario.

So `arm()` and `reboot()` write the token and `read()` consumes it. A note exists
only if the boot before it was inside a sequence that had deliberately armed, and
a firmware that stops cleanly leaves nothing for the next one to misread.

## The safety property, and it is not optional

**A board in a reboot loop it cannot be talked out of is worse than the slow loop
this replaces.** The 1200-baud reflash touch needs the device to stay enumerated
long enough to hear it. Three things guarantee it, and all three are guarded:

1. **`breadcrumb::read()` disarms first, unconditionally.** A boot can never
   inherit an armed watchdog. "Stop calling `arm`" is not the same as "the
   watchdog is off", and the difference cost a board.
2. **Every boot spends six seconds enumerated with nothing armed** before it
   risks anything, and says so in the log.
3. **The storm stops after five boots** and disarms.

Verified after the run: the board is still `running`, still enumerated, and still
enters BOOTSEL from `yi26 bootsel` with nobody near the button.

## Two boards were recovered by hand getting here

Both by the same mistake, and neither was the watchdog.

**The product string was one character too long.** `embassy-usb` builds string
descriptors *into the control buffer* and asserts once per UTF-16 unit:

```text
    assert!(pos + 2 < buf.len(), "control buffer too small");
```

`"exp157 a note for the next boot"` is 31 characters. The last one needs
`64 < 64`, which is false — so it panicked inside the USB stack, mid-enumeration,
with `panic_halt` as the handler. The executor stopped. The board handed over its
device and configuration descriptors and then froze: `urbnum` stuck,
`bConfigurationValue` empty, no log, no LED, no reboot. It looked exactly like a
firmware that had bricked itself, and it had.

Note `<` and not `<=`: with a 64-byte buffer the limit is **30 characters**, not
31. It is a `const` assertion now, so it is a build failure rather than a bench
trip, and the guard was checked by putting the long name back and watching the
build refuse:

```console
error[E0080]: evaluation panicked: product string will overflow embassy-usb's
              control buffer and panic mid-enumeration
```

A sweep of the other 38 experiments that set a product string found **none**
overflowing — and one sitting at exactly 30 characters, one from the cliff.

### And the diagnosis was wrong twice before it was right

Worth writing down, because the errors are more instructive than the fix:

- **A symptom was explained that had never been observed.** An elaborate theory
  about `PSM.WDSEL` was built to explain what happened "after boot 5" — on a
  firmware that had never printed a single line. Both builds had died before
  boot 1.
- **A measurement was overridden by a deduction.** A spike had already armed the
  watchdog with `embassy-rp`'s reset mask and been reset by it five times, coming
  back healthy every time. Reading the register layout afterwards suggested that
  mask should not work on RP2350 at all, so it was changed — unmeasured, in the
  same breath as a real fix, which is how an unmeasured change gets believed. It
  was never the problem. The measured value is back, and **which mask is correct
  for RP2350 is recorded as an open question** in
  [`crates/breadcrumb`](../../crates/breadcrumb/src/lib.rs).
- **exp156's own rule was broken.** *Bring the LED up before anything that can
  hang.* This experiment blinked only after the storm, so "never started" and
  "died during enumeration" were one signal — and that is where the two bench
  trips went. The heartbeat now starts before `Driver::new`, and `check.sh`
  fails if it moves.

## What this found on the way

**`embassy_rp::init()` takes every peripheral out of reset.** `clocks::init()`
ends with `reset::unreset_wait(ALL_PERIPHERALS)`, so there is no such thing as
reading a peripheral in reset from inside an embassy firmware. The first fault
generator here tried exactly that — because exp156 records dying that way — and
**it did not fault**: boot 3 completed all eight steps where a fault was
scripted, and the run said so.

Two consequences. This experiment faults with `udf` instead, which needs no
peripheral and no assumption. And exp156's `bring_i2c1_out_of_reset()` is a
no-op that its `check.sh` guards — its measurements all stand, but **what killed
its second round is no longer established.**

## How to see it

```sh
./check.sh                      # exit 0, and it names every entry it asserted
yi26 log --json --seconds 25    # the settled report, repeating every ten seconds
```

The storm takes about **fifty seconds**, and the port disappears five times while
it runs, so `yi26 log` returns fragments or `Broken pipe` until it settles.
`check.sh` polls for the settled state rather than guessing at a delay — the
first version read once and reported four failures on a board that was working
perfectly.

The LED is the fallback: **slow** while the storm runs, **fast** once it has
stopped.

## Expected output

Pasted from a real run on a Pico 2, Ubuntu, 2026-08-20 — flashed with
`yi26 pflash`, then read across its own reboots. The port drops between boots;
the fragments are joined here and nothing else is edited.

```console
[    3037 ms] exp157 up. What the previous boot left behind:
[    3037 ms] boot #1 — nothing before it. Fresh flash or power-on.
[    3037 ms] reflash window: 6 s with nothing armed. `yi26 bootsel` works now.
[    9037 ms] this boot: running 8 steps, budget 2000 ms each.
[    9037 ms]   step 1
...
[    9877 ms]   step 8
[    9997 ms] all 8 steps done. Going round again to run the next case.

[    3074 ms] boot #2, and the boot before it completed.
[    3074 ms]   boot 1: completed all 8 steps
[    9074 ms]   step 1
[    9194 ms]   step 2
[    9314 ms]   step 3
[    9314 ms]   hanging on purpose. Nothing feeds the watchdog from here.

[    3074 ms] boot #3, and the boot before it HANG.
[    3074 ms]   boot 1: completed all 8 steps
[    3074 ms]   boot 2: HANG in step 3
[    9674 ms]   step 6
[    9674 ms]   faulting on purpose: an undefined instruction.

[    3074 ms] boot #4, and the boot before it FAULT.
[    3074 ms]   boot 1: completed all 8 steps
[    3074 ms]   boot 2: HANG in step 3
[    3074 ms]   boot 3: FAULT in step 6
[   10034 ms] all 8 steps done. Going round again to run the next case.

[   43074 ms] boot #5, and the boot before it completed.
[   43074 ms]   boot 1: completed all 8 steps
[   43074 ms]   boot 2: HANG in step 3
[   43074 ms]   boot 3: FAULT in step 6
[   43074 ms]   boot 4: completed all 8 steps
[   43075 ms] STOP after 5 boots. Nothing armed; still reflashable.
[   43075 ms] VERDICT: two deaths, two kinds, two steps, named above.
```

`./check.sh` on the same board:

```console
PASS  toolchain present (cargo, elf2flash)
PASS  firmware compiles (214392 byte ELF)
PASS  converts to UF2 (46592 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  the product string is bounded at build time
PASS  the LED heartbeat starts before the USB stack
PASS  the storm has a hard stop that disarms
PASS  board enumerated as 1209:0001
PASS  control: boot 1 completed
PASS  control: boot 4 completed after two deaths
PASS  a hang was reported, with its step (2: HANG in step 3)
PASS  a fault was reported, with its step (3: FAULT in step 6)
PASS  the storm stopped and said so
```

## What is not verified here

- **Anything before USB is up.** The breadcrumb is reported *over USB*, so a
  death during enumeration still leaves only the LED — which is exactly what the
  two bench trips above were. This is an honest limit of the mechanism, not an
  oversight: **the LED is still the last instrument, and it still has to be
  designed before it is needed.**
- **That skipping the step that killed you works.** This experiment reports where
  it died; it does not yet *route around* it. That is the second half of
  [the-board-is-the-loop](../../docs/the-board-is-the-loop.md) and the thing that
  would collapse exp156's rounds five, six and seven into one.
- **Which `PSM.WDSEL` mask is right for RP2350.** The measured one is in use. The
  reasoning that says it should not work is recorded next to it.
- **A build flashed over a firmware that died mid-sequence inherits one boot.**
  The token is only cleared by a boot that runs; if the previous firmware was
  killed with the token set, the first boot of the new one consumes it and counts
  itself as a continuation. Observed once. Flashing twice clears it, and a clean
  stop never leaves it set.
- **Anything on a phone.** Nothing here has been near one.

## The ideas to take away

1. **A dead run can still file a report.** The constraint everybody designs
   around — *when firmware dies, everything it knew dies with it* — is a property
   of how the firmware was written, not of the chip. Sixteen bytes that survive a
   reset turn "died" into "died at step six, by fault".

2. **A watchdog catches what a fault handler cannot.** A hang raises no
   exception. It is the failure that looks most like a board that never started,
   and it is the one exp156 lost its first round to.

3. **The instrument is what needs a control.** Both boots that *completed* exist
   so that the boots that died mean something. It is the same shape as exp156's
   middle read, and it was almost left out for the same reason: the interesting
   half is the one that fails.

## Next

The second half: **the board skips what killed it and tries the next candidate**,
so one flash answers a hypothesis matrix instead of one hypothesis. Then the
signing road's third experiment, with an instrument that can survive it.
