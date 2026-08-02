# exp113-enumerable-seed — a seed you can count to

exp112 ended with a fix that looks reasonable. The software generator was
predictable because its seed was a constant, so seed it from something
device-specific instead. Every board then produces its own sequence, the
reboot tell disappears, and every statistical test still passes.

This experiment asks what that fix is worth, and answers by **cracking it on
the same chip that produced it**.

Needs: any RP2350 board, and the exp102 toolchain.

> Nothing here is a key and nothing here should be used as one. That is the
> point: the number turns out to be small enough to enumerate, so it was never
> a secret to begin with.

## The failure class

A seed assembled from ingredients that are individually reasonable and
collectively guessable:

- something **device-specific but not secret** — a serial number, a chip ID,
  a MAC address. It makes each unit different, which is what makes it feel
  like it is doing work. Anyone holding the device can read it.
- something **variable but not very** — a timer, an uptime, a boot counter.
  It differs run to run, which is what makes it feel random. It differs by
  much less than its width suggests.

The result advertises a large number of bits and delivers a small one. Nothing
downstream notices, because the output is the right size and passes every test
you would think to run.

## What this firmware does

1. Reads 32 bits of chip identity out of OTP, and **prints it** — it is not a
   secret, and pretending otherwise would be the same mistake in miniature.
2. Reads the timer at boot.
3. XORs them into a seed, and emits eight bytes from it with the same
   xorshift32 exp112 used.
4. Then searches for the timer value that reproduces those eight bytes,
   reporting how many candidates it tried and how long it took.

## Expected output

Captured from a real Pico 2 on Ubuntu.

```
[      37 ms] exp113 up. Building a seed the lazy way, then breaking it.
[    3037 ms] otp identity (public, printed on purpose): 1f6ba31a
[    3037 ms] output from the seed: 99 1b 3b 54 9d 27 4c de
[    3037 ms] Those bytes pass every test in exp111. Now watch them stop being a secret.
[    3084 ms] CRACKED: hidden value was 37654 us. 37655 candidates in 46 ms.
[    3084 ms] The board that made this seed found it again in 46 ms. It was never a secret.
[    3103 ms] rate: 16384 candidates in 18800 us -> about 871 per ms
[    3103 ms] so a full 2^24 sweep would take about 19262 ms (extrapolated, not swept)
[    3103 ms] Effective difficulty was 37655 of those. Entropy is not space.
```

Forty-six milliseconds, on a 150 MHz microcontroller, by the same chip that
generated the seed.

## Entropy is not space

The search covers 2^24 candidates, and at the measured rate a full sweep of
that space would take about **19 seconds** on this chip. That is the number
most people would quote.

It is not the number that matters, because an attacker does not search
uniformly. They start where the answer probably is. Here are the boot-timer
values from eight consecutive boots of the same board:

```
37605  37654  37655  37660  37666  37677  37678  37684
```

A spread of **79 microseconds**. Not 2^24 possibilities — about **2^6**.

Someone who has watched one board boot eight times knows to try eighty
candidates, which at 871 per millisecond is **under a tenth of a millisecond**.
The 24-bit search space was never the difficulty. It was the width of a field,
and the entropy in that field was six bits.

Scaling outwards from the measured rate, on this chip:

| space | time to sweep |
| --- | --- |
| 2^24 | 19 seconds |
| 2^32 | about 82 minutes |
| 2^64 | longer than the age of the universe |
| the actual entropy here (~2^6) | 0.09 milliseconds |

A desktop is orders of magnitude faster than this microcontroller, and the
last row does not care either way.

## The chip identity is stable, and that is the problem

`1f6ba31a` on every boot, which is what a chip identity is supposed to be. It
makes each board's stream unique — genuinely, which is why this looks like a
fix — and it contributes **zero bits** against anyone holding the board, since
it is readable by anyone holding the board. This firmware prints it to make
that concrete.

Uniqueness and unpredictability are different properties. A seed built from a
serial number has the first and none of the second.

## What broke during development, and why it is in this README

The first version of this experiment swept the whole 2^24 space instead of
measuring a rate. The loop yielded to the executor — exp110's lesson, applied
— but only every 65536 candidates, which is about **17 milliseconds of work
between yields**.

That was enough to lose USB enumeration. The kernel log:

```
usb 1-7: new full-speed USB device number 55
xhci_hcd: Timeout while waiting for setup device command
usb 1-7: device descriptor read/all, error -71
usb usb1-port7: unable to enumerate USB device
```

The firmware was running perfectly. It simply never finished enumerating,
which meant no serial port, which meant no 1200-baud reboot, which meant the
board could only be recovered by a human holding BOOTSEL.

Three things came out of that, and all three are in the code:

- **The seed is read at boot; the heavy work waits three seconds.** That
  guarantees a responsive window on every boot, which is what keeps a
  misbehaving firmware recoverable.
- **`YIELD_EVERY` is 2^10, not 2^16.** Yielding and staying responsive are
  different claims, and the difference is a number nobody measured.
- **The worst case is extrapolated from a timed batch, not swept.** It costs a
  thousandth of the work, answers the same question, and cannot starve
  anything. It is also what you would actually do.

Enumeration is the one window where a busy executor is unrecoverable from the
host. Heavy work at boot is the worst possible place for heavy work.

## Make it yours

1. Change `SEARCH_BITS` to 20 and watch it still find the answer instantly.
   Then set it to 8 and watch it fail. Somewhere between those is the real
   entropy of your board's boot timer — find it, and you have measured
   something the datasheet does not tell you.
2. Seed from the OTP identity **alone**, dropping the timer. Every board still
   gets its own stream; every board's stream is now fully determined by a
   number printed on its own log. The tests still pass.
3. Replace the whole seed with `trng.fill_bytes()` from exp109. The search
   finds nothing, and the reason is not that it got harder — it is that there
   is no longer a small field to search. That is the difference this whole
   track is about.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `not found in 2^24 candidates` | Boot took longer than the space covers | Raise `SEARCH_BITS`; the arithmetic is unchanged |
| OTP identity reads `00000000` | These rows are not programmed on your part | Print more rows; the experiment works with any stable value |
| Board stops enumerating after a change | Heavy work moved into the first moments after boot | Hold BOOTSEL, replug, flash a known-good `.uf2` — and read the section above |
| Cracked value is millions, not tens of thousands | The seed is being read after the delay, not at boot | `hidden` must be captured before `Timer::after` |

## Next

**exp114** is the other half of the answer. exp111 said its two tests were
"monitoring, not certification", and pointed at NIST SP 800-90B as a document
rather than a function call. exp114 implements the two continuous health tests
that document actually specifies — and, unlike everything so far, refuses to
emit output when they fail.
