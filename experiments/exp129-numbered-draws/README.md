# exp129-numbered-draws — a prize draw, and what about it can be checked

Send the range printed on the raffle tickets and get one number back:

```text
draw #1: 2418  in 2100-2567 (468 values)
  256 of 2^32 rejected to keep it unbiased
```

This is the first experiment here with a **use** rather than a demonstration —
a year-end party draw, employee numbers 2100 to 2567 — and the first where
somebody in the room has a reason to doubt the answer.

Needs: any RP2350 board, and the exp102 toolchain. No browser, and nobody in
the room: `yi26 send` is the whole host half.

## The subject is not randomness

Nobody watching a draw can tell the difference between a number from this
chip's TRNG, a number from `Math.random()`, and a number a rigged firmware
chose in advance.

That is not a guess. [exp112](../exp112-silent-fallback/) settled the hardest
of the three: a build that quietly stopped using the hardware RNG produced
output that passed **every** statistical test in this repository. Randomness is
not something an audience can verify, and a firmware that only promises "it is
random" is asking to be trusted rather than checked.

So this one is built around a different question. **What can be checked?**
Three things, and each of them is one mechanism.

## One — the mapping cannot be biased

The obvious way to turn a uniform `u32` into a ticket number is `2100 + x %
468`. It is wrong.

There are 2³² possible values of `x` and 2³² is not a multiple of 468. Splitting
them into 468 buckets leaves a remainder of **256**, so 256 of the tickets are
reachable from one more `x` than the rest — more likely by about one part in
nine million.

**Nobody will ever notice that.** Not at a party, not in a chi-square test on
ten million draws. Which is the argument for removing it rather than against: a
defect you cannot detect afterwards has to be designed out beforehand, because
there is no later opportunity.

[`crates/draw`](../../crates/draw/) rejects instead of folding, and its tests
count, for every possible result, how many of the 2³² inputs reach it. That is
uniformity established by **counting the whole space**, which no number of
draws on real hardware could ever do — and it is why this lives in a crate
that `cargo test` runs on any machine.

The firmware reports the count with every draw, and it is not always 256:

```text
draw #4: 48  in 1-256 (256 values)
  0 of 2^32 rejected to keep it unbiased
```

256 divides 2³² exactly, so nothing needs rejecting. The first version of the
crate got that case wrong — it rejected a whole 256 values that never needed
it. The draws would have been perfectly good and the number beside them a lie.
The tests caught it; no draw ever would have.

## Two — a failing source cannot emit

[exp114](../exp114-health-tests/)'s rule, applied: when a source fails, it
stops being used. Not flagged, not printed in red — stopped.

Every bit that could reach a result goes through the SP 800-90B continuous
tests **before** it is used. The order is the whole of it:

1. fetch a fixed block of random bytes,
2. push every bit of it through the health tests,
3. check whether they failed,
4. and only then run the draw over **those same bytes**.

So the bytes behind a number are the bytes that were tested — not a sample
taken nearby, and not a check performed on entropy that was already spent. If
the tests fail the number has still been computed; it is simply never said out
loud, and the failure is permanent.

The warm-up at boot exists for the same reason. The adaptive proportion test
has a 1024-sample window and says nothing until one has closed, so a draw made
before then would be gated by a test that had not yet had the chance to fail.
**A gate that cannot fail is not a gate** — this repository's phrase for it is
that a check which cannot fail is reassurance.

## Three — a discarded draw is visible

This is the failure a real prize draw actually has, and it is not
cryptographic: **the operator can press again until they like the number.**

Nothing here prevents that, and nothing pretends to. What the sequence number
does is make it impossible to conceal. Draw five times and announce the fifth,
and the line beside the winning number says `#5`, where everyone looking at the
same screen can see it.

It is worth being precise about what that mechanism is. It is **not
cryptography. It is a counter somebody can read.** A commit-and-reveal scheme
would be stronger on paper and worse here, because nobody at a party can verify
a hash — it would move the checking away from the people in the room, which is
the opposite of what this needs.

## What this cannot tell you

It cannot tell you the draw was fair. One board and a few thousand samples
cannot certify a source; [exp111](../exp111-measuring-randomness/) drew that
line and it has not moved.

What is claimed is **mechanism**: unbiased by construction, gated by tests with
stated cutoffs, accountable by counter. Whether the chip's TRNG is any good is
a question for the chip's documentation and for exp109 through exp114, not for
this experiment. `check.sh` says so on every run rather than letting fifteen
green PASS lines imply otherwise.

## The command is exp128's message

`2100-2567` is nine bytes on the OUT endpoint, reassembled by the loop
[exp128](../exp128-reassemble-by-hand/) built. It is the first thing in this
repository that needed a message rather than a byte, which is what exp128 was
for.

The parser is deliberately strict. `2100 - 2567` with spaces, or a trailing
newline a terminal added, are refused and quoted back rather than interpreted:

```text
not a range: "hello"
  send lo-hi, digits and one dash: 2100-2567
```

A prize draw is a bad place for a parser that guesses, because the cost of
being wrong is a number nobody can account for.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — the fetch/test/draw order, and the parser
  that refuses.
- [`crates/draw`](../../crates/draw/) — the rejection, and the tests that count
  preimages over 2³².

