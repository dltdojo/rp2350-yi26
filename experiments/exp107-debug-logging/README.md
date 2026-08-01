# exp107-debug-logging — three tasks, one log

Three things run at once and all of them talk: a heartbeat flashing the LED, a
watcher polling the BOOTSEL button, and a probe measuring how late its own
wakeups are. They share one serial port and none of them can be stalled by
the host.

This is the experiment where printing stops being a thing you do *instead of*
working.

Needs: any RP2350 board with a plain LED, and the exp102 toolchain.

## Why this comes after exp104

exp104 could already print. What it could not do was print *safely*: it
measured two log lines arriving **21 seconds apart** because a write into a
port nobody drains parks the task doing the writing. exp106 worked around
that by only printing when a terminal was attached, which kept the button
responsive and quietly gave up on the log.

A debug tool that changes the timing of the thing being debugged is worse
than no debug tool, because it lies. So this experiment fixes it properly,
and the fix turns out to need exactly the machinery — tasks, a queue, a
policy for when things go wrong — that async is for.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — three small loops that call `log!`.
- [`crates/usb-log/src/lib.rs`](../../crates/usb-log/src/lib.rs) — **read this
  one.** About a hundred lines, and the actual subject of the experiment.

## Two ways to do it

```sh
./run.sh      # guided: flash, ignore the port on purpose, then read it
./check.sh    # verdict: builds, and checks the running board if there is one
```

## Expected output

Captured from a real Pico 2 on Ubuntu.

```console
$ ./check.sh
PASS  toolchain present (cargo, elf2flash)
PASS  firmware compiles (211920 byte ELF)
PASS  crates/usb-log builds standalone
PASS  converts to UF2 (43008 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  board enumerated as 1209:0001
PASS  serial port present: /dev/ttyACM0
PASS  heartbeat task is logging
PASS  scheduler probe is logging
PASS  2 independent tasks interleaved in one stream
PASS  heartbeat sequence unbroken while reading
```

Now the interesting part. `run.sh` flashes the board and then **deliberately
ignores the port for twenty seconds** before opening it:

```console
$ stty -F /dev/ttyACM0 -icrnl && cat /dev/ttyACM0
[      37 ms] exp107 up. Queue holds 16 lines.
[      37 ms] Nothing has been read from this port yet, and nothing cares.
[      87 ms] heartbeat #1 (LED flashed)
[    1037 ms] scheduler: 10 wakeups, worst lateness 7 us
[    1087 ms] heartbeat #2 (LED flashed)
...
[    7087 ms] heartbeat #8 (LED flashed)
[   21037 ms] (+26 lines lost) scheduler: 210 wakeups, worst lateness 7 us
[   21088 ms] heartbeat #22 (LED flashed)
[   22037 ms] scheduler: 220 wakeups, worst lateness 7 us
```

Read that gap carefully, because it is the whole experiment:

- The **first seven seconds of the board's life are in there**, starting at
  37 ms, even though nothing opened the port until twenty seconds later.
  Output written before anyone was listening survived.
- The log stops at heartbeat **#8** and resumes at **#22**. Fourteen
  heartbeats are missing from the log — and the numbering proves the
  heartbeat task never missed one. It kept its rhythm the entire time the log
  was going nowhere.
- `(+26 lines lost)` is attached to the first line that made it out after the
  gap, so the loss is marked where it happened rather than announced from
  somewhere convenient. Note it landed on a `scheduler:` line: the survivor is
  whichever task logged first, not a designated one.

And with a finger on the button:

```console
[  207037 ms] scheduler: 2070 wakeups, worst lateness 30 us
[  207092 ms] heartbeat #208 (LED flashed)
[  207158 ms] BOOTSEL down  (press #1)
[  207339 ms] BOOTSEL up    (press #1)
[  208037 ms] scheduler: 2080 wakeups, worst lateness 30 us
```

Five presses were recorded as ten clean edges, held for 120–240 ms each. No
task knows about any other; the interleaving is just three loops sharing one
queue.

## What the numbers are telling you

