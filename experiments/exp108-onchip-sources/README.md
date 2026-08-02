# exp108-onchip-sources — two sources of numbers you did not compute

The chip contains hardware that manufactures numbers on its own: an analogue
temperature sensor on ADC channel 4, and a true random number generator that
samples a ring oscillator. This experiment reads both, prints both, and then
does the thing that makes it worth doing — it **measures** them, because
neither one can be trusted for looking right.

Needs: any RP2350 board, and the exp102 toolchain. No parts, no wiring.

## Why this comes after exp107

Every number in the log so far was one the firmware worked out: a counter, a
timestamp, how late a wakeup was. Those are easy to trust, because you can
read the code that produced them.

These two are not. A temperature sensor hands you a voltage that means
something only if you apply a formula correctly, and an entropy source hands
you bytes that are indistinguishable from bad bytes by eye. Both are the kind
of thing that has no physical form and cannot be blinked — which is exactly
what exp107 built the log for.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — one task owning both peripherals, two
  test functions, and a heartbeat that exists to prove nothing blocked.

There is no new crate. `embassy-rp` ships both drivers, and the TRNG is gated
behind the same `rp235xa` feature the other experiments already set. The
RP2040 has no TRNG, so this is the first firmware here that could not be
back-ported to one.

## Two ways to do it

```sh
./run.sh      # guided: build, flash, watch the scores settle
./check.sh    # verdict: builds, and checks the running board if there is one
```

## Expected output

Captured from a real Pico 2 on Ubuntu.

```console
$ ./check.sh
PASS  toolchain present (cargo, elf2flash)
PASS  firmware compiles (146888 byte ELF)
PASS  converts to UF2 (47104 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  board enumerated as 1209:0001
PASS  serial port present: /dev/ttyACM0
PASS  temperature sensor is reporting
PASS  TRNG is producing bytes
PASS  temperature reading is plausible (raw 841)
PASS  monobit test is reporting
PASS  transition test is reporting
PASS  TRNG monobit is near a fair coin (50%)
PASS  heartbeat kept running alongside both sources
```

And the log itself, from boot:

```
[      37 ms] exp108 up. Two sources, one question: which of them is random?
[      37 ms] temp: raw 843 of 4095 -> 42.58 C
[      43 ms] trng: 5f 2c 7a 75 a5 55 fa 0a  (5306 us awaited)
[      43 ms] ones     after 64 bits: trng 54.6%  adc-lsb 59.3%  (fair coin 50.0%)
[      43 ms] changes  after 64 bits: trng 60.9%  adc-lsb 46.8%  (fair coin 50.0%)
[      43 ms] Two tests, two sources. Read all four numbers before the README.
[      87 ms] heartbeat #1
[    1043 ms] temp: raw 841 of 4095 -> 43.52 C
[    1049 ms] trng: 4c 78 b6 e7 76 cf 57 7d  (5492 us awaited)
[    1049 ms] ones     after 128 bits: trng 58.5%  adc-lsb 63.2%  (fair coin 50.0%)
[    1049 ms] changes  after 128 bits: trng 53.9%  adc-lsb 46.0%  (fair coin 50.0%)
...
[   30228 ms] ones     after 1984 bits: trng 50.1%  adc-lsb 84.1%  (fair coin 50.0%)
[   30228 ms] changes  after 1984 bits: trng 49.5%  adc-lsb 27.0%  (fair coin 50.0%)
```

Notice the first line of scores and the last. On 64 bits the TRNG reads 54.6%
and 60.9% — nowhere near a fair coin, and completely meaningless, because 64
bits is not enough data to say anything at all. By 1984 bits it has settled to
50.1% and 49.5%. **A statistic on too little data is not a small truth; it is
noise with a decimal point on it.** Watching those numbers converge is the
first thing this experiment teaches, and it is free.

## What the scores actually said

By the end of that run:

| | ones | changes |
| --- | --- | --- |
| **TRNG** | 50.1% | 49.5% |
| **ADC bottom bit** | 84.1% | 27.0% |
| *a fair coin* | *50%* | *50%* |

The TRNG sits on 50% from both directions and stays there. The ADC's bottom
bit fails both: too many ones, and far too few changes between neighbouring
bits — long runs of the same value, which is what you would expect from a
reading that spent the whole run hovering between `raw 841` and `raw 842`.

**Sample the same sensor on a different day and you will get different
scores.** Across runs while this experiment was being written, the ADC's
monobit score ranged from 32.8% to 84.1%, and once — over six thousand bits —
it landed on 47.5%, comfortably inside anything you would call a pass. The
TRNG never moved off 50%.

That instability is the finding. A source whose statistics depend on how
steady the room is, is not an entropy source; it is a thermometer you are
misreading on purpose.

## The default that does not work

Worth its own section, because it cost real time and would cost yours.