## Two ways to do it

```sh
./run.sh      # guided: draw, then work through what an audience can check
./check.sh    # verdict: draws and checks the number is inside the range
```

## Expected output

Captured from a Pico 2. `yi26 log --seconds 8` straight after flashing:

```text
[      37 ms] exp129 up. Send a range, like  2100-2567
[     100 ms] warmed up: 2048 bits through the health tests
[     150 ms] control: 8000 baud, DTR off
[     264 ms] control: 8000 baud, DTR off
[     395 ms] control: 9600 baud, DTR off
[     414 ms] control: 9600 baud, DTR on
[     414 ms] control: 115200 baud, DTR on
[     414 ms] control: 115200 baud, DTR off
[     419 ms] control: 115200 baud, DTR on
[    5037 ms] idle: no draws yet — try  yi26 send '2100-2567'
```

Two thousand bits through the health tests in 63 ms, before the first draw is
allowed.

Three draws, `yi26 send '2100-2567'`:

```text
[   15761 ms] draw #1: 2418  in 2100-2567 (468 values)
[   15761 ms]   256 of 2^32 rejected to keep it unbiased
[   17790 ms] draw #2: 2125  in 2100-2567 (468 values)
[   17790 ms]   256 of 2^32 rejected to keep it unbiased
[   19896 ms] draw #3: 2484  in 2100-2567 (468 values)
[   19896 ms]   256 of 2^32 rejected to keep it unbiased
[   20037 ms] idle: 3 draws, 0 refused, 3584 bits tested
```

Refusals, and the two ranges that reject nothing:

```text
[   34101 ms] not a range: "hello"
[   34101 ms]   send lo-hi, digits and one dash: 2100-2567
[   36249 ms] 2567-2100 is empty — lo must not be above hi
[   38372 ms] draw #4: 48  in 1-256 (256 values)
[   38372 ms]   0 of 2^32 rejected to keep it unbiased
[   40466 ms] draw #5: 7  in 7-7 (1 values)
[   40466 ms]   0 of 2^32 rejected to keep it unbiased
```

`./check.sh` against that board:

```text
PASS  toolchain present (cargo, elf2flash)
PASS  the draw crate's tests pass, including the preimage count over 2^32
PASS  compiles (147996 byte ELF)
PASS  converts to UF2 (50176 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  auto-reboot is compiled in (the board can still be reflashed)
PASS  the health tests still gate the draw (HEALTH_FAILED, health.push)
PASS  board is running exp129
PASS  a draw came back (draw #8: 2467  in 2100-2567)
PASS  the drawn number 2467 is inside 2100-2567
PASS  the firmware reports 256 rejected values for a 468-wide range
PASS  a power-of-two range rejects nothing
PASS  draw numbers advance (8 then 9) — a discarded draw leaves a gap
PASS  a command that is not a range is refused and quoted back
PASS  a reversed range is refused rather than silently swapped
NOTE  none of this shows the draw was fair — see exp111. What is checked
      is that the mapping cannot be biased, that a failing source cannot
      emit, and that a discarded draw leaves a visible gap.
```

The 1200-baud reboot still works: `yi26 bootsel` put the board in BOOTSEL and
`yi26 flash` brought it back, with no hand on a button.

## What the log is telling you

- **`warmed up: 2048 bits`.** Two windows, so the first is complete and the
  second under way. Before that line, no draw is possible.
- **The rejection count on every draw.** It is the one number that would change
  if somebody swapped the mapping for `% n`, and it is printed where an
  operator sees it rather than buried in a header.
- **`3584 bits tested` after three draws.** 2048 from the warm-up plus 512 per
  draw — every bit that could have reached a number.
- **The sequence number.** The only thing on the screen that a redraw cannot
  hide behind.

## Make it yours

1. Draw the same range a few hundred times and count the results. You will
   find nothing, which is the point — exp111 explains why that is not evidence
   of anything.
2. Replace `draw::in_range` with `lo + x % n` and run `check.sh`. Every draw
   still lands in range; only the reported rejection count moves. That is how
   invisible the defect is.
3. Delete the warm-up loop. The first draw now happens before the adaptive test
   could have failed, and nothing anywhere says so.
4. Add a command that prints every draw so far. The sequence numbers are
   already there; making the whole history readable is what turns "you can see
   a gap" into "you can audit the evening".

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `not a range` for something that looks like one | A space, or a newline your terminal added | `yi26 send` adds no newline; check for spaces |
| The draw numbers restart at 1 | The board reset — they are not persistent | Expected; a reset is visible as the count going backwards |
| `refused: the health tests have failed` | The TRNG failed a continuous test | Real if it persists across a reset. Report it — and see exp114 |
| No `draw #` line at all | The message did not end — see exp128 | Send a command shorter than 64 bytes |

## Next

**exp130** — the same draw with the page coming off the board itself, opened on
a phone plugged into it. That is the form this is actually for, and it changes
the security picture rather than just the presentation: a browser, a page and a
screen now sit between the TRNG and the room, so the number an audience reads
is a *claim about* what the device said rather than the thing the device said.
The log is what makes the two independently checkable.

The rest of the road is under [Planned](../README.md#planned).
