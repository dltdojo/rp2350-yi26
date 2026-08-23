# exp180 — the silicon or the room

A ring-oscillator PUF claims that a chip's own oscillator runs at a speed
nobody else's does. Earlier work on this chip measured three boards, found a
**13.34% spread** in the ROSC base frequency — 10.828, 11.928 and 10.524 MHz —
and read that as device uniqueness.

Ring oscillators also drift with temperature, and three boards measured once
each cannot separate one cause from the other. The
[identity road](../README.md#the-identity-road) wrote this rung down as the
comparison that could: **one board cold against the same board warm.**

The comparison came out, and then a third thing turned out to be bigger than
either.

> **Verified on hardware, 2026-08-23.** Temperature is real and small: ROSC moves
> **−0.050% per degree**, measured across **6.94 °C** of the board warming itself
> from a cold start, with the crystal at 0.000% as the control. Twenty degrees of
> that is **1.00%** — **thirteen times smaller** than the spread called device
> uniqueness. What *is* bigger is `FREQ_RANGE`: **one register field, written by
> firmware, moves the same chip by 65.7%.**

## What moves this number

| | how much it moves ROSC's base frequency |
| --- | ---: |
| `FREQ_RANGE`, one field a firmware writes | **65.7%** |
| the earlier work's three boards | 13.34% |
| **20 °C of temperature** | **1.00%** |
| the crystal, over the same run (the control) | 0.000% |

So the answer to the question this rung is named after is **neither, mostly**.
The room is in there and it is measurable, and it is a tenth of the effect
being attributed to silicon. The thing that dwarfs both is a configuration
choice — and a fingerprint that a register write moves by two thirds is not a
fingerprint until that register is part of the enrolment.

```text
  ROSC as this firmware found it: range 0xfa5, freqa 0x0000, freqb 0x0000
    range LOW:    5506.12 kHz
    range MEDIUM: 6801.53 kHz
    range HIGH:   9122.87 kHz
```

That also explains a discrepancy this experiment could otherwise have called a
finding: this board reads **6.80 MHz** where the earlier work's three read 10.5
to 11.9 MHz. Same part, and a bigger difference than the one it called device
spread — because the two firmwares left the oscillator configured differently.

## The temperature, and how hard it was to get any

`−0.050% per degree`, over **6.94 °C**, and the drift at the widest point is
**−0.350%** — seven times the ±0.05% the counter and the sensor wander by when
nothing is happening. It is a real coefficient, measured, not asserted.

Getting 6.94 °C took three instruments. The first two are checked in as what
they are, because they are the reason the third one looks the way it does.

| transcript | ΔT | what it records |
| --- | ---: | --- |
| [`capture-self-heating.txt`](./capture-self-heating.txt) | 1.47 °C | **the board cannot heat itself.** A core spinning on a cheap loop is not a heat source; the first version's die *cooled* during its heating phase. Arithmetic plus flash reads at nearly full duty bought 1.47 °C |
| [`capture-finger.txt`](./capture-finger.txt) | 0.02 °C | **a fingertip is a heat sink.** The die idles at about 41 °C and skin is about 33 °C, so holding a finger on the chip cooled it 0.7 °C — the LED said hold, the temperature fell for exactly that minute, and it climbed back when the LED said let go |
| [`capture-cold-start.txt`](./capture-cold-start.txt) | **6.94 °C** | **the board's own warm-up is the sweep.** Unplugged, left to cool, plugged back in — and the first reading taken before the USB stack is built, because that is the only moment it is anywhere near the room |

The LED is why the finger transcript is readable at all: solid meant *hold*,
fast blink meant *let go*, and [exp171](../exp171-a-credential-nobody-asked-for/)
is where this repository learned not to ask a person to count seconds. The
answer that came back was "you are cooling it", which is a result rather than a
failure — but it is the same 0.02 °C either way.

## The 14% that was one count

The same earlier work reported the low-power oscillator at **28.00, 32.00 and
28.00 kHz** across its three boards — a "14.28% spread". Its frequency counter
ran at `FC0_INTERVAL = 8`, and the window is about `0.98 µs × 2^interval`, so
about **251 µs**. A 32 kHz clock fits about **eight periods** in that, which
makes the counter's resolution there about **4 kHz**.

**28.00 and 32.00 are one count apart.** This board, in the same second:

```text
  LPOSC at interval 8:  32.00 kHz   — an exact multiple of 4
  LPOSC at interval 15: 32.53 kHz   — a number that window cannot produce
```

The arithmetic was confirmed the hard way before it was written down: **this
experiment's own first run measured its own resolution and called it drift.**
Every ROSC reading came back a multiple of 4 kHz and the ±0.058% that looked
like temperature was one count at 6.8 MHz. Same trap, one step further down,
and it is why nothing but the deliberate reproduction uses the short interval
now.

## The instrument reports forever, and that is not tidiness

The first successful cold start scrolled its entire result past a host that was
not attached: eighty lines lost, including the boot reading that had cost
somebody a ten-minute wait. [exp157](../exp157-a-note-for-the-next-boot/)'s
README already says it — *a fact printed once is a fact most readers never
see* — and this firmware had printed its summary once.

So there is no phase here that ends. Every sample prints the whole comparison,
every fifteen seconds, forever. Whoever attaches gets the answer on the next
line rather than having had to be present for it.

## What this does not establish

- **One board.** The inter-device half needs the second one, which lives with a
  phone and is [never on this bench](../../docs/debugging-on-a-phone.md), and
  even then n = 2 against the earlier work's three. Nothing here measures
  uniqueness; it measures what else moves the number uniqueness was read from.
- **6.94 °C, not a temperature range.** A device in the world sees far more than
  that. The coefficient is extrapolated to twenty degrees for comparison and is
  a straight line drawn through one climb.
- **The absolute temperature is not to be trusted**, and exp108 says why — the
  sensor's constants are typical, not a calibration of this chip. Only the
  change is used.
- **Voltage is not swept.** The road names it beside temperature and it is
  software-controllable, and deliberately not touched: it needs over- or
  under-volting a board this repository cannot replace.
- **Nothing here says an RO-PUF cannot work on this chip.** The earlier work's
  own roadmap already proposes pairwise comparison and enrolment helper data,
  both of which are designed to survive exactly this. What is measured here is
  that the *static* reading it published is not a device signature.

## Running it

```console
cargo build --release
elf2flash convert -b rp2350 target/thumbv8m.main-none-eabihf/release/exp180-the-silicon-or-the-room target/exp180.uf2
yi26 flash target/exp180.uf2
yi26 log --seconds 30
```

For the temperature half: **unplug the board, leave it until it is cool, plug it
back in.** Nothing else is needed — no finger, no hairdryer, nothing to press.
The result repeats every fifteen seconds for as long as it is powered, so there
is no moment to catch.

```console
./check.sh
python3 verify.py capture-cold-start.txt
```

## Expected output

```text
PASS  python3 present
PASS  firmware compiles (213776 byte ELF)
PASS  the FC0 sources are the RP2350's numbers, named rather than written inline
PASS  every real measurement uses the long window
PASS  the earlier work's interval is kept only to reproduce its reading (3 mentions)
PASS  it sweeps FREQ_RANGE, which is the finding that needs no temperature
PASS  and puts the range back the way it found it
PASS  the LED has states, so nobody has to count seconds (exp171's lesson)
PASS  the first reading is taken before the USB stack, which is the only cold moment
      ruling on capture-self-heating.txt
PASS  the transcript carries all three usable ROSC ranges
PASS  one register field moves ROSC by 65.8% (5496.25 to 9111.90 kHz) — more than the 13.34% the earlier work called device uniqueness
PASS  LPOSC was measured at both intervals
PASS  at interval 8 it reads 32.00 kHz, an exact multiple of 4 kHz — one count
PASS  at interval 15 it reads 32.46 kHz, which that window could never produce
PASS  the crystal reads 12000.00 kHz — the counter is not the thing drifting
SKIP  no usable temperature sweep here — 1.47 C, against the 5.0 C this instrument needs before a drift would clear its own 0.05% noise. That is what this transcript records, not a gap in it.
      ruling on capture-finger.txt
PASS  the transcript carries all three usable ROSC ranges
PASS  one register field moves ROSC by 65.7% (5497.78 to 9111.28 kHz) — more than the 13.34% the earlier work called device uniqueness
PASS  LPOSC was measured at both intervals
PASS  at interval 8 it reads 32.00 kHz, an exact multiple of 4 kHz — one count
PASS  at interval 15 it reads 32.46 kHz, which that window could never produce
PASS  the crystal reads 12000.00 kHz — the counter is not the thing drifting
SKIP  no usable temperature sweep here — 0.02 C, against the 5.0 C this instrument needs before a drift would clear its own 0.05% noise. That is what this transcript records, not a gap in it.
      ruling on capture-cold-start.txt
PASS  the transcript carries all three usable ROSC ranges
PASS  one register field moves ROSC by 65.7% (5506.12 to 9122.87 kHz) — more than the 13.34% the earlier work called device uniqueness
PASS  LPOSC was measured at both intervals
PASS  at interval 8 it reads 32.00 kHz, an exact multiple of 4 kHz — one count
PASS  at interval 15 it reads 32.53 kHz, which that window could never produce
PASS  the crystal reads 12000.00 kHz — the counter is not the thing drifting
PASS  a temperature coefficient was computed
      ROSC moved 0.050% per degree over 6.94 C
PASS  twenty degrees of that is 1.00%, which is 13 times smaller than the 13.34% called device uniqueness — temperature is real here and does not explain that spread
PASS  at least the two transcripts that need no temperature are checked in
PASS  the cold-start transcript is here — the temperature half has a number
PASS  the README says which road this is on
PASS  the README carries both numbers — one register field against three boards
```

The three transcripts it rules on are checked in beside it. Two of them are
instruments that did not work, kept for that reason.
