# exp190 — the board that brings itself back

[exp157](../exp157-a-note-for-the-next-boot/) proved that a firmware killed in a
way that takes USB and the log with it **comes back and says which step it died
in**. This is the next thing that asks for: not a board that explains its death,
but a board that **survives it without a person**.

> **Verified on hardware, 2026-08-29.** Four weights, and nobody touched the
> board for any of them. A fault before USB and a hang with interrupts off each
> put the board **in its own bootloader in one second**, presenting the drive a
> host reflashes from. A fault *after* the board was up did **not** — it came
> back by itself and stayed up. See [Expected output](#expected-output).

## The claim

> **A firmware that dies on the way up brings itself back, and when it cannot,
> it hands itself to the ROM bootloader rather than to somebody at a bench.**

## Why, counted

One round of work on the [authenticator road](../README.md#the-authenticator-road)
cost **four trips to a bench**, and every one was the same shape: firmware died,
and with it went USB, the log, and the 1200-baud watcher that lets a host reboot
the board. What was left had to be unplugged, held down and plugged back in by a
person standing there.

| what died | why nobody could reach it |
|---|---|
| a `StaticCell` claimed twice, panicking on the second CBOR command | `panic-halt` halts in silence; the executor stopped and took CDC, HID and the reboot watcher with it |
| an HID interface declared with no task servicing it | the whole device left the USB bus |
| `SecretKey::from_slice` on thirty-two zero bytes, before USB was serving | the board never appeared at all |

**None of those is exotic.** All three are ordinary bugs, and the reason each one
cost a walk is that nothing was watching.

## It has to be able to fail, or it has proved nothing

[exp140](../exp140-a-checksum-that-passes/) is this repository's name for a
harness that cannot be caught being wrong, and **a safety net nobody has dropped
a weight on is exactly that**. So `EXP190_DIE` is a build input and the run drops
four:

| arm | what it does | what must happen |
|---|---|---|
| `never` | gets up and stays up | the control, and nothing below means anything without it |
| `late` | dies **after** saying it is reachable | comes back by itself, and is **not** handed over |
| `early` | dies **before** it is reachable, by a fault | handed to the bootloader after three tries |
| `hang` | stops without dying, interrupts off | the same — this is the case no fault handler catches |

**`late` is the one that can fail in the expensive direction.** A board that got
up is a board a host can still reboot at 1200 baud, so handing it over there
would turn an ordinary crash into a device that runs nothing. An experiment that
only dropped `early` could not tell a working net from one that catches
everything.

## What the escape actually is

`embassy_rp::rom_data::reset_to_usb_boot(0, 0)` — the same call
[`crates/usb-reboot`](../../crates/usb-reboot/) uses for the 1200-baud touch.
**A firmware can put itself into BOOTSEL.** Nothing here is a new mechanism; what
was missing was the policy, and that nothing made it standard.

The policy is [`crates/lifeline`](../../crates/lifeline/), and it is four lines:
count boots that died before saying they were reachable, and at three, hand over
instead of failing again. The count lives in two spare bits of a watchdog
scratch register, so it survives the resets it is counting.

## Three things it cost to get right, all of them found on a board

- **The flag that said "I got up" could be overwritten.** `alive` recorded it in
  `breadcrumb`'s step field, and an experiment marking its own steps — the
  ordinary way to use that crate — erased it. So an ordinary reflash read as a
  death, and three flashes would have dropped a working board into its
  bootloader. `finished` is sticky now: **a boot that got up cannot un-get-up.**
- **The history could not see far enough.** `breadcrumb`'s four history slots are
  indexed by *absolute boot number*, so from the fifth boot onwards nothing is
  written and the oldest four are reported for ever. That is right for exp157,
  which demonstrates a short deliberate sequence, and useless for a board that
  has been powered on for a week — the escape could never have fired on one.
  Rather than change what exp157 verified, the counter is its own two bits.
- **The escape was not one-shot.** With the count left at the threshold, the
  *fixed* firmware flashed next was bounced into the bootloader before it ran: a
  board permanently in BOOTSEL, which is a different way of needing a person.

## The LED, because a person at the board has nothing else

Up before the USB stack, which is [exp156](../exp156-a-wall-you-can-measure/)'s
hardest-won rule — seven flash cycles, of which two produced a fact about the
subject and two went on making the LED able to say *where* rather than *that*.
exp157 records paying it a second time: two of its builds froze inside the USB
stack with the LED dark, and *never started* and *died during enumeration* are
the same signal.

- **one short flash a second** — up
- **N quick flashes then a pause** — this is retry number N after a death, and N
  reaching three is the last boot before the board hands itself over

`check.sh` reads the order out of the source and fails if the LED is ever
spawned after `Driver::new`.

## What this experiment is not

The mechanism belongs to `crates/lifeline` and is used by other firmwares;
[exp183](../exp183-the-contract-and-the-lock/) runs on it today. **This
experiment is the weight**, and the reason it exists is that until it ran, the
net had never been dropped on.

Nor is it a claim that a board can always be saved. A firmware that corrupts the
watchdog registers, or one flashed with an image the bootrom will not start, is
still a walk to a bench. What is measured here is the common case, which is
three ordinary bugs out of three.

## Running it

Needs 1 — a board attached, and nothing but software after that.

```console
./drop.sh      # four arms, four weights, nobody touching anything
./check.sh
```

`drop.sh` restores the `never` arm at the end, so the board is left running
rather than in a bootloader.

## Expected output

`./drop.sh`:

```text
>>> arm 1/4: never — the control. It gets up and stays up.
-- never --
[      37 ms] boot 2, last ended: Completed at step 0 — 0 death(s) in a row before it was up
[      37 ms]   EXP190_DIE=never, escape after 3 boots that never got up
state after 10 s: running

>>> arm 2/4: late — dies AFTER saying it is reachable.
-- late --
[      74 ms] boot 21, last ended: Completed at step 0 — 0 death(s) in a row before it was up
[    6074 ms] dying on purpose, AFTER saying I was up — this must not hand the board over
-- late, after it came back --
[      74 ms] boot 23, last ended: Fault at step 16 — 0 death(s) in a row before it was up
state after 30 s: running

>>> arm 3/4: early — dies BEFORE it is reachable, by a fault.
>>>          nobody touches the board from here.
-- early --
reached bootsel after: 1 s
drive present: yes

>>> arm 4/4: hang — stops without dying, interrupts off.
-- hang --
reached bootsel after: 1 s
drive present: yes

>>> putting the control back
-- restored --
[      37 ms] boot 1, last ended: Fresh at step 0 — 0 death(s) in a row before it was up
final state: running
```

And `verify.py` ruling on it:

```text
PASS  the control came up and said which boot it was
PASS  and it reports no deaths behind it
PASS  it was still running ten seconds later
PASS  the `late` arm reached its own death, so the weight was really dropped
PASS  and it came back by itself — boot 21 died, boot 23 is answering
PASS  and the boot after it counts no deaths, because the one that died had got up first
PASS  **and it was NOT handed to the bootloader** — a board that got up is one a host can still reboot
PASS  `early` (a fault before USB) put itself in the bootloader after 1 s, with nobody touching it
PASS  and the early board presents its drive, so a host can reflash it
PASS  `hang` (a hang no fault handler catches) put itself in the bootloader after 1 s, with nobody touching it
PASS  and the hang board presents its drive, so a host can reflash it
PASS  a working firmware flashed afterwards runs — the escape is one-shot, not a state
PASS  and the board is left running, not in a bootloader
```

**One second**, for both of the arms that cannot come back on their own. The
three deaths and the handover are all watchdog resets, and a watchdog reset is
fast.

## Two things the capture had to be rebuilt to see

Both were the instrument rather than the subject, and
[exp174](../exp174-a-deadline-nobody-mentioned/) wrote the rule they broke:
*the measurement must not be slower or blinder than the thing it measures.*

- **`yi26 log` cannot survive the board re-enumerating.** The CDC endpoint goes
  away with the reboot and takes the session with it, so the boot that comes back
  is invisible to the session that watched the one that died. It is read by
  connecting again — which is also how a person would find out.
- **The `late` arm died every six seconds for ever**, which made the board a
  moving target that the next arm could not be flashed onto. It dies once now,
  on a boot whose predecessor did not, and staying up afterwards is the more
  honest demonstration anyway: recovery is the claim, and a board that dies for
  ever never shows it recovering.

## Next

Everything on the [authenticator road](../README.md#the-authenticator-road) and
after it can build on `crates/lifeline` for the price of two lines, and the
firmwares that have already paid for its absence are the first candidates.
