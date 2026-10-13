# vk26-alice-2 — the hash tested first

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Before a kernel hands its samples to `HASH`, it asks `HASH` a question
whose answer it already has: the digest of 64 fixed bytes, compared with the
digest the image carries. Only if the answer is right does it test
samples: SP 800-90B's start-up test over one window of 1024, then one more
window, the repetition count carried across the edge between them. Only if
both pass is `HASH` of the second window written as the output. A
112-instruction RV32IM kernel, proved in Lean for every input and for any
`HASH` (`Trust.from_boot`, `Trust.trusts_after_kat`):
- a `HASH` that answers the known-answer test (KAT) wrong stops the kernel
  with 2 after exactly 43 instructions, before it reads a sample; the only
  bytes it has written are that answer, at the KAT's scratch;
- otherwise it halts with 1 if the start-up window fails, 3 if the next does,
  and 0 if both pass, after exactly 17462, 34878 or 34885 instructions; with
  0, and only with 0, the 32 bytes at 0x2400 are `HASH` of the second
  window's 4096 bytes, and no other byte changed.

On the RTL the shell runs five streams, one of them with `HASH`'s answer to
the KAT spoiled on purpose: the kernel stops there, every time. Two wrong
shells — `HASH` writing its digest a word late, and hashing 64 bytes too
few — are caught by the KAT itself. On a Pico 2, read on a phone through the
page: the LED blinked as it should, and all 18 whole streams in the saved
log, over three rounds, halted with trust.py's code at the RTL's minstret;
the spoiled KAT was refused all four times it came up, before a sample was
read, and each of the seven outputs was hashlib's SHA-256 of its second
window.**

