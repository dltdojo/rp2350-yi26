# vk26-alice-1 — the run across the seam

<!-- SPDX-License-Identifier: Apache-2.0 -->

**SP 800-90B's repetition count and adaptive proportion tests over four
windows of 1024 samples, the way the standard and exp114's crate run them:
the repetition count goes on across every window's edge. Each window that
passes is handed to `HASH`, and its 32-byte digest is written. The first
window that fails stops everything. A 138-instruction RV32IM kernel, proved
in Lean for every input (`Seam.from_boot`):
- it halts after exactly `cost (stop …)` instructions — 17431 + 17421·k if
  window k + 1 is the first to fail, 69699 if none does — with 0 if all four
  windows pass, else the failing window's number, 1 to 4;
- the region is then the image with one digest for each window before the
  stop, `HASH` of that window's 4096 bytes at 0x4400 + 32w, and not one byte
  else; one instruction earlier it is still running.

So 11 ones at the end of one window and 10 at the start of the next are a
run of 21, and stop the kernel at the second window, where
`lean/Rv32/Health.lean`'s `front`, applied window by window, passes both.
On the RTL the shell runs six streams, the run across the seam among them,
each halting with the reference's code and the RTL's count for it. On a
Pico 2, read on a phone through the page: the LED blinked as it should, and
all seven whole streams in the log — the TRNG's among them — halted with
seam.py's code at the RTL's minstret, each digest hashlib's SHA-256 of its
window; the seam stream stopped at window 2.**