`embassy-rp`'s `trng::Config::default()` sets `sample_count: 25` — the number
of clock cycles between two consecutive ring-oscillator samples. On this board
that is too fast. Samples taken that close together are correlated enough to
keep failing the TRNG's own health tests (autocorrelation, CRNGT, and a Von
Neumann balancer, all on by default), and a failed test means the block is
discarded and started again.

Measured, with the default:

- `blocking_fill_bytes` for 64 bits took anywhere from **20 ms to 3.8
  seconds**, varying round to round.
- The `async` `fill_bytes` **hung and never returned**. The heartbeat kept
  going, so the executor was healthy — the future simply stopped being woken.

With `sample_count: 1000`, over 43 consecutive fills:

- minimum **4997 µs**, median **5424 µs**, maximum **6291 µs**.
- The async path is reliable.

Sampling more slowly does not make the entropy better. It makes consecutive
samples independent enough that the health tests stop rejecting them, which is
a different claim and worth not confusing.

Two things to take from this beyond the constant itself. A real entropy source
has **health tests**, and health tests mean **variable latency with no useful
upper bound** — that is the honest difference between a TRNG and a PRNG, which
always answers instantly and is never random. And a driver default is a
starting point, not a verdict: this one is in the upstream crate, it is
documented, and it still does not work here.

## Why `fill_bytes`, not `blocking_fill_bytes`

The blocking call spends the whole wait inside this task with the executor
unable to run anything else — including the 1200-baud watcher that lets the
next flash happen without touching the board. At 3.8 seconds that is the
difference between a firmware you can replace over USB and one that needs a
human holding BOOTSEL.

Awaiting hands the CPU back for the duration. The wait is the same; what
changes is whether the rest of the firmware waits with it. The heartbeat line
in the log is the evidence: it keeps ticking once a second through every TRNG
round. If it ever stops, something blocked.

## What these two tests cannot see

Both tests together are still nowhere near enough to certify a random number
generator, and it matters that you know why before reusing any of this.

- The sequence `0101010101…` scores a perfect 50% on **both** tests. It is
  also entirely predictable.
- Neither test looks further back than one bit. Any pattern with a period
  longer than two is invisible to both.
- Neither has any concept of an attacker. "Looks like noise" and "cannot be
  guessed by someone who knows how it was made" are different properties, and
  only the second one is what a random number generator is for.

Real assessment is NIST SP 800-90B, and it is a document, not a function call.
The value of the two tests here is that they are cheap enough to run on the
device, forever, and **catch a source that has broken** — a sensor that got
stuck, an oscillator that stopped. That is monitoring, not certification.

## About that temperature

The conversion in `raw_to_celsius` is the datasheet's: the sensor is a diode
reading 0.706 V at 27 °C and falling about 1.721 mV per degree. Those are
*typical* values, not a per-chip calibration, and the RP2350 datasheet is
explicit that absolute accuracy without calibration is poor.

What is trustworthy is the shape of the change. The reading of ~43 °C above is
a chip that has been running a while, not a room. Pinch the chip between two
fingers and the number moves the right way by roughly the right amount — which
is the honest way to use an uncalibrated sensor.

## Make it yours

In `src/main.rs`, set `TRNG_SAMPLE_COUNT` back to `25` — the upstream default
— rebuild, and flash. Then:

1. Watch the `us awaited` numbers. They should scatter wildly instead of
   sitting near 5400.
2. Swap `trng.fill_bytes(&mut trng_bytes).await` for
   `trng.blocking_fill_bytes(&mut trng_bytes)` and watch the **heartbeat**.
   With the default sample count and the blocking call, the heartbeat stutters
   — that is the executor unable to run while one task waits on hardware.
3. Put both back. Then try `yi26 flash` while the blocking version is running
   and see whether it still works.

Step 3 is the one worth doing slowly. A firmware that blocks long enough stops
being reflashable over USB, and finding that out on a board you can reach is
much cheaper than finding it out on one you cannot.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Build fails on `trng` | Package feature not set | `rp235xa` (or `rp235xb`) must be on — there is no TRNG on RP2040 |
| No `trng:` lines at all, heartbeat fine | The async fill is not being woken | Check `TRNG_SAMPLE_COUNT`; at 25 this is reproducible |
| Temperature reads absurd | Wrong ADC channel | `Channel::new_temp_sensor`, not a GPIO pin |
| Heartbeat stutters | Something blocking the executor | You are on `blocking_fill_bytes` — see "Make it yours" |

## Next

Both of these are sources of data with nowhere to go but a serial port. The
browser track that starts at exp109 changes that: first a web page reads this
log with no firmware changes at all, and by exp112 the board is speaking a
protocol of its own design over raw USB — at which point "what does it send?"
has an answer that is sitting right here.
