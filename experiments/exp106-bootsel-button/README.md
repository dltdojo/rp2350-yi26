# exp106-bootsel-button — the button that was there all along

Press BOOTSEL, the LED lights. Release it, the LED goes out. The classic first
microcontroller experiment — on a board that has **no user button**, with
nothing wired and nothing bought.

exp101 said BOOTSEL was for getting into the bootloader at power-on. That was
true only because nothing was looking at it while your firmware ran. Now
something is.

Needs: any RP2350 board with a plain LED, and the exp102 toolchain.

## The code IS the walkthrough

Two files, and the second one is the point:

- [`src/main.rs`](./src/main.rs) — the experiment. One line does the work:
  `let pressed = bootsel::is_pressed();`
- [`crates/bootsel/src/lib.rs`](../../crates/bootsel/src/lib.rs) — **read this
  one.** It explains exactly what that call does to your chip, and what it
  costs.

## Two ways to do it

```sh
./run.sh      # guided: flash, then press the button and watch
./check.sh    # verdict: builds and converts, no board needed
```

## Honest warning: this is a big box of magic

Elsewhere this repository hides awkward machinery behind a labelled one-liner —
`rp2350-linker` in exp103 is the reference case. `crates/bootsel` is the same
idea but a **much larger box**, and it would be dishonest to present it as an
equivalent little convenience.

BOOTSEL is not wired to a GPIO. To save a pin it hangs off the QSPI flash
chip's chip-select line. Reading it means floating that line, sampling it, and
putting it back — and while it floats, **the flash chip cannot be reached**,
which matters enormously because your code executes directly out of that
flash. So the sampling routine has to live in RAM, with interrupts off for the
duration.

That is why this is the least beginner-ish thing in the repository despite
looking like the most beginner-ish.

## Expected output

Captured from a real Pico 2 on Ubuntu:

```console
$ ./check.sh
PASS  toolchain present (cargo, elf2flash)
PASS  firmware compiles (210844 byte ELF)
PASS  crates/bootsel builds standalone (cortex-m only, no HAL)
PASS  converts to UF2 (38912 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  board enumerated as 1209:0001
PASS  serial port present: /dev/ttyACM0

$ cat /dev/ttyACM0
exp106: BOOTSEL DOWN (press #2, each read costs ~20700 ns)
exp106: BOOTSEL up   (press #2, each read costs ~20700 ns)
```

**~20.7 microseconds per read**, measured on the board itself rather than
quoted from a datasheet — the firmware times 100 reads at startup and divides.
Compare that with a real GPIO read, which is a single load instruction.

At the 20 ms polling interval this firmware uses, that is about **0.1% of the
time with interrupts disabled**. Acceptable for a button. Poll it every
100 µs instead and you would spend a fifth of your interrupt latency asking
whether a finger is present.

## The three ideas to take away

1. **Constraints are worth attacking before accepting them.** "This board has
   no user button" was true, and also not the end of the story. The pin was
   there; it was just busy doing something else.

2. **Abstractions should be labelled, not denied.** `is_pressed()` reads like
   an ordinary GPIO call and is nothing of the sort. Hiding the machinery is
   good; hiding *that there is machinery* is how people write tight polling
   loops and then wonder why their USB stack stutters. Hence the measurement
   printed at runtime, and the entry in `../audit.sh`.

3. **Cost is a number, not an adjective.** "Expensive" means nothing on its
   own. ~20.7 µs against a 20 ms poll is a ratio you can reason about, and it
   is the kind of thing worth measuring rather than assuming for any hardware
   trick you adopt.

## Things this does not do

- **No debouncing.** While you hold the button the level is steady, and the
  few milliseconds of contact bounce at each edge are far too short to see on
  an LED. A press-to-*toggle* design would need debouncing; that is a fine
  next exercise.
- **No async API.** `is_pressed()` is a plain blocking call, deliberately.
  BOOTSEL has no interrupt, so any `wait_for_press().await` would be a polling
  loop wearing a disguise — and the polling rate is exactly the trade-off you
  should be making consciously.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| LED never lights | Pico 2 **W** | Its LED is not on GPIO 25 — see [Boards](../README.md#boards) |
| Board reboots when pressed | You held it during power-on | That is the ROM, not this firmware — replug without holding it |
| No log output | Nothing has the port open | The firmware only writes when a terminal is attached (`dtr()`) |
| Log stops but LED still works | Working as designed | The log is skippable; the button is not |

## Next

Every input experiment so far has been the board reacting instantly. The
interesting question now is what happens when several things need attention at
once — a button, a timer, and a host all wanting the CPU — which is what
Embassy's tasks and channels are actually for.
