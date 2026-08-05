# exp114-health-tests — tests that refuse

exp111 counted ones, counted changes, printed two percentages, and said
plainly that this was monitoring rather than certification. It pointed at NIST
SP 800-90B and noted that it is a document, not a function call.

This is the part of that document that *is* a function call: the two
continuous health tests from section 4.4. And one behaviour separates it from
every test in this repository so far.

**When a source fails, it stops being used.** Not flagged, not printed in red —
stopped. A test that reports and carries on is a report. A health test gates
the thing it watches, and the difference is one `if`.

Needs: any RP2350 board, and the exp102 toolchain.

## The two tests, and where the numbers come from

Both cutoffs are derived from a stated false-positive rate — α = 2^-20, about
one spurious alarm per million samples — and an assumed min-entropy of 1 bit
per sample. Nobody picked them because they looked strict enough.

**Repetition Count Test.** `C = 1 + ceil(-log2(α) / H)`, which for H = 1 gives
**C = 21**. Twenty-one identical bits in a row from a fair coin has
probability 2^-20, which is exactly the false-positive budget being spent. It
catches a source that has *stuck*.

**Adaptive Proportion Test.** Window W = 1024. The first sample of each window
is the reference; count how many of the window match it; fail if that count
reaches **C = 589** against a mean of 512. `C` is the smallest value for which
`P(Binomial(1024, 2^-H) >= C) <= 2^-20`. It catches a source that still
changes but has developed a strong preference — the failure a repetition count
cannot see.

Assuming H = 1 is the most demanding choice available for a binary source, and
therefore the right one for something claiming to be a TRNG: it produces the
tightest cutoffs. SP 800-90B expects that number to come from an entropy
assessment of the specific noise source. **This is not that assessment**, and
calling it one would be exactly the sort of claim exp112 is about.

## The code IS the walkthrough

- [`crates/entropy-health/src/lib.rs`](../../crates/entropy-health/src/lib.rs)
  — **read this one.** About a hundred lines, no dependencies at all, and five
  unit tests that run on your laptop.
- [`src/main.rs`](./src/main.rs) — three sources fed through it.

The crate has no dependencies on purpose. These tests are arithmetic on a
stream of bits: no hardware, no async runtime, no chip. Keeping them free of
all three means `cargo test` runs them on the machine you are reading this on,
which matters more here than anywhere else in this repository — **the cutoffs
are the part most likely to be wrong, and a wrong threshold still produces
confident output.**

```sh
cd crates/entropy-health && cargo test
```

## Three sources, and why the third one is not a joke

- the **TRNG** from exp109, which should pass;
- the **ADC bottom bit** from exp111, which exp111 found wanders — so this
  reports whatever happens rather than promising a result;
- a **deliberately broken source**: nine ones then a zero, forever.

That third one is a known-answer test for the health tests themselves. A check
that has never been observed to fire is indistinguishable from a check that
cannot fire, and code gets refactored. It is also chosen to be *biased rather
than stuck*, so it passes the repetition count and can only be caught by the
adaptive proportion test — proving both, and proving they catch different
things.

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone. One firmware,
three sources, and two tests that each catch a different one.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 and a USB data cable. RP2350 only — it uses the TRNG.
  * Ubuntu. `cat` and `stty` are already there.
  * Twenty seconds of watching. One of the two failures needs 1024 bits before
    it can be declared, and that is the honest cost of the test, not a delay.

1. UNPACK IT.

       unzip exp114-health-tests.zip
       cd exp114-health-tests

2. PUT THE FIRMWARE ON THE BOARD. **[HUMAN STEP]** Hold BOOTSEL, plug in, let
   go:

       cp firmware/exp114-health-tests.uf2 /media/$USER/RP2350/

3. WATCH ALL THREE SOURCES FOR TWENTY SECONDS.

       sleep 5
       stty -F /dev/ttyACM0 -icrnl
       timeout 20 cat /dev/ttyACM0

4. READ THE HEADER AND THE FIRST REPORT.

       [    2037 ms] SP 800-90B 4.4 continuous tests, alpha = 2^-20, assumed H = 1 bit/sample
       [    2037 ms]   repetition count cutoff C = 21   adaptive proportion W = 1024, C = 589
       [    2050 ms] trng  : HEALTHY after 256 bits (window 256/1024, 125 match ref)
       [    2050 ms] adc   : HEALTHY after 256 bits (window 256/1024, 60 match ref)
       [    2050 ms] broken: HEALTHY after 256 bits (window 256/1024, 231 match ref)

   **The source you were told is broken says `HEALTHY`, and it is not lying.**
   A test that has not seen enough data yet can honestly say nothing else.
   Stopping here would certify a source handed to you as broken on purpose.

   The `adc` line may already read `FAILED` at this point — it did in one of
   the two runs behind this walkthrough. Which report catches it depends on
   when its bottom bit happens to stick.

5. WATCH THE ADC GO, ON THE FIRST TEST.

       [    2050 ms] adc   : FAILED repetition count at 21 after 191 bits — OUTPUT WITHHELD
       ...or...
       [    3062 ms] adc   : FAILED repetition count at 21 after 293 bits — OUTPUT WITHHELD

   Those are the two runs behind this walkthrough. **`at 21` is fixed and the
   bit count is not**: the repetition count test fires the moment it sees the
   same value twenty-one times running, and when that happens is up to the
   source. It catches a source that has got **stuck**.

