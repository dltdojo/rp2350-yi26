# exp132-one-owner-or-two — two programs watching one draw

[exp131](../exp131-the-volume-is-the-app-drawer/) put the draw page and the log
page on the same volume and then could not open both:

```text
Error: cannot claim the interfaces — something else owns them, and an
interface has exactly one owner. [NetworkError: Failed to execute
'claimInterface' on 'USBDevice': Unable to claim interface.]
```

That is not a fault to fix. **An interface has exactly one owner** is the rule
the whole browser track is built on, and exp122 spent an experiment
establishing it. What exp131 got wrong was assuming two pages could be two
witnesses while sharing one interface.

This experiment builds both answers and measures the difference.

Needs: any RP2350 board and the exp102 toolchain. The two-channel build needs
the udev rule for raw USB access, as [exp122](../exp122-vendor-bulk/) does.
`check.sh` needs no browser and nobody in the room; the two-tab finding below
needs both.

## Two builds, one source

```sh
cargo build --release                          # one channel
cargo build --release --features two-channels  # two
```

| | One channel | Two channels |
| --- | --- | --- |
| Interfaces | CDC | CDC **+ a vendor interface** |
| Commands travel on | the CDC OUT endpoint | the vendor OUT endpoint |
| The log travels on | the CDC IN endpoint | the CDC IN endpoint |
| Who can hold what | one program holds both | `cdc_acm` holds one, anything holds the other |
| Two witnesses at once | **no** | **yes** |
| Cost | — | one interface, two endpoints, and everything exp121 says that moves |

The command handling, the rejection sampling and the health gate are written
once and shared. The only structural difference is in `main`, left visible
rather than hidden behind a helper so both shapes can be read at once.

## What the second channel actually buys

This is the measurement, and it is what a browser could not have shown here:

```text
$ yi26 echo '2100-2567'
sent     9 bytes: 2100-2567
received 41 bytes: draw #1: 2365  in 2100-2567 (468 values)

$ yi26 log            # running throughout, in another process
[   16065 ms] draw #1: 2365  in 2100-2567 (468 values)
```

`yi26 echo` claims the vendor interface with libusb. The kernel's `cdc_acm`
holds the CDC pair and never let go. **The same sentence reached two programs
at the same time**, which is exactly what exp131's two pages could not do.

The audit argument exp130 makes — that the number is a claim, checkable
against the device's own words — needs two witnesses to be worth anything.
Here they exist.

## What it buys on a phone, which is the opposite of what this said first

This section claimed, for one day, that the second channel does not help a
phone: Android offers no way to arrange two pages side by side, so "two pages,
one each" looked like something a person could not do.

**Side by side was never the requirement.** Simultaneous *claiming* does not
need simultaneous *visibility* — you switch tabs. That was pointed out rather
than noticed, after the coupling it caused had already been paid for.

Measured on a Pixel 9a, 2026-08-03, with exp116's log page in one tab and
[`draw-vendor.html`](./draw-vendor.html) in another:

```text
[   65037 ms] idle: no draws yet — try  yi26 echo 2100-2567
[   69194 ms] draw #1: 2217  in 2100-2567 (468 values)
[   70037 ms] idle: 1 draw, 0 refused, 2560 bits tested
[   71678 ms] draw #2: 2300  in 2100-2567 (468 values)
[   72426 ms] draw #3: 2295  in 2100-2567 (468 values)
[   75037 ms] idle: 3 draws, 0 refused, 3584 bits tested
```

The draws were sent from the other tab. The log tab was **in the background
for all three** and recorded every one — and the idle lines either side of them
are five seconds apart with nothing missing, `24 lines, 1469 bytes, 49.3 s`,
no `(+N lines lost)` anywhere.

So a backgrounded Chrome tab on Android keeps its WebUSB claim **and keeps
draining the endpoint**. Two channels work on a phone.

### And a page can claim a vendor interface

Nothing in this repository had tried. exp122 reached class `0xFF` with libusb
and its portability note said "No browser" — not because a browser could not,
but because nobody had asked one to. It can, with no BOS or MS-OS descriptors:
those buy Chrome's auto-connect notification, not the ability to claim.

`draw-vendor.html` sends the range and reads the reply on the vendor endpoints,
with no `SET_LINE_CODING` and no DTR — that interface has no class to have
opinions about baud rates, which is what 0xFF means.

### What that costs the design that came before it

[exp130](../exp130-the-board-draws/)'s page has a log pane and a JSON export
written into it, because the log could not be a separate page. On one channel
that is still true. On two it is not, and the difference is composability: a
log viewer that drops onto any firmware is one file, and a log pane welded into
an appliance page is seven scattered edits that the next appliance must repeat.

