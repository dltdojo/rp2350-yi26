# vk26-alice-3 — the count the estimate rests on

<!-- SPDX-License-Identifier: Apache-2.0 -->

**SP 800-90B's most common value estimate (§6.3.1) rests on one number: how
many times the commonest value occurs. A 29-instruction RV32IM kernel counts
4096 byte samples into 256 bins and finds the largest count, proved in Lean
for every input (`Count.from_boot`):
- it halts with 0 after exactly 6,294,284 instructions, whatever the samples;
- memory is then the image with the 256 counts as words from 0x1400, the
  largest at 0x1800, and nothing else;
- that largest is the commonest value's count (`most_is_max`), and the
  counts add up to 4096 (`hist_sum`).

It counts in a way the samples cannot steer. For each value it reads every
sample and adds `(sample xor value) <u 1`, then takes the max without a
branch. lean/Rv32/Ct.lean's checker accepts it as written: two images that
differ only in their samples run in lock step, with the same pc, the same
addresses and the same end at every step (`count_constant_time`). The
checker refuses the plain histogram, `counts[sample] += 1`
(`naive_refused`).

On the RTL the kernel takes 7,343,633 cycles on all 12 streams of the
differential and all 5 of the shell. The shell's TRNG streams come both
with the TRNG's own tests on and with them bypassed. The estimate itself
needs a square root and a logarithm: it is on the page, not in the proof.
On a Pico 2, read on a phone through the page: the LED blinked as it should,
and all 13 whole streams in the saved log were counted right at the RTL's
minstret. The prediction that every stream would take one `mcycle` did not
hold: three numbers, 64, 164 and 184 cycles over the RTL's, and the same
fixed samples took different ones in different rounds. The raw TRNG's bits
were 1 about 48.3% of the time in both draws, about six standard deviations
from even; with its tests on, about 50%. Revision 2 runs every stream's
kernel twice, back to back, and reports both `mcycle`s, to tell what the
shell left behind from anything else. It has not run on a board yet.**