This is the second experiment of [alice's trial proposal](../README.md) for
the vk26 call; the first is
[vk26-alice-1](../vk26-alice-1-the-run-across-the-seam/), whose window block
and carried repetition count this one uses.

## Why test the hash first

[exp223](../../../../experiments/exp223-the-digest-the-kernel-withholds/)
conditions with a SHA-256 written in RV32IM and proved
([exp208](../../../../experiments/exp208-the-hash-the-kernel-computes/)):
334284 instructions for one window. vk26-alice-1 and this experiment call
`HASH` instead, an `ecall` the shell answers with the RP2350's SHA-256 block
([exp210](../../../../experiments/exp210-the-hash-the-chip-computes/)), and
the whole kernel, two windows and two `HASH` calls, is 34885 instructions.
The price is that the kernel's output is only as good as the block. The
proofs say nothing about which function `HASH` is: `env.hash` is any
function from bytes to 32 bytes.

vk26-alice-1 left the checking to the shell and the page, which hold every
digest to hashlib and WebCrypto. That is checking afterwards, from outside.
This experiment puts a check inside the kernel, before the first sample is
read, and puts the condition into the theorem: what the kernel writes is
`HASH`'s, and `HASH` has answered the one question it was asked right.

SP 800-90B does not ask for this. The text searched for "known answer" has
no match, and its health tests are on the noise source's samples, "before
any conditioning is done" (§4.3, item 6). The KAT is this experiment's
choice. The start-up test is the standard's, §4.3 item 4:

> The entropy source's startup tests shall run the continuous health tests
> over at least 1024 consecutive samples. … The samples subjected to startup
> testing may be released for operational use after the startup tests have
> been passed, or may be discarded at any time.

The kernel takes the second option: the start-up window is tested and
never hashed. One of its consequences is easy to miss. The repetition count
is carried from the start-up window into the next (vk26-alice-1's point),
so the start-up samples decide *whether* there is an output, but no byte of
the output depends on them.

[exp114](../../../../experiments/exp114-health-tests/)'s README says why
the shell spoils the KAT on purpose once a round: "A check that has never
been observed to fire is indistinguishable from a check that cannot fire."

## The kernel

`proof/Trust.lean` writes it; `kernel.bin` is its 448 bytes.

| Instructions | What |
| --- | --- |
| 0 | `s0` = base |
| 1–6 | `HASH` of the 64 bytes at 0x300, to 0x360 (the KAT's scratch) |
| 7–38 | the 32 bytes at 0x360 against the 32 at 0x340, eight words, no early exit (`Blocks.compare_words`); `s6` = 0 iff all equal |
| 39 | `bne s6` → KAT FAIL |
| 40–42 | `s1` = base + 0x400 (the samples), `s4` = 2 (no sample yet), `s5` = 0 (the run) |
| 43–66 | window 0, the start-up test: [`Alice.Window.win`](../lean/Alice/Window.lean) |
| 67 | `bne s6` → START FAIL |
| 68–91 | window 1, `s4` and `s5` carried in |
| 92 | `bne s6` → FAIL |
| 93–99 | `HASH` of window 1's 4096 bytes, to base + 0x2400 |
| 100 | HALT 0 |
| 103 | START FAIL: HALT 1 |
| 106 | KAT FAIL: HALT 2 |
| 109 | FAIL: HALT 3 |

The image the shell lays out: the kernel at 0, the KAT's message at 0x300,
the digest it should have at 0x340 (hashlib's, written by
[`gen.py`](./gen.py)), the scratch at 0x360, sample i at 0x400 + 4i as a
word, 0 or 1, and the output at 0x2400.

## What is proved

`Trust.from_boot`: placed at any `base` the model allows, with the image's
first 448 bytes the kernel's,

```lean
(∃ s1, run env (cost env.hash (memOfImage base img) base - 1) (boot env.region img) = .running s1) ∧
∃ s', run env (cost env.hash (memOfImage base img) base) (boot env.region img)
    = .halted (code env.hash (memOfImage base img) base) s'
  ∧ s'.mem = after env.hash (memOfImage base img) base
```

- `Trusted H m base`: for each of the 32 bytes, what `H` gives for the 64
  bytes at 0x300 is the byte at 0x340 + i.
- `code`: 2 if not `Trusted`; else 1 if window 0 fails (`WinOk`, as in
  vk26-alice-1: no run of 21 from the stream's first sample to the window's
  last, fewer than 589 of the window equal to its first); else 3 if window 1
  fails; else 0.
- `cost`: 43, 17462, 34878, 34885 in the same order.
- `after`: the image with `H`'s answer to the KAT at 0x360 (`katted`) and,
  when all three hold, `H (windowBytes m base 0x400 1)` at 0x2400.

`Trust.trusts_after_kat` reads it the way the plan put it:

```lean
(¬ Trusted env.hash (memOfImage base img) base →
  ∃ s', run env 43 (boot env.region img) = .halted 2 s'
    ∧ s'.mem = katted env.hash (memOfImage base img) base) ∧
(∀ s', run env (cost env.hash (memOfImage base img) base) (boot env.region img) = .halted 0 s' →
  Trusted env.hash (memOfImage base img) base ∧ ∀ i : Fin 32,
    s'.mem (base + BitVec.ofNat 32 (OUT + i)) = env.hash (windowBytes (memOfImage base img) base SMP 1) i)
```

[The plan](../README.md#vk26-alice-2--the-hash-tested-first) said a failed
KAT leaves memory unchanged. It cannot: `HASH` writes its answer before the
kernel can compare it. What is proved is the exact difference, the 32
bytes at the scratch.

Under it, in order:

| Theorem | What it says |
| --- | --- |
| `kat_run` | the first 39 instructions: `HASH` of the message to the scratch, then `s6` = 0 iff the scratch equals the expected digest (`compare_iff`) |
| `halts` | each HALT line: 3 instructions to `.halted c` with memory as it was |
| `window_step` | a window, read through the KAT's memory: [`win_run`](../lean/Alice/Window.lean), then its branch |
| `output_run` | the 7 instructions to the output: `a0` = window 1's start, `a1` = 4096, and `HASH` writes at 0x2400 |
| `from_boot`, `trusts_after_kat` | the whole kernel, as above |

Each rests on Lean's own axioms only (`#print axioms`, in
[capture.txt](./capture.txt)).

[`proof/mutants.txt`](./proof/mutants.txt) holds eleven wrong versions.
Five are wrong kernels: the KAT's branch inverted, the answer compared
with the four bytes after the expected digest, the comparison's `or` an
`and`, the output `HASH` of the start-up window, and a failed start-up
window halting with 3. Five are wrong claims: a failed KAT halting with 0,
the output written whether or not the KAT passed, the output `HASH` of the
start-up window, the hash trusted when its answer equals the scratch it was
written to (true of every hash), and a failed KAT one instruction sooner.
The eleventh edits alice's own package, `Alice/Window.lean`: the
specification resetting the run at each window. Lean refuses every one, in
the theorem its label names.

## The reference, and the differential

[`trust.py`](./trust.py) is the plan in order — the KAT, the start-up
window, the next window, the output — for any `H`, on alice's shared
[`../tools/health.py`](../tools/health.py), and shares nothing with the
kernel's registers. Its `trust_streams()` are 14 streams of 2048 words:

- fair; stuck at 1 from the start; 21 and 20 alike in the start-up window;
- across the edge between the windows: 11 + 10 ones, 10 + 10, 20 + 1 zeros;
- the adaptive proportion's cutoff: 589 of window 1, 589 and 588 of window 2;
- nine ones then a zero in window 2; two random; noise above bit 0.

And `bad_wants()`: three expected digests the KAT must refuse — the right
one with its first bit flipped, its last bit flipped, and all zeros.

[`differential/differential.py`](./differential/differential.py) runs
`kernel.bin` on all 17 on the Lean model and the Hazard3 RTL. Both halt with
trust.py's code; the model after the proof's count; each region is the
image with hashlib's answer at the scratch and, with 0, hashlib's digest of
window 1 at the output, and nothing else.

## The shell

[`shell/shell.c`](./shell/shell.c) runs five streams a round: the TRNG's,
64 words split into 2048 samples, then four of trust.py's, compiled in by
gen.py — fair, with `HASH`'s answer to the KAT spoiled (the shell flips bit
0 of its first byte, so the kernel must stop with 2 before reading a
sample); the run across the edge, 11 + 10 (3); its control, 10 + 10 (0); and
stuck at 1 from the start (1). The kernel runs in User mode under
[`tools/hazard3/harness`](../../../../tools/hazard3/harness/), the shell
answering `HASH` with the chip's SHA-256 block, or `sha256.c` on the RTL.
Then it checks ([`board.h`](./shell/board.h) numbers them):

1. the kernel's bytes were `kernel.sha256`'s;
2. the code is trust.py's for a fixed stream, 0 to 3 for the TRNG's, and 2
   exactly when the shell spoiled the answer; `HASH` called twice for 0,
   once otherwise;
3. minstret is the RTL's count for that code;
4. the scratch holds what `HASH` answered (and, unless spoiled, hashlib's
   digest); with 0, the output is SHA-256 of window 1 — gen.py's for a
   fixed stream, the block's for the TRNG's; and with those cleared the
   region hashes as it did before the run.

And 10: the TRNG gave nothing.

gen.py runs every fixed stream, and the fair one with a wrong expected
digest, on the Lean model and the RTL before it writes anything:

| Code | The proof's count | The RTL's minstret | More | `HASH` calls |
| --- | --- | --- | --- | --- |
| 0 | 34885 | 34897 | 12 | 2 |
| 1 | 17462 | 17470 | 8 | 1 |
| 2 | 43 | 51 | 8 | 1 |
| 3 | 34878 | 34885 | 7 | 1 |

3 + 4 per `HASH` call, as in vk26-alice-1, and one more for codes 0, 1
and 2 but not 3. Across both experiments the one more appears exactly when
the halting `ecall` is not the kernel's last instruction: here HALT 3 is the
last, and in vk26-alice-1 HALT 0 is the only halt followed by more code.
That is a pattern seen in nine counts, not an explanation; the shell holds
the chip to the RTL's figure either way.

Wrong shells are caught by the check they name: the kernel's hash changed
(1); the shell forgetting to spoil the fair stream (2: 0 where 2 is due);
the spoiled stream said to pass (2); one more instruction asked for code 2
(3); a byte of the KAT's answer left in the region (4); the shell trapping
itself (a fault); and the TRNG giving nothing (10). Two more are caught by
the kernel, not the shell's checks: `HASH` writing its digest a word late,
and hashing 64 bytes too few. Either way the KAT's answer is wrong, the
kernel halts with 2 on the TRNG's stream, unspoiled, and check 2 says so.

### The lines

Over USB ([`tools/hazard3/shell/speak.h`](../../../../tools/hazard3/shell/speak.h)),
while a page holds the port open:

```
BITS round s k w0 … w15         samples 512k to 512k + 511 of stream s, four lines a stream
KAT round s spoil <64 hex>      HASH's answer to the KAT, as the kernel saw it
DIGEST round s 0 <64 hex>       the output, with code 0 only
STREAM round s code want minstret outputs name
ROUND round streams
```

### The LED

After each stream, the halt code in flashes — 1 the start-up window failed,
2 `HASH` failed its KAT, 3 the second window failed — or one long light
for 0; then 2 s dark. A healthy round: long (the TRNG), two (the spoiled
hash), three (the run across the edge), long (its control), one (stuck at
1). And speak.h's own: N flashes and 3 s dark is a USB stage; 2 s of light
first is an error, its count the check that failed.

## The page

[`trust.html`](./trust.html) judges every stream again, from the lines
alone: the KAT's answer against WebCrypto's SHA-256 of the message (or of
it with the one bit flipped, when the line says the shell spoiled it); then
SP 800-90B's two tests over both windows, from alice's shared
[`../pages/health.js`](../pages/health.js), the same code vk26-alice-1's
page judges with; then the output against WebCrypto's SHA-256 of the second
window. A stream is wrong if its code, minstret, or output is not what its
KAT answer and samples give, or if the KAT answer is not what the shell
says it was; incomplete if a BITS or KAT line of it was lost.

[`page_test.mjs`](./page_test.mjs) runs the page's block under node, on all
14 of trust.py's streams and on lines [`fixtures.py`](./fixtures.py) writes
from trust.py and hashlib: two good rounds; a kernel that never asks the
KAT (the spoiled stream goes on to an output); `HASH` answering wrong with
nothing spoiling it; a kernel that skips the start-up test; one that resets
the run at the start-up window's edge; one that hashes the start-up window;
an output flipped; minstret off by one; a BITS line lost, the KAT line
lost, and a page that joins mid-stream. [`../pages/browser.mjs`](../pages/browser.mjs)
runs the built page in headless Chromium against a stand-in board. Seven
wrong pages, made from the built page, are caught.

What the page cannot check: that the kernel that ran is the proved one (the
shell's check 1 is), and the proof itself.

## Running it on a board, from a phone

Needs a Pico 2 and an Android phone with Chrome; one BOOTSEL press.

1. Hold BOOTSEL, plug the Pico 2 into the phone, drop
   `build/vk26-alice-2.uf2` on the drive that appears.
2. Watch the LED: long, two, three, long, one, then again.
3. Open `build/trust.html` from the Files app with Chrome, press Connect and
   choose "vk26-alice-2". Wait for two ROUND lines, then press Save, and
   send the file it puts in Downloads back as an attachment; it goes into
   `board/` as it is.

`check.sh` then holds every whole stream in it to trust.py and hashlib, and
runs it through the page's block.

## On the board

[`board/round1.txt`](./board/round1.txt): a Pico 2, the page on a phone,
the file Save gave back, kept as it came. The LED blinked as described:
long, two, three, long, one, round after round.

The page, as it saved: 18 streams, 18 judged right, 0 wrong, 0 incomplete,
3 rounds, 4 spoiled hashes refused, 3 stopped by the start-up test, 7
outputs, no FAIL line. The log starts at round 6's second stream and ends
after round 9's fourth; every stream in it is whole. By `fixtures.py
--board` (trust.py and hashlib) and by the page's block under node, all 18:

| Stream | Rounds | Code (chip = trust.py) | minstret (= RTL) | KAT answer | Output |
| --- | --- | --- | --- | --- | --- |
| trng | 7, 8, 9 | 0 | 34897 | SHA-256's | hashlib's, of window 2 |
| fair, spoiled | 6, 7, 8, 9 | 2 | 51 | SHA-256's, bit 0 of byte 0 flipped | none |
| seam 11+10 | 6, 7, 8, 9 | 3 | 34885 | SHA-256's | none |
| seam 10+10 | 6, 7, 8, 9 | 0 | 34897 | SHA-256's | hashlib's, of window 2 |
| stuck at 1 from the start | 6, 7, 8 | 1 | 17470 | SHA-256's | none |

What it adds to the RTL:

- **The chip counts as the RTL does**, at all four codes, the one more at
  codes 0, 1 and 2 included: 34897, 17470, 51 — and 34885 at code 3, with
  none. So the pattern seen across both experiments is the core's or
  tools/hazard3/harness's, not the testbench's. It is still not explained.
- **The SHA-256 block answered the KAT right every time it was asked
  honestly** (14 times here), and the kernel went on; every time the shell
  spoiled the answer (4), the kernel stopped at instruction 43 and wrote no
  output.
- **The TRNG's three draws**, judged here afterwards: longest runs 11, 12
  and 11; 516 and 508, 501 and 522, 518 and 527 of each window equal to its
  first — far from 21 and 589, and code 0, as trust.py says.

## What it does not say

- One board, one phone, one log: 18 streams, three TRNG draws.
- The KAT asks one question: 64 bytes, one block. A `HASH` that is right
  for one block and wrong for 64 — the output's length — passes it. The
  shell's check 4 and the page hold the output to SHA-256 afterwards; the
  kernel does not.
- `Trusted` compares `HASH`'s answer with the bytes at 0x340, whatever they
  are. That they are SHA-256's is gen.py's and the shell's (check 4, against
  hashlib), not the proof's: an image with a wrong expected digest stops
  every stream with 2, which is the differential's three bad wants.
- The spoiled stream is the shell flipping a bit, not the block failing. It
  shows the KAT fires; it is not evidence about how the block fails.
- The one more instruction for codes 0 to 2, on the RTL and on the chip, is measured, not
  explained.

## What the trial found in the call's settings

Found while making this experiment, and recorded in
[alice's README](../README.md#五預期會測到的徵集設定問題):

- J3's prior work, for a proposal's experiment, held the repository's
  experiments from exp201 on and none of the proposal's own, so J3 could
  credit vk26-alice-1's carried run to this experiment (fixed in its own
  commit: the proposal's earlier rows of its index table are now in J3's
  slice).
- `duplication.sh` counts by name: this experiment's `streams()` met
  vk26-alice-1's, a different function, and is `trust_streams()`.
- A second page, a second fixtures.py and a second RTL check would each
  have copied vk26-alice-1's. Before they could, the judging code moved to
  `../pages/health.js`, the node loader to `../pages/pagetest.mjs`, the
  browser check to `../pages/browser.mjs`, and the lines to
  `../tools/lines.py`. A Python twin of trng_sim.h is in `../tools/`, not
  beside trng_sim.h, because a proposal changes only its own directory.

## Running it

```sh
./check.sh     # everything that needs no board, about three minutes
./run.sh       # the same, recorded to capture.txt
./build.sh     # build/vk26-alice-2.uf2 and build/sim.bin
python3 ../pages/build.py trust.html build/trust.html   # the page, as one file
```

## Expected output

[capture.txt](./capture.txt), recorded by `run.sh` from a clean commit.

Pasted from it — the theorems, the mutants, the five streams on the RTL:

```
=== vk26-alice-2 — the hash tested first ===
recorded at 2026-10-13T16:06:53Z from commit 92c6418

>>> the theorems, and what they rest on
'Trust.compare_iff' depends on axioms: [propext, Quot.sound]
'Trust.kat_run' depends on axioms: [propext, Classical.choice, Quot.sound]
'Trust.halts' depends on axioms: [propext, Classical.choice, Quot.sound]
'Trust.window_step' depends on axioms: [propext, Classical.choice, Quot.sound]
'Trust.output_run' depends on axioms: [propext, Classical.choice, Quot.sound]
'Trust.from_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
'Trust.trusts_after_kat' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
from_boot    the KAT's branch is inverted: on to the samples when the hash failed                                           refused in from_boot
cmp_at       the KAT's answer is compared with the bytes four after the expected digest                                     refused in cmp_at
cmp_at       the comparison keeps only the bits every word disagrees in (and, not or)                                       refused in cmp_at
output_run   the output is HASH of the start-up window, the samples it was to discard                                       refused in output_run
at_bne       a failed start-up window halts with 3, as though the next had failed                                           refused in at_bne
from_boot    the claim: a failed KAT halts with 0                                                                           refused in from_boot
from_boot    the claim: the output is written whether or not the hash passed its KAT                                        refused in from_boot
from_boot    the claim: the output is HASH of the start-up window                                                           refused in from_boot
compare_iff  the claim: the hash is trusted when its answer equals the scratch it was written to, not the expected digest   refused in compare_iff
from_boot    the claim: a failed KAT halts one instruction sooner                                                           refused in from_boot
win_verdict  the specification: the repetition count starts afresh at each window, as front's does                          refused in win_verdict
...
>>> on the RTL, every stream: STRM s code want minstret spoil, then DONE streams
5354524d 00000000 00000000 ffffffff 00008851 00000000
5354524d 00000001 00000002 00000002 00000033 00000001
5354524d 00000002 00000003 00000003 00008845 00000000
5354524d 00000003 00000000 00000000 00008851 00000000
5354524d 00000004 00000001 00000001 0000443e 00000000 444f4e45 00000005 exit=0 
```

and the KAT at work, among 81 PASS, 0 FAIL and 1 SKIP (no phone log yet):

```
PASS  on the RTL the shell runs all five streams, SHA-256 answering HASH, each halting with trust.py's code and the RTL's count for it, the spoiled one at the KAT
PASS  the shell catches a version where HASH writes its digest a word late — the KAT refuses it: check 2, code 2 unspoiled
PASS  the shell catches a version where HASH hashes 64 bytes too few — the KAT refuses it: check 2, code 2 unspoiled
```
