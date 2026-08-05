# exp110-await-not-block — awaiting is not the same as waiting

exp109 was careful about one line without dwelling on it. It called
`fill_bytes(..).await` and not `blocking_fill_bytes(..)`.

Both wait exactly as long. The hardware takes as long as it takes, and no
choice in your code makes the ring oscillator hurry up. This experiment is
about what happens to **everything else** during that wait, and it measures
the difference rather than asserting it.

Needs: any RP2350 board, and the exp102 toolchain.

## The setup

Same source, two builds:

```sh
cargo build --release                      # awaits
cargo build --release --features blocking  # blocks
```

Three tasks run in both:

- **entropy** asks the TRNG for 4096 bytes, which takes about 880 ms.
- **probe** wants to wake up every 100 ms and reports how late it actually
  was. It is exp107's scheduler probe, pointed at a specific suspect.
- **heartbeat** flashes the LED, so there is something to see on the board.

The request is deliberately large. exp109 asked for 8 bytes and got them in
5 ms, which is a real stall and completely invisible next to a heartbeat that
ticks once a second. 4096 bytes makes the wait most of a second, and a
most-of-a-second stall is impossible to miss.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — the two bodies differ in one call. Buffer,
  timing and log line are identical on purpose, so nothing else can be blamed
  for the measurement.

## Two ways to do it

```sh
./run.sh      # guided: build both, flash both, compare the numbers
./check.sh    # verdict: builds both, and checks the running board
```

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone. **Two firmware
images, and the difference between them is the experiment** — one word in the
source, and a number that moves by five orders of magnitude.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 and a USB data cable. RP2350 only — it uses the
    TRNG, and the RP2040 has none.
  * Ubuntu. `cat` and `stty` are already there.

1. UNPACK IT.

       unzip exp110-await-not-block.zip
       cd exp110-await-not-block
       ls firmware/

   Two images:

       exp110-await.uf2       asks for entropy and lets others run meanwhile
       exp110-blocking.uf2    asks for entropy and sits on the processor

2. FLASH THE AWAITING ONE. **[HUMAN STEP]** Hold BOOTSEL, plug in, let go:

       cp firmware/exp110-await.uf2 /media/$USER/RP2350/

3. READ IT.

       sleep 5
       stty -F /dev/ttyACM0 -icrnl
       timeout 10 cat /dev/ttyACM0

   Expect:

       [      37 ms] exp110 up, built to AWAIT. Watch the probe's worst lateness.
       [     927 ms] entropy: 4096 bytes in 890 ms (first byte 5d)
       [    2037 ms] probe: 20 wakeups, worst lateness 12 us (0 ms)
       [    2823 ms] entropy: 4096 bytes in 895 ms (first byte 87)
       [    4037 ms] probe: 40 wakeups, worst lateness 3 us (0 ms)

   **Note the probe lines land at 2037 and 4037** — on the second, every
   second. The entropy request takes 890 ms and the probe does not care.

4. FLASH THE BLOCKING ONE. **[HUMAN STEP]** Same as step 2, other file.

       cp firmware/exp110-blocking.uf2 /media/$USER/RP2350/

5. READ THAT.

       sleep 5
       stty -F /dev/ttyACM0 -icrnl
       timeout 10 cat /dev/ttyACM0

   Expect:

       [      37 ms] exp110 up, built to BLOCK. Watch the probe's worst lateness.
       [     924 ms] entropy: 4096 bytes in 886 ms (first byte 04)
       [    2804 ms] entropy: 4096 bytes in 880 ms (first byte 9c)
       [    2804 ms] probe: 20 wakeups, worst lateness 866976 us (866 ms)

   **The timestamps depend on when you opened the port, and the evidence does
   not.** If flashing took you a while, your first line may read `[44274 ms]`
   instead of `[37 ms]` — your machine's serial buffer holds only the last ten
   or twenty seconds of a board nobody is listening to, which is
   [exp107](../exp107-debug-logging/)'s subject. The lateness figure and the
   `wakeups` count are what to compare; they are the same at any uptime.

6. COMPARE TWO NUMBERS, AND THEN A THIRD.

   * **Worst lateness: 3–13 µs against 866 000 µs.** Same hardware, same
     entropy, same 890 ms wait. The probe was supposed to run every 50 ms and
     in the blocking build it ran 866 ms late.
   * **The entropy itself costs the same either way** — about 885 ms in both.
     Awaiting did not make anything faster. That is the point people expect to
     be wrong and it is not: `await` buys nothing for the thing doing the
     waiting, and everything for whatever else wanted the processor.
   * **The timestamps give it away without reading any number.** In step 3
     the probe reports at 2037 and 4037 ms. In step 5 it reports at 2804 and
     4691 — dragged along behind the entropy line, because it could not run
     until the draw let go.

IF IT DOES NOT WORK
  * `stty` prints nothing and never returns — ModemManager. Ctrl-C, wait,
    retry.
  * Both builds look the same — check which image is actually on the board.
    The first log line says `built to AWAIT` or `built to BLOCK`, which is
    there precisely so this cannot be got wrong.

