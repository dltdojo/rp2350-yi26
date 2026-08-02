# exp109-hardware-trng — real entropy, and what it costs to ask

exp108 read a sensor: hardware that measures something real. This one reads
hardware that manufactures something no measurement could predict — the
RP2350's true random number generator, which samples a free-running ring
oscillator and turns the jitter into bits.

Asking for bytes is one line. Getting them at a sensible speed is the
experiment, and it comes down to a single constant that the upstream driver
sets wrong for this board.

Needs: any RP2350 board, and the exp102 toolchain. **RP2350 only** — the
RP2040 has no TRNG, so this is the first firmware here that cannot be
back-ported to one.

## Why a real entropy source is slow

A pseudo-random generator answers instantly, every time, and is never random.
A hardware entropy source is the other way round: it does not simply hand over
what it collected, because what it collected might not be any good.

The RP2350's TRNG runs three health tests — an autocorrelation test, a CRNGT
test, and a Von Neumann balancer — all enabled by default. A block of samples
that fails any of them is **discarded, and collection starts again**. Nothing
is reported when that happens. The only symptom is that the answer takes
longer.

So the cost of asking is variable and has no upper bound worth relying on.
That is not a defect. It is what makes the thing an entropy source rather than
a fast function, and it is why this firmware prints the timing of every single
request.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — one task, and one constant with a table
  above it. Read `TRNG_SAMPLE_COUNT` first.

## Two ways to do it

```sh
./run.sh      # guided: build both configurations and watch the difference
./check.sh    # verdict: builds, and checks the running board if there is one
```

## The constant

`sample_count` is how many clock cycles the TRNG waits between two consecutive
ring-oscillator samples. `embassy-rp`'s default is **25**.

On this board that is too fast. Samples taken that close together are still
correlated with each other, the health tests catch it, and the work is thrown
away — over and over.

Measured on a real Pico 2, asking for 64 bits each time:

| `sample_count` | time to produce 64 bits |
| --- | --- |
| **25** (upstream default) | 0.38 s, then **31.4 s**, then **14.5 s** |
| **1000** (used here) | 5.0 – 6.3 ms, every time |

Those are three consecutive fills in the first row, not a worst case dug out
of a long run. Build with `--features upstream-default` and watch it happen.

Two things about that row are worth saying plainly. It is **not a hang and not
a crash** — the firmware is fine, the heartbeat never misses a beat, and every
request is eventually answered. And something that always works but sometimes
takes half a minute is *harder* to diagnose than something that simply breaks,
because there is nothing to catch: no error, no panic, no log line. Just a gap.

Finally, the fix does not do what it looks like it does. Sampling more slowly
**does not make the entropy better**. The bits were always going to be as good
as the ring oscillator is. What changes is that consecutive samples become
independent enough that the health tests stop rejecting them, so less work is
wasted. Those are different claims and it is worth not merging them.

## Expected output

Captured from a real Pico 2 on Ubuntu, at `sample_count = 1000`:

```
[      37 ms] exp109 up. sample_count = 1000.
[      43 ms] trng: 14 99 71 53 cc 15 16 53
[      43 ms] cost: 5812 us this time, 5812 best, 5812 worst over 1 rounds
[      87 ms] heartbeat #1
[    1048 ms] trng: 08 2c 31 85 c1 20 26 fd
[    1048 ms] cost: 5178 us this time, 5178 best, 5812 worst over 2 rounds
[    1087 ms] heartbeat #2
[    2054 ms] trng: 75 2f 35 b0 25 24 97 e9
[    2054 ms] cost: 5653 us this time, 5178 best, 5812 worst over 3 rounds
```

And the same firmware built with `--features upstream-default`:

```
[      37 ms] exp109 up. sample_count = 25.
[      87 ms] heartbeat #1
[     419 ms] trng: 95 1c 7c f8 cc d8 4a ab
[     419 ms] cost: 381901 us this time, 381901 best, 381901 worst over 1 rounds
[    1087 ms] heartbeat #2
[    2087 ms] heartbeat #3
...                                    ← thirty seconds of heartbeats, no trng
[   32838 ms] trng: aa 99 49 6d 55 4a 3b a5
[   32838 ms] cost: 31418563 us this time, 381901 best, 31418563 worst over 2 rounds
[   48324 ms] trng: 52 ab 6c 57 19 0f 8f 61
[   48324 ms] cost: 14486463 us this time, 381901 best, 31418563 worst over 3 rounds
```

The heartbeats in the middle are the whole reason they are printed. Without
them, thirty silent seconds could equally be a dead firmware, an unplugged
board, or a host that stopped reading.

## Are the bytes any good?

This experiment does not answer that, and it is important that it does not
pretend to. Bytes that arrive quickly and bytes that are unpredictable are two
unrelated properties, and everything above is about the first one.

Look at the hex in the captures. They look random. So would a counter
encrypted with a fixed key, and so would the output of a badly-seeded PRNG.
**exp111** is where they get measured — including the ADC readings from exp108,
which also look random and are not.

## Make it yours

1. `cargo build --release --features upstream-default`, flash, and watch.
   Time how long you are willing to stare at heartbeats before assuming
   something is broken. That instinct is the thing being trained here.
2. Set `TRNG_SAMPLE_COUNT` to something in between — 100, say — and find
   where the cost stops being wild. The number in this file is one measured
   answer on one board, not a constant of nature.
3. Ask for more bytes per round by raising `BYTES_PER_ROUND`. The TRNG
   produces 192 bits per block internally, so watch what happens at the point
   where one request needs two blocks.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Build fails on `trng` | Package feature missing | `rp235xa` or `rp235xb` must be set — there is no TRNG on RP2040 |
| Long silences between `trng:` lines | You built with the upstream default | That is the experiment — see the table above |
| No `trng:` lines *and* no heartbeats | Not the TRNG. The firmware or the port | `yi26 doctor` |
| `Permission denied` on the port right after flashing | Device node just recreated, udev catching up | Wait a second, try again |

## Next

**exp110** takes the one line this firmware was careful about — `fill_bytes`
rather than `blocking_fill_bytes` — and shows what the other choice costs.
With waits this long, the difference is not academic: it decides whether the
board can still be reflashed over USB.