This is the third experiment of [alice's trial proposal](../README.md) for
the vk26 call.

## Why the count

[exp114](../../../../experiments/exp114-health-tests/) set its health tests'
cutoffs from an *assumed* min-entropy of one bit a sample. Its crate says so:
"SP 800-90B expects this to come from an entropy assessment of the specific
noise source. This is not that assessment."
[exp222](../../../../experiments/exp222-the-bits-the-kernel-withholds/) says
the same: "SP 800-90B's entropy assessment is not here."

§6.3.1 is the simplest estimator of that assessment, in three steps:

1. p̂ = the proportion of the most common value in the dataset;
2. p_u = min(1, p̂ + 2.576 √(p̂(1 − p̂)/(L − 1)));
3. H = −log2 p_u bits a sample.

Steps 2 and 3 need a square root and a logarithm, which this repository's
Lean has no proved RV32IM code for. Step 1 is a count. So this experiment
proves the part that can be proved, the count, and leaves the formula where
it can be checked against another implementation: in [`count.py`](./count.py)
and on the page. That boundary is stated, not hidden. It is also what this
trial wants to show J1: a claim with a proved half and an unproved half.

§6.3.1's own example (L = 20, p̂ = 0.4) gives p_u = 0.6895 and then writes
"log2(0.6822)". 0.6895 is right, and H = 0.5363 as the text says. count.py
and the page are both tested on it.

## Which samples

The repository's TRNG driver ([`tools/hazard3/shell/trng.h`](../../../../tools/hazard3/shell/trng.h))
leaves the TRNG's own tests on, as embassy-rp does: the von Neumann balancer,
the CRNGT and the autocorrelation test. Its words are the balancer's output.
SP 800-90B estimates entropy on raw data: "The output of the digitized noise
source is called the raw data." An estimate after the balancer measures the
balancer, whose output is close to even by design whatever the source behind
it does.

So the shell draws both kinds each round:

- **the TRNG, its tests on** — `board_trng`, as alice-1 and alice-2 do;
- **the TRNG, raw** — [`../shell/trng_raw.h`](../shell/trng_raw.h)'s
  `board_trng_raw`, which sets TRNG_DEBUG_CONTROL bits 1 to 3 (rp-pac
  7.0.0: `vnc_bypass`, `trng_crngt_bypass`, `auto_correlate_bypass`). No
  experiment here has done this before, so how the raw bits look on this
  board is what the board run will show.

A sample here is a byte: eight consecutive TRNG bits. The TRNG is a binary
source, and for a binary source 90B's sample is one bit. The page also gives
the estimate with each byte's eight bits as samples of their own (k = 2).
Neither is an assessment: §3.1.1 asks for "at least 1 000 000 sample values
obtained directly from the noise source", and this is 4096 bytes.

## The kernel

`proof/Count.lean` writes it; `kernel.bin` is its 116 bytes.

| Instructions | What |
| --- | --- |
| 0 | `s0` = base |
| 1–7 | `s1` = base + 0x400 (the samples), `t1` = 4096 (`lui`), `s2` = `s1` + 4096 (their end, and the counts), `s3` = `s2`, `s4` = 0 (the value), `s5` = 0 (the most), `s7` = 256 |
| 8–9 | BIN: `a0` = `s1`, `s6` = 0 |
| 10–15 | LOOP: `t1` = byte at `a0`; `t1` = (`t1` xor `s4`) <u 1; `s6` += `t1`; `a0` += 1; `bne a0, s2` → LOOP |
| 16 | the count to `s3` |
| 17–21 | `s5` = max(`s5`, `s6`) without a branch: mask = −(`s5` <u `s6`); `s5` ^= (`s6` ^ `s5`) & mask |
| 22–24 | `s3` += 4; `s4` += 1; `bne s4, s7` → BIN |
| 25 | the most to base + 0x1800 |
| 26–28 | HALT 0 |

That is 8 + 256 × (2 + 6 × 4096 + 9) + 4 = 6,294,284 instructions. A plain
histogram, eight instructions a sample, is about 33,000. The extra 190 times
buys a trace no sample moves.
The kernel needs no HASH. 4096 is `lui t1, 1`, not `addi` and `slli`: the
checker knows a `lui`'s value but only that a shift's is public, and it
needs the counts' place as a number to accept a store there.

## What is proved

`Count.from_boot`: placed at any `base` the model allows, with the image's
first 116 bytes the kernel's,

```lean
(∃ s1, run env (COST - 1) (boot env.region img) = .running s1) ∧
∃ s', run env COST (boot env.region img) = .halted 0 s' ∧ s'.mem = after (memOfImage base img) base
```

- sample `i` is the byte at 0x400 + i; `cnt b n` is how many of the first
  `n` are `b`, and `hist b` is `cnt b 4096`;
- `most` is the largest of `hist 0` … `hist 255`;
- `after` is memory with `hist b` written as a word at 0x1400 + 4b for every
  `b`, and `most` at 0x1800.

Under it, in order:

| Theorem | What it says |
| --- | --- |
| `look_iter`, `look_loop` | one value's count: six instructions a sample, 4096 by induction; memory untouched, every register but `t1`, `s6`, `a0` kept |
| `maxLine_regs`, `max_word` | the five instructions leave `max(s5, s6)` in `s5`, for any two counts |
| `bin_iter`, `bin_loop` | one value: its count written, the largest so far kept; 256 by induction |
| `setup_run`, `fin_run` | the 8 instructions before, the 4 after |
| `from_boot` | the whole kernel, as above |
| `most_is_max` | no value is counted more often than `most`, and some value exactly that often |
| `hist_sum` | the 256 counts add up to 4096 |
| `accepted`, `count_constant_time` | the checker accepts the kernel with only the program public; so any two images that differ only outside it run in lock step |
| `naive_refused` | the checker refuses `counts[sample] += 1`: its load and store go to an address made from a sample |

Each rests on Lean's own axioms only (`#print axioms`, in
[capture.txt](./capture.txt)).

[`proof/mutants.txt`](./proof/mutants.txt) holds twelve wrong versions, each
refused in the theorem its label names:
- **Eight are wrong kernels:**
  - `lb` for `lbu`, so the values 128 to 255 count as others;
  - `<u 2` for `<u 1`, so a value one more is counted too;
  - a pointer that advances by the comparison, an address made from a sample;
  - a max whose mask is 1;
  - counts starting at 1;
  - counts written 8 bytes apart;
  - 255 values;
  - the most stored a word late.
