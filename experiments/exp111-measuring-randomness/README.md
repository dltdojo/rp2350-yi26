# exp111-measuring-randomness — both of these look random

exp108 read a temperature sensor. exp109 read a hardware entropy source. Print
raw bits from either one and they look identical:

```
trng: e7 4f 2d 8d    adc-lsb: 90 d1 36 ba
```

No pattern, no structure, nothing a person could pick out of either. One of
them is random and the other is a thermometer being misused, and **you cannot
tell by looking**.

So this experiment stops looking and starts counting.

Needs: any RP2350 board, and the exp102 toolchain.

## The two tests

The firmware harvests the same number of bits from both sources every round
and scores each with two tests that are about as cheap as tests get:

- **ones** — what fraction of the bits are 1. A fair coin gives 50%.
- **changes** — how often a bit differs from the one before it. Also 50%.

Two, not one, and that is the design. One test that passes proves much less
than two tests that disagree. A source stuck in a long run of the same value
sails through the first — long runs of ones and long runs of zeroes still
average out to half — and fails the second badly.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — two counting functions of about ten lines
  each, and one task that feeds both sources through them.

## Two ways to do it

```sh
./run.sh      # guided: build, flash, watch the four numbers settle
./check.sh    # verdict: builds, and checks the running board if there is one
```

## Expected output

Captured from a real Pico 2 on Ubuntu.

```
[      37 ms] exp111 up. Scoring two sources against a fair coin.
[      44 ms] Both of these look random. One of them is not.
[      44 ms] trng: e7 4f 2d 8d  adc-lsb: 90 d1 36 ba
[      44 ms] ones     after 64 bits: trng 45.3%  adc-lsb 56.2%  (fair coin 50.0%)
[      44 ms] changes  after 64 bits: trng 51.5%  adc-lsb 48.4%  (fair coin 50.0%)
[    1049 ms] ones     after 128 bits: trng 46.8%  adc-lsb 65.6%  (fair coin 50.0%)
...
[   41290 ms] ones     after 2688 bits: trng 49.4%  adc-lsb 69.4%  (fair coin 50.0%)
[   41290 ms] changes  after 2688 bits: trng 51.0%  adc-lsb 39.3%  (fair coin 50.0%)
```

After 2688 bits:

| | ones | changes |
| --- | --- | --- |
| **TRNG** | 49.4% | 51.0% |
| **ADC bottom bit** | 69.4% | 39.3% |
| *a fair coin* | *50%* | *50%* |

The TRNG approaches 50% from both directions and stays there. The ADC's bottom
bit fails both: too many ones, and too few changes between neighbouring bits —
long runs, which is exactly what a reading hovering between two adjacent counts
produces.

## The first four numbers are worthless

Look at the 64-bit line. The TRNG reads 45.3% and 51.5%; the ADC reads 56.2%
and 48.4%. On that evidence the ADC is the better source.

It is not. Sixty-four bits is not enough data to say anything at all, and a
statistic on too little data is not a small truth — it is noise with a decimal
point on it. Watching the numbers separate as the totals grow is the first
thing this experiment teaches, and it costs nothing but waiting.

**Run it more than once.** Across runs while this was being written, the ADC's
`ones` score ranged from 32.8% to 84.1%, and once — over six thousand bits —
landed on 47.5%, comfortably inside anything anyone would call a pass. The
TRNG never moved off 50%.

That instability is the real finding. A source whose statistics depend on how
steady the room is, is not an entropy source.

## What neither test can see

This matters more than either result, because it is the part that gets people
into trouble.

- The sequence `0101010101…` scores a **perfect 50% on both tests**. It is
  also entirely predictable.
- Neither test looks further back than one bit. Any pattern with a period
  longer than two is invisible to both of them.
- Neither has any concept of an adversary. "Looks like noise" and "cannot be
  guessed by someone who knows how it was made" are different properties, and
  only the second is what a random number generator is *for*. An encrypted
  counter passes every test here and is completely deterministic to anyone
  holding the key.

Real assessment is NIST SP 800-90B, and it is a document, not a function call.

What the two tests here *are* good for is running on the device, forever, to
catch a source that has **broken** — an oscillator that stopped, a sensor
stuck at one value. That is monitoring, not certification, and it is a job
worth doing: a TRNG that silently dies returns bytes that look exactly like a
TRNG that is working.

## Make it yours

1. Add a third "source" that is a counter — `0, 1, 2, 3, …` — and feed its
   bytes through the same two tests. Watch it score close to 50% on `ones`.
   That is the cheapest possible demonstration of what passing means.
2. Now feed the tests `0xAA` repeated (`10101010…`). Perfect on both. Then
   look at the hex and see how obviously wrong it is.
3. Warm the chip with a finger while the ADC column is running and watch its
   scores move. Nothing about the code changed — you are watching a
   statistical property of a "random" source respond to the temperature of the
   room, which is the whole argument against using it.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Both columns near 50% | Not enough bits yet | Wait. Below a few hundred bits everything looks fine |
| ADC column also near 50% after minutes | Your chip's noise happens to be balanced right now | Re-run later, or warm the chip — see "run it more than once" |
| No `adc-lsb` numbers | Reading a GPIO channel, not the sensor | `Channel::new_temp_sensor` — exp108 |
| Long gaps between rounds | TRNG sample_count | exp109 explains this one in full |

## Next

Two cheap tests disagreed, and that was enough to tell these two sources
apart. It is not enough to trust either of them.

**exp112** is the failure that survives every test on this page: a build that
quietly stopped using the hardware RNG and produces numbers that pass
everything, because software-generated numbers do. Then **exp113** shows a
seed whose space is enormous and whose entropy is about six bits, and
**exp114** replaces "score it" with the thing a real source does — refuse to
emit when its own health tests fail.