**7 µs of scheduler lateness** while idle. The probe asks to be woken every
100 ms and gets woken 7 µs late. That is the executor's overhead, measured on
your board — not a claim from a README.

**7 to 32 µs across runs.** Repeated runs of this same firmware settled on
7 µs, 12 µs, and 32 µs as their worst case. Worth stating plainly: this is a
*worst-ever* value, so it only ever goes up, and what it catches depends on
what happened to coincide with a wakeup. Do not read a single run as a
constant. The useful habit is watching whether the number changes when you
change something.

**16 lines of queue, 26 lines lost in 14 seconds.** Two lines a second, a
queue that holds sixteen. The arithmetic is boring and that is the point —
the drop rate is a consequence of numbers you chose, not a mystery.

## The three ideas to take away

1. **A queue does not make USB faster; it moves the waiting somewhere
   harmless.** The logger task still blocks. It just blocks where nothing
   else is waiting on it. Most "make it non-blocking" work is this move, not
   an optimisation.

2. **When a buffer fills, something has to give — and silence is the worst
   option.** Waiting reintroduces the original bug. Dropping loses data. This
   design drops *and says how much*, because reading an incomplete log while
   believing it complete is worse than either.

3. **Timestamp at the event, not at the print.** If the line were stamped on
   its way out of the queue, every delay you were hunting would be absorbed
   into the measurement that was supposed to reveal it.

## The bug this experiment shipped with, briefly

The first version of this firmware logged unconditionally, whether or not a
host was listening. It ran beautifully — and after about thirty seconds of
writing into a closed port, **the board stopped answering USB control
requests**.

Not visibly. The serial stream kept flowing perfectly; heartbeats kept
arriving; the LED kept blinking. But `SET_LINE_CODING` never completed again,
which means the exp105 1200-baud reflash touch hung for as long as you cared
to wait, and the only way back in was the physical BOOTSEL button. Attaching
a reader afterwards did not clear it.

The trigger is reproducible: leave the port closed long enough for the queue
to fill, and the next control transfer never returns. exp104 through exp106
never hit it because none of them wrote to a port nobody had opened —
exp106's `dtr()` check, which looked at the time like a small optimisation,
was quietly preventing this.

The fix is in `crates/usb-log`: the writer waits for DTR before putting
anything on the wire. Lines still queue while nobody is listening, and still
drop when the queue fills — that behaviour is unchanged and is what you see
in the output above.

**What is not known:** the mechanism. Whether this is embassy-rp's USB
driver, an interaction with the host's cdc-acm driver, or something in the
RP2350 controller itself has not been established — only the trigger, the
symptom, and a fix that survives repeated hardware testing. It is written
down here rather than tidied away because the next person to leave a packet
armed on an unread endpoint deserves to find this page.

## Things this does not do

- **No log levels, no filtering, no `defmt`.** A timestamp and a line of text.
  Levels are a thing to add when something needs them.
- **No formatting beyond `core::fmt`.** Lines are capped at 96 bytes and a cut
  line ends in `...` so truncation is visible.
- **Nothing is authenticated.** Anything logged is readable by any local
  process that can open the port. `../audit.sh` reports this. Do not log
  secrets.
- **No host input.** The port is still one-way; reading what the host types is
  a later experiment.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| A blank line after every entry | Host-side CR→LF translation | `stty -F /dev/ttyACM0 -icrnl` — `run.sh` does this for you |
| No output at all | Another program holds the port | `fuser -v /dev/ttyACM0` |
| LED never flashes | Pico 2 **W** | Its LED is not on GPIO 25 — see [Boards](../README.md#boards) |
| `stty` hangs and the board will not reflash | Firmware left a packet armed on an unread endpoint | See the section above; recover with the BOOTSEL button |
| Log jumps, no `lines lost` marker | Nothing was dropped | The queue never filled — that is the good case |

## Next

The port has been one-way since exp104: the board talks, the host listens.
Making it two-way — the host types, the firmware reacts — turns the keyboard
into an input device and raises a question this experiment carefully avoided,
which is what happens when a task is waiting on two different things at once.