- **Four are wrong claims:**
  - one instruction fewer;
  - the most of only 255 counts;
  - a value's count including the samples below it;
  - a head that says the value stops at 254, which the checker refuses.

## The reference, and the differential

[`count.py`](./count.py) is §6.3.1 from its text. Its `count_streams()` are
12 streams of 4096 bytes:
- each value 16 times, shuffled and in order;
- all 0 and all 255;
- 0xa5 at 1000 places;
- 7 and 200 tied at 300;
- 0 or 255 once more than the rest;
- two random;
- bytes whose bits are 1 three times in four;
- the RTL's stand-in TRNG.

[`differential/differential.py`](./differential/differential.py) runs
`kernel.bin` on all 12, on the Lean model and the RTL, four at a time.
- Both halt with 0, the model after `COST`.
- Each region is the image with count.py's 256 counts and largest, and
  nothing else.
- The RTL takes 7,343,633 cycles on every one.

The RTL counts 6,294,287 instructions, the proof's count plus 3.
- alice-1 and alice-2 counted plus 3 plus 4 for each HASH call, and one
  more whenever the halting `ecall` was not the kernel's last instruction.
- Here there is no HASH, the `ecall` is last, and there is no one more.
- That is ten counts across three experiments on one pattern. The pattern
  is now this experiment's prediction for the chip, and still not an
  explanation.

## The shell

[`shell/shell.c`](./shell/shell.c) runs five streams a round:
- the TRNG with its tests on, 1024 words;
- the TRNG raw, 1024 words;
- three of count.py's streams, compiled in by [`gen.py`](./gen.py): each
  value 16 times, 0xa5 at 1000 places, and bits 1 three times in four.

Sample i is byte i % 4 of word i / 4. From revision 2 the kernel runs
twice on each stream: when the first run halts, the shell records it and
enters the kernel again at once, on the same region. Between the two runs
there is only the trap's way into `handle()` and back out through
`enter_payload`. Then, for both runs, it checks
([`board.h`](./shell/board.h) numbers them):