This experiment does not undo that. It establishes what the choice actually is:

| | One channel | Two channels |
| --- | --- | --- |
| The log is | inside every appliance page | one independent file |
| A new appliance costs | its own job **plus** a log pane | its own job |
| Descriptor surface | unchanged | one interface, two endpoints |
| Two tabs on a phone | the second one fails to claim | both work, background included |

**It costs descriptor surface.** exp121 measured what adding an interface does
to every number in the tree, and earlier private work on this ground rejected a
vendor interface for exactly this reason — more surface to re-test against a
strict host, for marginal gain. That reasoning does not transfer here (there is
no strict host, and the gain is not marginal), but the cost does.

## The rule that produced all of this

One interface, one owner. It is worth listing where that has now bitten, since
each time it looked like a different problem:

| Where | What it looked like | What it was |
| --- | --- | --- |
| exp116 | the page cannot claim on Linux | `cdc_acm` had it — `yi26 detach` |
| exp122 | a vendor interface with no device node | nothing claims 0xFF, so anyone can |
| exp131 | the log page will not open | the draw page still had it |
| here | — | two interfaces, so two owners — and two tabs, on a phone, both reading |

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — one `handle()` shared by both builds, and
  the `#[cfg]` in `main` that is the entire structural difference.

## Two ways to do it

```sh
./run.sh      # guided: both builds, and the two-witness capture
./check.sh    # verdict: builds both, then proves the simultaneity on hardware
```

## Expected output

Captured from a Pico 2 running the two-channel build:

```text
[      37 ms] exp132 up, two channels. Commands on the vendor interface.
[      99 ms] warmed up: 2048 bits through the health tests
[    5037 ms] idle: no draws yet — try  yi26 echo 2100-2567
```

Then a command on one interface while the log is being read on the other:

```text
sent     9 bytes: 2100-2567
received 41 bytes: draw #1: 2365  in 2100-2567 (468 values)

[   16065 ms] draw #1: 2365  in 2100-2567 (468 values)
```

`./check.sh` against that board:

```text
PASS  toolchain present (cargo, elf2flash)
PASS  the draw crate's tests pass
PASS  the one-channel build compiles and converts (50176 bytes)
PASS  the two-channel build compiles and converts (51712 bytes)
PASS  exp132-one-channel.uf2 has family ID e48bff59
PASS  exp132-two-channels.uf2 has family ID e48bff59
PASS  the vendor interface is built by hand, behind the feature
PASS  both shapes live in one source, chosen by a feature
PASS  board is running exp132
PASS  the vendor interface answered the command it was sent
PASS  the drawn number 2386 is inside 2100-2567
PASS  the log carried the same draw, on the other interface, at the same time
PASS  cdc_acm kept the log interface while libusb held the vendor one
```

The last two are the experiment. The log capture being non-empty is checked
separately from it containing the draw, because a libusb claim that displaced
`cdc_acm` would produce an empty capture rather than an incomplete one, and
those are different failures.

## What is not verified here

**The same test on a desktop.** Two tabs of Chrome on Android is now measured;
two windows of Chrome on Linux is not, and the kernel's `cdc_acm` has to be
detached there first, which is a different starting position.

**The one-channel build on hardware.** It compiles and converts on every
`check.sh` run; flashing it is `run.sh`'s job. Its behaviour is exp129's, which
is verified there — which is why this is recorded rather than queued. Whoever
next walks through this experiment flashes both builds in turn, and that run is
where the one-channel half stops being an inference.

## Make it yours

1. Flash the one-channel build and try `yi26 echo`. There is no vendor
   interface to echo into, and the error says so — which is the difference in
   its plainest form.
2. Send a range to the CDC port on the two-channel build. It is refused with a
   line naming the right channel, rather than ignored.
3. Run `yi26 log` in two terminals at once against either build. The second
   fails, and it is the same rule one layer down.
4. Take the log pane back out of exp130's page and try to watch a draw from
   `LOG.HTM` on exp131's volume. The failure is what started this experiment,
   and it is worth seeing once before trusting the fix.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `yi26 echo` finds no interface | The one-channel build is flashed, or the udev rule is missing | `yi26 udev --install`, or flash the two-channel build |
| The log is empty while echo works | Something else holds the CDC port | `yi26 attach`, and close other readers |
| Commands sent to the serial port do nothing | Two-channel build — they go to the vendor interface | The log says so; use `yi26 echo` |

## Next

[exp133](../exp133-a-page-per-job/) spends what this measured: the same
app-drawer volume on a two-channel firmware, with the log back as an
independent file and an appliance page that carries no log code at all.

Beyond that, nothing on this road. What is left is under [Planned](../README.md#planned).
