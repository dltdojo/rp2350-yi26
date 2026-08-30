# exp193 — how many doors fit

**The wall is not where the bytes run out. It is at four interfaces, it is a
Cargo feature default nothing in this repository has ever set, and opening a
serial console spends half of it.**

[exp190](../exp190-the-board-that-brings-itself-back/) moved the CDC-ACM
bring-up into [`crates/cdc-console`](../../crates/cdc-console/) and ran it on
hardware — but only in the shape 45 experiments here use: a serial port and
nothing else. The other 29 put something on the same port, and for those the
crate had no path at all. It called `builder.build()` itself.

This experiment is the first caller of the composite path, and it exists to
walk into a number rather than to show a device working.

## What was measured

Every step flashed, enumerated, and read **from the host** — `wTotalLength` and
`bNumInterfaces` out of `/sys/bus/usb/devices/*/descriptors`, because a firmware
that dropped an interface would report the number it meant to build.

| lane | shape | interfaces | descriptor bytes | |
| --- | --- | --- | --- | --- |
| narrow | hid 0 | 2 | 70 | the console alone |
| narrow | hid 1 | 3 | 103 | what 20 experiments here build |
| narrow | hid 2 | 4 | 136 | |
| narrow | **hid 3** | — | — | **did not enumerate** |
| wide | hid 3 | 5 | 169 | |
| wide | hid 4 | 6 | 202 | |
| wide | hid 5 | 7 | 235 | |
| wide | **hid 6** | — | — | **did not enumerate** |

Each interface costs exactly **33 descriptor bytes**, in both lanes.

## The finding

The experiment was built to test this:

> Components extracted into crates compose on one board, and the wall they run
> into is the configuration descriptor.

**The second half is wrong.** The narrow lane stopped at five interfaces with
**136 of 256 descriptor bytes spent** — 120 still free.

`embassy-usb` keeps its interface list in a `heapless::Vec` whose capacity is
the compile-time `MAX_INTERFACE_COUNT`, **defaulting to 4**. The fifth push
asserts inside `Builder::interface`, before anything reaches the bus.

This repository already knew — in eight places, and nowhere a crate could see.
exp148–exp155 and exp161 set `max-interface-count-8` in their own `Cargo.toml`,
each with a comment explaining why. That is the network and browser line, which
needs CDC-ACM's two plus CDC-NCM's two plus a drive.

The other **32 composite experiments do not raise it**, and none of them says
so. They fit under four because CDC-ACM's two plus one more interface is under
the ceiling, and two of them land on it exactly:

| shape | experiments | interfaces |
| --- | --- | --- |
| `cdc+hid` | 20 | 3 |
| `cdc+msc` | 8 | 3 |
| `cdc+hid+vendor`, `cdc+msc+vendor` | 2 | 4 |
| `hid+hid+ccid+vendor` — exp177 | 1 | 4 |

**`cdc_console::open` spends two of the four before its caller adds anything**,
and putting that somewhere a caller will find it is what this experiment is
for. A `Cargo.toml` comment in one experiment cannot carry it any more: the
console is a crate, and its budget is spent inside the crate.

There is a fourth bill for copying sitting in the middle of this, already paid
and already written down. exp152's own `Cargo.toml` says:

> This comment said FOUR for as long as this firmware has had a drive: it was
> inherited from exp151 and never updated. `lsusb` says five.


The `wide` lane sets `max-interface-count-8` and `max-handler-count-8` — the
largest embassy-usb offers — and the wall moves from hid 3 to hid 6. Only then
is the byte count what runs out: hid 6 needs 268 bytes of the 256
`crates/cdc-console` gives it.

## And neither wall costs a person

Both are a panic inside `Builder`, before USB exists — no log, no CDC, no
1200-baud watcher, which is the most expensive kind of death this repository
knows. [`crates/lifeline`](../../crates/lifeline/) caught both:

```text
-- narrow hid 3 --        -- wide hid 6 --
did not enumerate         did not enumerate
bootsel after: 1 s        bootsel after: 1 s
drive present: yes        drive present: yes
```

One second, drive presented, reflashed by the script that was already running.
Nobody was in the room for any of it — which is what makes walking into a wall
an experiment rather than an accident.

## Run it

```sh
./drop.sh     # needs a board and nobody. Writes capture.txt.
./check.sh    # rules on the capture and on the source. No board needed.
```

## What this does not show

- **Only HID was added.** MSC, NCM and vendor interfaces cost different numbers
  of descriptor bytes and different numbers of interfaces; the 33 above is HID's.
  What generalises is the ceiling, not the per-interface price.
- **The filler carries nothing.** These HID interfaces have a 22-byte report
  descriptor and no traffic. The experiment measures the room an interface takes
  up, not whether four of them can be driven at once.
- **8 is embassy-usb's largest**, so the wide lane's own ceiling was not tested
  against a raised one — there is no `max-interface-count-16`.

## Standing on

- [exp140](../exp140-a-checksum-that-passes/) — why "it enumerated" is not a
  result, and every arm has to be able to fail.
- [exp156](../exp156-a-wall-you-can-measure/) — a wall is worth more than a
  failure, and it has to have a number on it.
- [exp190](../exp190-the-board-that-brings-itself-back/) — the recovery this
  experiment leans on for both walls, and the crate this one extends.