1. the kernel's bytes were `kernel.sha256`'s;
2. it halted with 0, by HALT;
3. minstret is the RTL's 6,294,287;
4. each of the 256 counts is the shell's own count of the samples, the most
   is the largest of them (and gen.py's, for a fixed stream), and with those
   cleared the region hashes as it did before.

And 10: a TRNG gave nothing.

`mcycle` is sent for both runs, not checked. On the RTL it is 7,343,633
for all ten runs.
[exp212](../../../../experiments/exp212-the-cycles-the-chip-counts/) ran
proved kernels on a Pico 2 and found two things:
- "sixteen seeds of the key generator and sixteen of the signer take the
  same `mcycle` on silicon, to the cycle";
- the first timed run after boot was out of line, and silicon's numbers
  are not the RTL's.

So the page compares the streams with each other, the first after boot
aside.

Wrong shells are caught by the check they name:
- 1: the kernel's hash changed;
- 2: the kernel calling HASH instead of halting;
- 3: one more instruction asked for;
- 4: gen.py's largest off by one;
- 4: the samples a word late;
- 4: the most left in the region;
- 2: no second run, so the first run's halt is never recorded;
- a fault: the shell trapping itself;
- 10: the TRNG giving nothing.

### The lines

```
BITS round s k w0 … w15          64 a stream: the 1024 words
HIST round s k c0 … c15          16 a stream: the kernel's counts
AGAIN round s minstret mcycle    revision 2: the second run
STREAM round s most want minstret mcycle name    the first run's
ROUND round streams
```

### The LED

After each stream, one long light, then 2 s dark: a healthy round is five.
speak.h's own codes as before: N flashes and 3 s dark is a USB stage; 2 s
of light first is an error, its count the check that failed.

## The page

[`count.html`](./count.html) counts every stream again from its BITS lines
and holds each of the kernel's 256 counts, and the most, to its own.
- **The two TRNG draws:** it draws them as histograms, and gives §6.3.1's H
  per byte and per bit for every stream.
- **The cycles:** it compares every stream's mcycle, the first after boot
  aside, and says whether they are one number. From revision 2 (page build
  p2) it does the same, separately, for the second runs. A revision 1 log,
  with no AGAIN lines, still reads as before.
- **The tests:** [`page_test.mjs`](./page_test.mjs) holds its count and both
  estimates to count.py's on all 12 streams, and to §6.3.1's own example.
  It runs it on [`fixtures.py`](./fixtures.py)'s logs:
  - two good rounds;
  - one count one short;
  - a most that is not the largest;
  - minstret off;
  - one stream 4 cycles slower (no count wrong, the cycles differ);
  - one second run 20 cycles slower (the first runs one number, the
    second runs two);
  - a second run's minstret off;
  - revision 1's lines, with no second runs;
  - a BITS line and a HIST line lost;
  - a page that joins mid-stream.
- **Wrong pages:** nine, made from the built page, are caught.
  - A byte order reversed within each word is *not* one of them. It leaves
    every count the same, so no test can or should catch it.
- [`../pages/browser.mjs`](../pages/browser.mjs) runs the built page in
  headless Chromium against a stand-in board.

## Running it on a board, from a phone

Needs a Pico 2 and an Android phone with Chrome; one BOOTSEL press.

1. Hold BOOTSEL, plug the Pico 2 into the phone, drop
   `build/vk26-alice-3.uf2` on the drive that appears.
2. Watch the LED: five long lights a round, a little over half a minute
   each round.
3. Open `build/count.html` from the Files app with Chrome, press Connect and
   choose "vk26-alice-3". Wait for two ROUND lines, then press Save and send
   the file back as an attachment; it goes into `board/` as it is.

What the run will say, stated before it happens (what it said is in *On
the board*, next):
- every count right, as on the RTL;
- every stream after the first one mcycle, as exp212 found for its kernels;
- for the TRNG with its tests on, an H per byte near the random streams'
  6.7.
- **For the raw TRNG nothing is predicted:** that is the question.

## On the board

[`board/round1.txt`](./board/round1.txt): a Pico 2 running revision 1's
`vk26-alice-3.uf2` (`ab367127…6442293a6`, committed in 8b40ce7), the page on a
phone, the file Save gave back, kept as it came. The LED blinked as
described ("LED 如預期閃"): a long light per stream.

The page, as it saved: 13 streams, 13 judged right, 0 wrong, 0 incomplete,
3 rounds, no FAIL line, and three cycle values. The log starts at round 2's
fourth stream and ends after round 5's first; every stream in it is whole.
By `fixtures.py --board` (count.py) and by the page's block under node:

| Round:stream | Stream | Most | H a byte | H a bit | Ones | mcycle − RTL |
| --- | --- | --- | --- | --- | --- | --- |
| 2:3, 3:3, 4:3 | 0xa5 at 1000 places | 1012 | 1.919 | 0.974 | 0.4981 | +64, +64, +64 |
| 2:4, 3:4, 4:4 | bits 1 three times in four | 440 | 3.060 | 0.400 | 0.7516 | +164, +64, +184 |
| 3:0 | the TRNG, its tests on | 31 | 6.499 | 0.967 | 0.4954 | +64 |
| 3:1 | the TRNG, raw | 28 | 6.622 | 0.930 | 0.4823 | +64 |
| 3:2, 4:2 | each value 16 times | 16 | 7.284 | 0.980 | 0.5000 | +184, +184 |
| 4:0 | the TRNG, its tests on | 26 | 6.711 | 0.980 | 0.5000 | +64 |
| 4:1 | the TRNG, raw | 29 | 6.580 | 0.935 | 0.4841 | +64 |
| 5:0 | the TRNG, its tests on | 30 | 6.539 | 0.962 | 0.5061 | +64 |

The RTL took 7,343,633 cycles on every stream; the chip took 7,343,697,
7,343,797 or 7,343,817.

What it adds to the RTL:

- **The count holds on the chip.** All 13 streams' 256 counts and largest
  are count.py's, at the RTL's minstret, 6,294,287. The three fixed streams
  gave gen.py's largest every time.
- **The cycle prediction failed, and the samples are not why.** The
  prediction, stated before the run, was one `mcycle` for every stream
  after the first. The chip gave three. "Bits 1 three times in four" is
  the same 4096 bytes in every round, and it took +164, +64 and +184. So
  the difference is not a function of the samples, which is what
  `count_constant_time` says it cannot be. It is something outside the
  kernel's trace that changed between rounds.
- **What fits, from prior work, not shown here.** exp212 wrote down that
  the counted window includes the harness's `mret` and its trap entry, and
  on the chip they are fetched from flash through the XIP cache
  ([`link_chip.ld`](../../../../tools/hazard3/shell/link_chip.ld) puts
  `.text.harness` in flash). Whether that line is cached depends on what
  the shell ran before, which differs between streams: the TRNG's driver,
  the raw driver, the copy of a fixed stream, USB status lines. exp212's
  shell did the same thing before every timed run; this one does not. The
  explanation fits every number here, and nothing here singles it out.
- **The raw TRNG leans to 0.** Its bits were 1 in 48.23% and 48.41% of
  32,768: 6.4 and 5.8 standard deviations below even, if the bits were
  independent. Its per-bit MCV estimate was 0.930 and 0.935, against 0.962
  to 0.980 with the tests on. The balancer's output was 49.54%, 50.00% and
  50.61%. Per byte, all five TRNG draws look alike (6.50 to 6.71): 4096
  bytes cannot see a lean of this size, and a bit can.

## Revision 2: every kernel run twice

To tell the cache from anything else, revision 2 runs each stream's kernel
twice back to back on the same samples and reports both `mcycle`s. That is
exp212's warm-up, applied to every stream. Nothing else changed: the
kernel, the checks, the streams and the LED are revision 1's. The first
run follows the shell's preparation exactly as revision 1's did. The
second follows only the first run's trap and the way back in.

What revision 2's run will say, stated before it happens:
- every count right, both runs at the RTL's minstret, as in revision 1;
- **every second run one `mcycle`**, in every round and on every stream,
  round 0's first included, and no more than revision 1's smallest,
  7,343,697;
- the first runs are not predicted: they repeat revision 1's measurement.

If the second runs move too, then what the shell ran before the timed
window is not the explanation, and neither is the harness's trap entry in
the XIP cache.

## What it does not say

- Why the chip's `mcycle` moved. The proof rules out the samples; the
  board shows identical samples moving; what moves it is a hypothesis.
- That the raw TRNG is biased in general: two draws of 32,768 bits on one
  board, at the shared driver's settings.
- The estimate's formula is not proved: count.py and the page agree on it,
  and on §6.3.1's example, which is two implementations, not a proof.
- 4096 samples are not an assessment (§3.1.1), and a byte is not this
  binary source's sample.
- Constant time is about this core's view: no caches, no data-dependent
  latency. The proof says the samples cannot move the trace; the RTL and
  the board measure the time.
- The one instruction alice-1 and alice-2 counted more is not explained;
  here it is predicted absent, and the RTL agrees.

## What the trial found in the call's settings

Found while making this experiment, and recorded in
[alice's README](../README.md#五預期會測到的徵集設定問題):

- **The raw TRNG had nowhere shared to go.** The shared driver has no way
  to bypass the TRNG's tests, and S2 keeps a proposal out of `tools/`. So
  `trng_raw.h` lives in alice's own `shell/`, and reuses `trng.h`'s
  configuration and block reader rather than copying them.
- **`duplication.sh` counts by name.** `image` was already copied across
  nine experiments, and this one's is `count_image`.
- **The Lean library's Ct checker knows a `lui`'s value, not a shift's**,
  and `lean.sh check` shows only an error's first line. Both, with a timeout
  over `List.range 256`, are now in the call README's Lean table (in a
  commit of its own).

## Running it

```sh
./check.sh     # everything that needs no board, about seven minutes
./run.sh       # the same, recorded to capture.txt
./build.sh     # build/vk26-alice-3.uf2 and build/sim.bin
python3 ../pages/build.py count.html build/count.html   # the page, as one file
```

## Expected output

[capture.txt](./capture.txt), recorded by `run.sh` from a clean commit.

Pasted from it — the theorems, the mutants, the five streams on the RTL:

```
=== vk26-alice-3 — the count the estimate rests on ===
recorded at 2026-10-14T02:30:24Z from commit 59ee475

>>> the theorems, and what they rest on
'Count.look_loop' depends on axioms: [propext, Classical.choice, Quot.sound]
'Count.bin_loop' depends on axioms: [propext, Classical.choice, Quot.sound]
'Count.from_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
'Count.most_is_max' depends on axioms: [propext, Quot.sound]
'Count.hist_sum' depends on axioms: [propext, Classical.choice, Quot.sound]
'Count.accepted' depends on axioms: [propext, Quot.sound]
'Count.naive_refused' depends on axioms: [propext, Quot.sound]
'Count.count_constant_time' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
look_iter     a sample is loaded sign-extended (lb), so the values 128 to 255 are counted as others   refused in look_iter
tally_regs    a sample one more than the value is counted as the value too (<u 2, not 1)              refused in tally_regs
tally_regs    the pointer advances by the comparison, an address made from a sample                   refused in tally_regs
maxLine_regs  the max's mask is 1, not all ones                                                       refused in maxLine_regs
bin_iter      each count starts at 1                                                                  refused in bin_iter
bin_iter      the counts are written 8 bytes apart, every other one over the next                     refused in bin_iter
setup_run     the values stop at 255                                                                  refused in setup_run
fin_run       the largest count is written a word late                                                refused in fin_run
from_boot     the claim: one instruction fewer to the halt                                            refused in from_boot
fin_run       the claim: the most is the largest of the first 255 counts                              refused in fin_run
cnt_succ      the specification: a value's count includes the samples below it                        refused in cnt_succ
accepted      the claim: at both heads the value is at most 254                                       refused in accepted
...
>>> count.py's streams, their counts and estimates, and §6.3.1's example
§6.3.1's example: p̂ 0.4000  p_u 0.6895  H 0.5363
...
>>> on the RTL, every stream twice: STRM s most want minstret mcycle, the second run's minstret mcycle, then DONE streams
5354524d 00000000 0000001a ffffffff 00600b0f 00700e11 00600b0f 00700e11
5354524d 00000001 0000001a ffffffff 00600b0f 00700e11 00600b0f 00700e11
5354524d 00000002 00000010 00000010 00600b0f 00700e11 00600b0f 00700e11
5354524d 00000003 000003f4 000003f4 00600b0f 00700e11 00600b0f 00700e11
5354524d 00000004 000001b8 000001b8 00600b0f 00700e11 00600b0f 00700e11 444f4e45 00000005 exit=0 
```

the time, among 87 PASS, 0 FAIL and 0 SKIP:

```
PASS  the RTL takes the same time on all 12 streams: cycles=7343633
PASS  on the RTL the shell runs all five streams twice, every count the shell's own, minstret the RTL's, and one mcycle for all ten runs
PASS  §6.3.1's own example, p̂ 0.4 of 20: p_u 0.6895, H 0.5363
PASS  one stream taking 4 cycles more: no count is wrong, and the page says the cycles differ
PASS  cycles.txt: the verdict line says "the cycles differ"
```

and the phone's log, by the page and by count.py:

```
PASS  round1.txt: 13 of 13 streams from a board counted right, 0 incomplete, 3 rounds; the page reads 13 timed streams as 7343697/7343797/7343817 cycles
PASS  round1.txt: 13 whole streams from a board, each of the 256 counts and the largest as count.py gives them, minstret the RTL's
      mcycle, round:stream: 7343697 at 2:3 3:0 3:1 3:3 3:4 4:0 4:1 4:3 5:0; 7343797 at 2:4; 7343817 at 3:2 4:2 4:4
      the TRNG, its tests on: H per byte 6.499 (0.967 a bit), 6.711 (0.980 a bit), 6.539 (0.962 a bit)
      the TRNG, raw: H per byte 6.622 (0.930 a bit), 6.580 (0.935 a bit)
```