## Expected output

Captured from a real Pico 2 on Ubuntu. First the awaiting build:

```
[      37 ms] exp110 up, built to AWAIT. Watch the probe's worst lateness.
[     926 ms] entropy: 4096 bytes in 888 ms (first byte ef)
[    2037 ms] probe: 20 wakeups, worst lateness 13 us (0 ms)
[    2803 ms] entropy: 4096 bytes in 876 ms (first byte 6e)
[    4037 ms] probe: 40 wakeups, worst lateness 5 us (0 ms)
[    4684 ms] entropy: 4096 bytes in 881 ms (first byte c8)
[    6037 ms] probe: 60 wakeups, worst lateness 3 us (0 ms)
```

Then the same firmware built with `--features blocking`:

```
[      37 ms] exp110 up, built to BLOCK. Watch the probe's worst lateness.
[     933 ms] entropy: 4096 bytes in 895 ms (first byte 17)
[    2832 ms] entropy: 4096 bytes in 899 ms (first byte db)
[    2832 ms] probe: 20 wakeups, worst lateness 894982 us (894 ms)
[    4707 ms] entropy: 4096 bytes in 875 ms (first byte 2b)
[    4707 ms] probe: 40 wakeups, worst lateness 870208 us (870 ms)
[    6582 ms] entropy: 4096 bytes in 874 ms (first byte 29)
[    6582 ms] probe: 60 wakeups, worst lateness 845131 us (845 ms)
```

Side by side:

| | entropy request | probe's worst lateness |
| --- | --- | --- |
| **await** | 888 ms | 3 – 13 **µs** |
| **blocking** | 895 ms | 827 – 895 **ms** |

The entropy request costs the same either way, to within noise. The probe's
lateness differs by a factor of about seventy thousand.

Look at the timestamps in the blocking capture too. The `probe:` line arrives
at 2832 ms — the *same millisecond* as the entropy line, not at the 2000 ms
where it was due. It could not report on time because reporting also needs the
executor, and the executor was not running.

## What actually happened

`blocking_fill_bytes` sits in a loop reading a hardware register until the
answer is ready. That loop is ordinary Rust code inside one task, and an
Embassy executor is cooperative: it runs a task until that task yields, and a
task that never yields is never interrupted.

So for 880 ms out of every 1900, nothing else in the firmware ran. Not the
probe, not the heartbeat, not the log writer, not the USB device task.

`fill_bytes(..).await` waits for exactly the same hardware for exactly as
long, but yields while it does. The executor spends that time running whatever
else is ready, and comes back when the TRNG's interrupt says the answer is
there. The wait is the same; what changes is whether the rest of the firmware
waits with it.

## Can you still reflash it?

This is the question that matters most in this repository, because the
1200-baud watcher from exp105 is a task like any other. If it never gets to
run, the board stops being reflashable over USB and needs a human holding
BOOTSEL.

Measured, on this board:

| flashing from | time for `yi26 flash` |
| --- | --- |
| the awaiting build | 5458 ms, 5459 ms |
| the blocking build | 5842 ms |

So: **at this request size it still works**, and costs about 380 ms extra. The
blocking task holds the CPU for 880 ms and then sleeps for 1000, so the
watcher gets regular gaps to run in and eventually lands one.

That is a measurement, not a reassurance. The margin here is a property of
this particular duty cycle, and nothing defends it — raise `REQUEST_BYTES`, or
drop the one-second sleep, and the gaps shrink until there is no room left for
the watcher to answer in. `REQUEST_BYTES` is set where it is for exactly that
reason, and the comment above it says so.

## Make it yours

1. Raise `REQUEST_BYTES` to 16384 in the blocking build and watch the probe's
   lateness follow it. Then try `yi26 flash` and time it.
2. Delete the `Timer::after` at the end of the entropy loop in the blocking
   build. This is the one to think about **before** you flash it: with no
   sleep, the task yields only inside `Timer` calls it no longer makes.
   Recovering from that may cost you a physical BOOTSEL press, which is a fine
   price for understanding it and an annoying one if your board is in another
   building.
3. Put the sleep back, keep `blocking`, and reduce `REQUEST_BYTES` to 8 —
   exp109's size. The lateness drops into the milliseconds and the firmware
   looks healthy. Blocking did not become safe; the stall became small enough
   to hide, which is how this class of bug survives code review.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Both builds show microsecond lateness | You built the same one twice | `--features blocking` needs a rebuild, not just a reflash |
| Lateness is high in the awaiting build too | Something else is blocking | Look at what else you added; the probe does not care who did it |
| `yi26 flash` times out | The blocking task has no gaps | Hold BOOTSEL, replug, flash the awaiting build |

## Next

**exp111** goes back to the two sources — exp108's sensor and exp109's
entropy — and asks the question both of them have been dodging: are the bytes
any good? They both look random. Only one of them is.