This is the first experiment of [alice's trial proposal](../README.md) for
the vk26 call: a real proposal, made before the call is announced, to find
what in the call's settings does not work.

## Why the seam

SP 800-90B §4.4.1 counts a run of identical samples over the whole stream.
[exp114](../../../../experiments/exp114-health-tests/)'s crate
([`crates/entropy-health`](../../../../crates/entropy-health/)) does the
same: its `run` is never reset at a window's edge. The repository's proved
block, [`front`](../../../../lean/Rv32/Health.lean), judges one window and
starts afresh: its setup sets the last sample to 2 ("none yet") and the run
to 0. [exp222](../../../../experiments/exp222-the-bits-the-kernel-withholds/)
and [exp223](../../../../experiments/exp223-the-digest-the-kernel-withholds/)
judge one window, so for them the two agree. Over several windows they do
not, and the samples on either side of an edge are exactly where a stuck
source can hide.

The adaptive proportion test is per window in both: each window's first
sample is its reference, and its count starts at 0.

## The kernel

`proof/Seam.lean` writes it; `kernel.bin` is its 552 bytes.

| Instructions | What |
| --- | --- |
| 0–11 | `s1` = base + 0x400 (the samples), `a2` = base + 0x4400 (the first digest), `a1` = 4096 and `t0` = 0 (HASH's length and call), `s4` = 2 (no sample yet), `s5` = 0 (the run), `s6` = 0 (nothing failed), `s2` = 0 (windows passed) |
| 12 + 30w | window w: [`Alice.Window.win`](../lean/Alice/Window.lean) — the reference, the two counts, 1024 samples, the verdict in `s6` |
| 36 + 30w | `bne s6, x0` → FAIL |
| 37 + 30w | `a0` = `s1` − 4096; `HASH`; `a2` += 32; `s2` += 1 |
| 132 | HALT 0 |
| 135 | FAIL: HALT `s2` + 1 |

`win` is `front` with a different setup: four instructions that take the
window's reference and zero the adaptive proportion's count and the sample
counter, and touch nothing else. The 17-instruction loop and the
3-instruction verdict are `Health.health` and `Health.verdictLine`,
unchanged. The last sample, the run and the failure flag stay in `s4`, `s5`
and `s6` from one window to the next. It lives in alice's own Lake package,
[`../lean/Alice/Window.lean`](../lean/Alice/Window.lean), because the call
does not let a proposal change `lean/` (the call's README, §4).

The counts: 24 instructions of block a window, 4 + 17·1024 + 3 = 17415; then
the branch; then 5 more if it passed (17421 in all) or the 3 of FAIL if it
did not. The setup is 12 and the end 3.

## What is proved

`Seam.from_boot`: placed at any `base` the model allows, with the image's
first 552 bytes the kernel's,

```lean
(∃ s1, run env (cost (stop (memOfImage base img) base) - 1) (boot env.region img) = .running s1) ∧
∃ s', run env (cost (stop (memOfImage base img) base)) (boot env.region img)
    = .halted (code (memOfImage base img) base) s'
  ∧ s'.mem = wrote env.hash (memOfImage base img) base (stop (memOfImage base img) base)
```

- `stop m base` is the first window `w` of 0 to 3 for which `WinOk` fails,
  or 4. `WinOk m base src w` says no run of 21 alike from the stream's first
  sample to window `w`'s last (`Health.rct` over the stream, not the
  window), and fewer than 589 of window `w`'s samples equal its first
  (`Health.agree` over the window).
- `code` is 0 when `stop` is 4, else `stop + 1`.
- `wrote H m base k` is `m` with `H (windowBytes m base j)` written at
  0x4400 + 32j for each `j < k`, and nothing else.

`env.hash` is any function from bytes to 32 bytes: the theorem holds
whatever `HASH` computes. That it is SHA-256 on the chip is the shell's and
the page's to check against hashlib and WebCrypto, not the proof's
(decision 3 of [alice's plan](../README.md#四討論的結果)).

Under it, in order:

| Theorem | What it says |
| --- | --- |
| `Alice.Window.win_run` | the block, from its top: `4 + 17·1024 + 3` instructions, `s6` = 0 iff `WinOk`, and when it holds, `s4` and `s5` are `rct`'s last sample and run at the window's end; memory untouched, every register outside `Health.written` kept |
| `setup_run` | 12 instructions from the boot state to window 0's top, `Entry` holding |
| `window_head` | the block, read through `Entry`: the digests written so far do not touch a sample |
| `window_pass` | a window that passes: 17421 instructions, its digest written, `Entry` at the next window |
| `window_fail` | a window that fails: 17418 running, then the halt with the window's number; nothing written since it began |
| `all_pass` | after four: 2 running, then HALT 0 |
| `runs_to` | `12 + 17421k` instructions to window k's top, for every k up to the stop |

Each rests on Lean's own axioms only (`#print axioms`, in
[capture.txt](./capture.txt)).

[`proof/mutants.txt`](./proof/mutants.txt) holds ten wrong versions. Six
are wrong kernels: the branch inverted, the halt code off by one either
way, the digests 16 bytes apart, `HASH` asked for the next window, and the
repetition count starting as though a 0 came first. Four are wrong claims:
each window starting with no run behind it, a digest for the failing window
too, the halt code as an index, and one instruction fewer. Lean refuses
every one, each in the theorem its label names.

The mutant the plan asked for first, "the run reset at each window", is the
claim one: in this kernel the reset would be a change to
`Alice.Window.head`, and `lean.sh`'s mutants can change only `lean/`, not a
proposer's package (one of the settings this trial found; see
[below](#what-the-trial-found-in-the-calls-settings)). What is refused here
is the statement that the kernel resets; the seam streams in the
differential and the page's `reset.txt` are where a resetting kernel's
behaviour is caught.

## The reference, and the differential

[`seam.py`](./seam.py) is the specification written the way exp114's crate
is: one sample at a time, a `run` and a `last` that nothing resets, each
window's reference its first sample. It shares nothing with the kernel's
registers. Its `streams()` are 14 streams of 4096 words:

- the seam: 11 + 10 ones across window 1's edge, 10 + 10 (one short), 1 + 20
  zeros, 15 + 6 across window 3's edge;
- the repetition count's cutoff inside a window: 21 and 20 alike in window 3;
- the adaptive proportion's cutoff: 589 and 588 of window 2 equal to its first;
- exp222's broken sources, each in a window of its own: stuck at 1 in
  window 1, nine ones then a zero in window 4;
- fair throughout, two random, and one with noise above bit 0.

[`differential/differential.py`](./differential/differential.py) runs
`kernel.bin` on all 14 on the Lean model (`rv32run`) and on the Hazard3
RTL. Both halt with seam.py's code; the model halts after the proof's count;
and each region is the image with hashlib's digest for each window that
passed and nothing else.

## The shell

[`shell/shell.c`](./shell/shell.c) runs six streams a round: the TRNG's,
128 words split into 4096 samples, then five of seam.py's, compiled in by
[`gen.py`](./gen.py) — the seam (11 + 10, which must stop at window 2) and
its control (10 + 10, which must not), and stuck at 1, 21 alike in window 3,
and nine ones then a zero, so that every halt code comes up. For each: the
64 KiB region zeroed, the kernel at its start, sample i at 0x400 + 4i as a
word, 0 or 1. The kernel runs in User mode under
[`tools/hazard3/harness`](../../../../tools/hazard3/harness/), and the shell
answers `HASH` with the chip's SHA-256 block (exp210's), or `sha256.c` on the
RTL. Then it checks:

1. the kernel's bytes were `kernel.sha256`'s;
2. it halted with a code 0 to 4 — seam.py's, for a fixed stream — after one
   `HASH` call for each window before the stop;
3. minstret is the RTL's count for that code;
4. each digest is SHA-256 of its window — hashlib's (gen.py) for a fixed
   stream, the block's for the TRNG's — and with them cleared the region
   hashes as it did before the run.

The TRNG's code is not checked against anything: nothing saw its samples
before the kernel did. The page does it, from the samples the board sends.

gen.py runs every fixed stream on the Lean model and the RTL before it
writes anything. The RTL counts more than the proof does, as the harness's
entry and each `HASH` round trip retire instructions of their own:

| Code | The proof's count | The RTL's minstret | More |
| --- | --- | --- | --- |
| 0 | 69699 | 69719 | 20 |
| 1 | 17431 | 17434 | 3 |
| 2 | 34852 | 34859 | 7 |
| 3 | 52273 | 52284 | 11 |
| 4 | 69694 | 69709 | 15 |

That is 3 + 4 per `HASH` call for codes 1 to 4, and one more than that for
code 0. The one is not explained here: the only difference on code 0's path
is that the halt comes five instructions after the last `HASH` returns
rather than a window later. The shell holds the chip to the RTL's own
figure, as exp223's does, so that a chip that counts differently fails
check 3 instead of being explained away.

Wrong shells are caught by the check they name: the kernel's hash changed
(1), the seam stream said to pass (2), one more instruction asked for code
2 (3), `HASH` writing a word late (4), hashing 64 bytes too few (4), the
samples a word late (4, at gen.py's digest), and the shell trapping itself
(a fault).

### The lines

Over USB ([`tools/hazard3/shell/speak.h`](../../../../tools/hazard3/shell/speak.h)),
while a page holds the port open:

```
BITS round s k w0 … w15         samples 512k to 512k + 511 of stream s
DIGEST round s w <64 hex>       what the kernel wrote for window w
STREAM round s code want minstret digests name
ROUND round streams
```

Sample i is bit i % 32 of word i / 32. A window's 4096 bytes are its
samples as little-endian words, so a page has them from the BITS lines
alone. `want` is ffffffff for the TRNG's stream.

### The LED

After each stream, the halt code in flashes: 1 to 4 is the window the
kernel stopped at, and one long light is 0, every window passed. Then 2 s
dark. A round is six streams, so a healthy board shows: one long light (the
TRNG), two flashes (the seam), one long light (its control), then one, three
and four flashes. And speak.h's own: N flashes and 3 s dark is a USB stage;
2 s of light first is an error, its count the check that failed (10: the
TRNG gave nothing).

## The page

[`seam.html`](./seam.html) judges every stream again: both tests written a
sample at a time as the standard states them, sharing nothing with the
kernel or the C, and SHA-256 of each window from the browser's WebCrypto.
For each stream it shows, per window, the longest run (with the part carried
in from the window before), the adaptive proportion's count, and which test
failed; and it marks the stream wrong if its code, minstret, the number of
digests or any digest is not what its samples give, or incomplete when a
line of it was lost. It also counts the streams stopped by a run begun in
the window before.

The connecting, Copy and the look are alice's shared
[`../pages/core.js`](../pages/core.js) and `core.css`.
[`../pages/build.py`](../pages/build.py) puts them into the page, so a phone
opens one file: `build/seam.html`.

[`page_test.mjs`](./page_test.mjs) runs the page's checking block under
node, on all 14 of seam.py's streams and on lines
[`fixtures.py`](./fixtures.py) writes from seam.py and hashlib: two good
rounds, a digest flipped, a kernel that resets the run at each edge (it
passes the seam stream with four digests, each SHA-256 of its window — the
page says its samples stop at window 2), one that writes after the first
failure, minstret off by one, a line lost, and a page that joins
mid-stream. [`page_browser.mjs`](./page_browser.mjs) runs the built page in
headless Chromium against a stand-in board. Six wrong pages are caught.

What the page cannot check: that the kernel that ran is the proved one
(the shell's check 1 is), and the proof itself.

## Running it on a board, from a phone

Needs a Pico 2 and an Android phone with Chrome; one BOOTSEL press.

1. Hold BOOTSEL, plug the Pico 2 into the phone, drop
   `build/vk26-alice-1.uf2` on the drive that appears.
2. Watch the LED: one long light, two flashes, one long light, one flash,
   three, four, then again.
3. Open `build/seam.html` from the Files app with Chrome, press Connect and
   choose "vk26-alice-1". Wait for two ROUND lines, then press Save, and
   send the file it puts in Downloads back as an attachment; it goes into
   `board/` as it is. Copy gives the same text, but a log of a few rounds
   is longer than a chat message holds: round 1's was cut on the way (see
   below), which is why page build p2 has Save.

`check.sh` then holds every whole stream in it to seam.py and hashlib, and
runs it through the page's block.

## On the board

[`board/round1.txt`](./board/round1.txt): a Pico 2, the page on a phone,
the log Copy gave back. The LED blinked as described: one long light, two
flashes, one long light, one, three, four.

The page, as it copied: 11 streams, 11 judged right, 0 wrong, 0
incomplete, 2 rounds, 2 stopped by a run across an edge, no FAIL line. The
log as pasted holds fewer: it starts at round 3's last stream and is cut
part way through a status line after round 4's last, so it has seven whole
streams and one ROUND line. Those seven, by `fixtures.py --board` (seam.py
and hashlib) and by the page's block under node:

| Round | Stream | Code (chip = seam.py) | minstret (= RTL) | Digests |
| --- | --- | --- | --- | --- |
| 3 | nine ones then a zero, window 4 | 4 | 69709 | 3, hashlib's |
| 4 | trng | 0 | 69719 | 4, hashlib's |
| 4 | seam 11+10 | 2 | 34859 | 1, hashlib's |
| 4 | seam 10+10 | 0 | 69719 | 4, hashlib's |
| 4 | stuck at 1, window 1 | 1 | 17434 | 0 |
| 4 | 21 alike in window 3 | 3 | 52284 | 2, hashlib's |

What it adds to the RTL:

- **The chip counts as the RTL does**, at every code, the extra one at
  code 0 included: 69719, not 69718. So the extra instruction is in the
  core or in tools/hazard3/harness, which both run, not in the testbench's
  simulation. It is still not explained.
- **The TRNG's digests are SHA-256's**, by hashlib on this machine, not
  only the SHA-256 block checked against itself. Its round-4 samples: the
  longest run 11, and 530, 496, 516 and 502 of each window equal to its
  first — far from 21 and 589, and code 0, as seam.py says.
- **The seam stream stopped at window 2 on silicon**, with one digest,
  window 1's.

## What it does not say

- One board, one phone, one log, and the log as pasted is part of what the
  page saw: seven whole streams, one TRNG draw.
- The proof says nothing about which function `HASH` is. On the chip the
  shell holds the SHA-256 block to hashlib's digests on the five fixed
  streams, and the TRNG's only to the same block again; that the TRNG's
  were SHA-256's is this log's, checked here afterwards.
- The TRNG's own halt code is not predicted; on the RTL the stand-in's
  samples pass, as seam.py says they should.
- The extra instruction counted at code 0, on the RTL and on the chip, is
  measured, not explained.
- One window at a time is still how the adaptive proportion test runs, and
  the stream is four windows: what happens after the fourth (a fifth
  window, a reseed) is not here.

## What the trial found in the call's settings

Found while making this experiment, and recorded in
[alice's README](../README.md#五預期會測到的徵集設定問題):

- `lean.sh exec` checked a proposer's file against `lean/` instead of the
  proposer's package (fixed in its own commit).
- The judge's bundle held no page, so a README's claims about one could
  only be unsupported (fixed in its own commit: J1 now reads the pages a
  README links, with the scripts they load from beside them).
- `lean.sh`'s mutants can change only `lean/`, not a proposer's package.
- `experiments/duplication.sh` does not look in `calls/`.
- `lean.sh check` fails on any warning, and the library has no Mathlib, so
  `split_ifs` and `set` are not there; `bv_omega` is.

## Running it

```sh
./check.sh     # everything that needs no board, about four minutes
./run.sh       # the same, recorded to capture.txt
./build.sh     # build/vk26-alice-1.uf2 and build/sim.bin
python3 ../pages/build.py seam.html build/seam.html   # the page, as one file
```

## Expected output

[capture.txt](./capture.txt), recorded by `run.sh` from a clean commit.

Pasted from it — the theorems, the mutants, the six streams on the RTL:

```
=== vk26-alice-1 — the run across the seam ===
recorded at 2026-10-13T12:25:46Z from commit e744097

>>> the theorems, and what they rest on
'Seam.init_regs' depends on axioms: [propext, Classical.choice, Quot.sound]
'Seam.setup_run' depends on axioms: [propext, Classical.choice, Quot.sound]
'Seam.window_head' depends on axioms: [propext, Classical.choice, Quot.sound]
'Seam.window_fail' depends on axioms: [propext, Classical.choice, Quot.sound]
'Seam.window_pass' depends on axioms: [propext, Classical.choice, Quot.sound]
'Seam.all_pass' depends on axioms: [propext, Classical.choice, Quot.sound]
'Seam.runs_to' depends on axioms: [propext, Classical.choice, Quot.sound]
'Seam.from_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
window_fail  the branch goes to FAIL when the window passed, and on when it failed     refused in window_fail
window_fail  the halt code is the number of windows passed, not the failing window's   refused in window_fail
all_pass     four windows passed and it halts with 1                                   refused in all_pass
window_pass  each digest 16 bytes after the last, half over it                         refused in window_pass
window_pass  HASH is asked for the window after the one tested                         refused in window_pass
init_regs    the repetition count starts as though a 0 came before the stream          refused in init_regs
window_head  the claim: each window starts with no run behind it                       refused in window_head
from_boot    the claim: the failing window's digest is written too                     refused in from_boot
from_boot    the claim: the halt code is the failing window's index, 0 to 3            refused in from_boot
from_boot    the claim: one instruction fewer to the halt                              refused in from_boot

...
>>> on the RTL, every stream: STRM s code want minstret digests, then DONE streams
5354524d 00000000 00000000 ffffffff 00011057 00000004
5354524d 00000001 00000002 00000002 0000882b 00000001
5354524d 00000002 00000000 00000000 00011057 00000004
5354524d 00000003 00000001 00000001 0000441a 00000000
5354524d 00000004 00000003 00000003 0000cc3c 00000002
5354524d 00000005 00000004 00000004 0001104d 00000003 444f4e45 00000006 exit=0 
```

and the phone's log, among 70 PASS, 0 FAIL and 0 SKIP:

```
PASS  round1.txt: 7 of 7 streams from a board judged right, 0 incomplete, 1 rounds, 1 stopped across an edge
PASS  round1.txt: 7 whole streams from a board, each code, minstret and digest as seam.py and hashlib give them
```