6. WATCH THE BROKEN ONE GO, AT ABOUT FIVE SECONDS, ON THE OTHER TEST.

       [    5083 ms] broken: FAILED adaptive proportion at 922 after 1024 bits — OUTPUT WITHHELD
       [    5083 ms] -> 1 of 2 real sources still permitted to emit; broken source correctly rejected

   **This one is reproducible to the millisecond** — 5083 and 5084 ms in the
   two runs, and `922 after 1024 bits` in both. The broken source never
   repeats itself; it is **biased**, not stuck, so the repetition count never
   fires at all. The adaptive proportion test counts how many of 1024 samples
   match a reference and wants fewer than 589. It saw 922. It could not say
   anything at all until it had all 1024 samples, which is why this arrives at
   five seconds and not at two.

   Both lines then repeat every second for as long as you watch. If you are
   reading a capture rather than a live port, take the *first* occurrence —
   the later ones carry the same numbers at a later timestamp and are easy to
   mistake for a much slower failure.

7. TAKE THE POINT. Two tests, two failure modes, and neither would have caught
   the other's. `OUTPUT WITHHELD` is the part that matters: this source does
   not report a problem and carry on, it stops emitting. A health test whose
   failure path still hands you bytes is a log message, not a test.

IF IT DOES NOT WORK
  * `stty` prints nothing and never returns — ModemManager. Ctrl-C, wait,
    retry.
  * Everything says HEALTHY forever — you read for three seconds. Step 6
    genuinely needs about five.
  * `adc` stays healthy — possible, and it means the bottom bit happened not
    to stick during your run. It is a biased source, not a reliably stuck one;
    exp111 measures the bias directly.

## Expected output

Captured from a real Pico 2 on Ubuntu.

```
[    2037 ms] SP 800-90B 4.4 continuous tests, alpha = 2^-20, assumed H = 1 bit/sample
[    2037 ms]   repetition count cutoff C = 21   adaptive proportion W = 1024, C = 589
[    2049 ms] trng  : HEALTHY after 256 bits (window 256/1024, 132 match ref)
[    2049 ms] adc   : FAILED repetition count at 21 after 29 bits — OUTPUT WITHHELD
[    2049 ms] broken: HEALTHY after 256 bits (window 256/1024, 231 match ref)
[    3060 ms] trng  : HEALTHY after 512 bits (window 512/1024, 254 match ref)
[    4071 ms] trng  : HEALTHY after 768 bits (window 768/1024, 385 match ref)
[    5082 ms] trng  : HEALTHY after 1024 bits (window 0/1024, 0 match ref)
[    5082 ms] broken: FAILED adaptive proportion at 922 after 1024 bits — OUTPUT WITHHELD
```

Three things in that capture are worth stopping on.

**The TRNG's window counts track the fair-coin line.** 132 of 256, 254 of 512,
385 of 768 — all within a few of half, against a cutoff of 589.

**The ADC failed after twenty-nine bits.** Not marginally, not eventually:
twenty-one consecutive identical bits, almost immediately. exp111's monobit
test gave the same source scores between 32.8% and 84.1% and sometimes a
clean-looking 47.5%. A percentage averaged over thousands of bits cannot see a
run, and the run is what a stuck source produces. **This is why there are two
tests, and why one of them looks at order.**

**The broken source stayed HEALTHY for three rounds.** The adaptive proportion
test delivers its verdict at the end of a 1024-bit window, so nothing is
reported until then. That is the standard's behaviour, not a bug, and it is
worth seeing: a health test has latency, and a source is trusted during it.

## What this still does not do

Everything exp111 said about its own tests applies here with more force,
because these come with a standard's name attached and that makes them easier
to over-trust.

- The sequence `0101010101…` passes **both** tests, forever. There is a unit
  test asserting exactly that, because it is a property worth pinning down
  rather than discovering later.
- These are the *continuous* tests. SP 800-90B also specifies startup testing,
  a validated entropy estimate, and a stochastic model of the noise source.
  None of that is here.
- Neither test has any concept of an adversary. They detect a source that has
  broken, not a source that was never good.

That is genuinely what continuous health tests are for: catching a source that
*was* working and *has stopped*. A TRNG that dies silently returns bytes that
look exactly like a TRNG that is alive — which is the whole reason exp112
exists.

## Make it yours

1. Set `RCT_CUTOFF` to 5 and watch the TRNG start failing. You have not made
   the test stricter in any useful sense; you have raised the false-positive
   rate from one-in-a-million to one-in-sixteen, and a health check that cries
   wolf gets disabled by whoever is on call.
2. Change `BrokenSource` to alternate — `true, false, true, false` — and watch
   both tests pass a completely predictable stream. Then decide what you would
   add to catch it, and how much it would cost to run continuously.
3. Feed the health tests the output of exp112's software generator. It passes.
   Health tests watch for a source that has failed; they have nothing to say
   about one that was a PRNG all along.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| TRNG fails the repetition count | Check `TRNG_SAMPLE_COUNT` — exp109 | A starved TRNG can return repeated blocks |
| Broken source never fails | The adaptive proportion window has not closed | It needs 1024 samples; wait one more round |
| ADC passes | Your chip's noise happens to be lively right now | Both outcomes are honest — exp111 explains why it wanders |
| `cargo test` fails in the crate | A cutoff was edited | That is the test doing its job; check the derivation above |

## Next

That closes the randomness track: measure it (exp111), find the fallback that
hides in a build (exp112), find the seed that was never a secret (exp113), and
gate the source on tests that refuse (exp114).

The **browser track** picks up at exp115, where a web page reads the log this
firmware is printing — with no firmware changes at all, and on a phone.
