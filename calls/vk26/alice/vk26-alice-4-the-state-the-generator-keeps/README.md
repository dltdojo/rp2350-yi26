# vk26-alice-4 — the state the generator keeps

<!-- SPDX-License-Identifier: Apache-2.0 -->

**SP 800-90A's Hash_DRBG keeps a state (V, C, reseed_counter) and, on
every Generate, returns Hash(V), Hash(V + 1), … and moves V on by
V + H + C + reseed_counter mod 2^440. A 70-instruction RV32IM kernel does
that Generate, with SHA-256's seedlen of 55 bytes and no additional input,
and Lean proves it for every state and every hash function
(`Drbg.from_boot`):
- with the counter at most the interval, it halts with 0 after exactly
  2030 + 566m instructions for m blocks;
- memory is then the image with Hashgen's m blocks at 0x600
  (`after_out`), V the next V, the counter one more, the work it did
  (data, H, the counter's bytes) where it did it, and nothing else;
- with the counter past the interval it halts with 1 after 7 and writes
  nothing (`reseed_boot`);
- started again on the region it left, the second Generate's blocks are
  Hashgen of the next V (`generate_twice`).

The arithmetic is the hard part: four 55-byte big-endian numbers added with
carries, done by one subroutine the proof takes byte by byte. NIST's CAVP
vectors were reachable from the cloud, so the hash is held to SHA-256 three
ways: drbg.py gives all 120 SHA-256 cases' ReturnedBits; the Lean model and
the Hazard3 RTL generate them all, twice each, through the kernel's own
region; and the shell runs all 120 on the RTL, three runs a case, the third
refused for reseed. On a Pico 2, read on a phone through the page, the
board ran 178 cases over two rounds without a FAIL. The saved log holds 165
of them whole, and all 165 are right. Their second Generate's bits are
NIST's ReturnedBits, so the chip's SHA-256 block, with this experiment's
own padding, is SHA-256 on HASHB's 55- and 56-byte inputs. Every
Generate's minstret is the RTL's 4318. Every second Generate took 15,078
cycles, whatever the state. The first Generate took 15,078 in 125 of the
165 cases and up to 1,596 more in the rest, mostly the same cases in both
rounds.**

This is the fourth experiment of [alice's trial proposal](../README.md) for
the vk26 call.

## Why the state

[exp222](../../../../experiments/exp222-the-bits-the-kernel-withholds/) and
[exp223](../../../../experiments/exp223-the-digest-the-kernel-withholds/) end with a
conditioned seed: 32 bytes of SHA-256 over samples that passed their health
tests. What a generator does with a seed is the next half of the chain, and
SP 800-90A puts most of its weight on one thing: the state. Its Generate is
four lines (§10.1.1.4, no additional input):

1. if reseed_counter > reseed_interval, return "reseed required";
2. returned bits = Hashgen(V): Hash(V), Hash(V + 1), …, as many blocks as
   asked;
3. H = Hash(0x03 ‖ V);
4. V = (V + H + C + reseed_counter) mod 2^440; reseed_counter += 1.

Steps 2 and 4 are where an implementation goes quietly wrong. A carry lost
between two of V's 55 bytes still gives random-looking output, and so does
a counter added at the wrong end. Both are wrong DRBGs that nothing at run
time would notice. So this one is proved.

## The kernel

`Drbg.kernel`, 70 instructions, 280 bytes, written to
`kernel.bin` by the proof (`sha256 de651726…`). Everything is an offset from
`base`, the region's start (`auipc`):

```
0x400  m (a word), 0x404 reseed_interval, 0x408 reseed_counter
0x43f  the byte 0x03, then V at 0x440 (55 bytes, big-endian)
0x480  C        0x4c0  data, Hashgen's running V + i
0x500  H, as 55 bytes: 23 zeros, then Hash(0x03 ‖ V) at 0x517
0x540  reseed_counter, as 55 bytes: 51 zeros, then its 4 bytes at 0x573
0x580  the number 1, as 55 bytes      0x600  the m blocks returned

 0       s0 = base
 1-3     interval <u counter -> RESEED
 4-12    COPY: V to data
 13-25   GEN, m times: HASHB(data, 55) to the next block; data += 1 (ADD)
 26-30   HASHB(0x03 ‖ V, 56) to 0x517
 31-36   V += H (ADD); V += C (ADD)
 37-43   the counter's 4 bytes, big-endian, to 0x573
 44-46   V += counter (ADD)
 47-51   counter += 1, stored; HALT 0
 52-54   RESEED: HALT 1
 55-69   ADD: the 55 bytes at a0 += the 55 at a1, last byte first, the carry in a3
```

The byte 0x03 sits just before V, so Hash(0x03 ‖ V) is one HASHB of 56
bytes, no copy. H and the counter are given 55-byte fields with leading
zeros, so all four additions are the same ADD: a subroutine, `jal`/`jalr`,
called five times a Generate (once per block for data + 1, three times for
V). The hash is `ecall` with t0 = 2, exp228's HASHB: SHA-256 of a1 bytes at
a0, written at a2, of any length.

The image holds what the kernel needs beside the state: the 0x03, H's and
the counter's leading zeros, and the number 1. The proof's hypotheses say
so, byte for byte.

## What is proved

[`../lean/Alice/Drbg.lean`](../lean/Alice/Drbg.lean), in alice's package since vk26-alice-5
became its second user, checked from [proof/Drbg.lean](./proof/Drbg.lean), on Lean's own axioms only (no
`sorry`, no `native_decide`):

- **`generate_run` / `from_boot`**: the image holds the kernel and a state.
  1 ≤ m, the m blocks fit in the region, and the counter is at most an
  interval below 2^32 − 1. Then from boot the kernel halts with 0 after
  exactly `COST m = 2030 + 566m` instructions. Memory is then `after`: the
  image with
  - blocks at 0x600;
  - data at V + m;
  - H at 0x517;
  - the counter's big-endian bytes at 0x573;
  - V = V + H + C + counter (`vnext`);
  - the counter word one more;
  - and every other byte as it was.

  This holds for *any* `env.hash`. Which function the hash is, the vectors
  say, below.
- **`after_out`**: in `after`, byte d of block j is byte d of Hash(V + j),
  V + j as 55 bytes: step 2, Hashgen, stated as the bytes a reader of 0x600
  sees.
- **`reseed_boot`**: with the counter past the interval, the kernel halts
  with 1 after 7 instructions and memory is the image. That is step 1.
- **`generate_twice`**: the kernel is started again on the region its first
  run left, any registers. With one more still at most the interval, it
  halts with 0 after `COST m` more. Its result is `after` of `after`: the
  second Generate's blocks are Hashgen of the first's V. NIST's vectors are
  checked this way, and the shell runs them this way.

The steps underneath:
- `add_run`: ADD adds two 55-byte fields mod 2^440, a byte and a carry at a
  time. Its invariant says the low k bytes already hold the low k bytes of
  the sum and a3 holds the carry out of them.
- `copy_loop`, `gen_loop`: the two loops, by induction.
- `call_add`: a call of ADD, returning three instructions on.
- `head_run`, `reseed_run`: the first four instructions and the branch.

Twelve wrong versions are each refused (`proof/mutants.txt`):
- reseed already at the interval;
- V copied a byte short;
- Hashgen over 54 bytes;
- H without its 0x03;
- C never added;
- a counter byte written over another;
- the counter never stored back;
- ADD's carry shifted by 9;
- and four wrong claims: one instruction fewer, `vnext` without the
  counter, H over 0x02, block j hashing V + j + 1.

**Not proved:**
- **Instantiate**, whose Hash_df turns entropy into V and C. drbg.py does
  it, from the standard's text, so that NIST's vectors can be used;
  vk26-alice-5 is where it is meant to be proved.
- **Constant time.** lean/Rv32/Ct.lean's checker knows HASH and HALT but
  not HASHB, and has no rule for `jal` or `jalr`. So it cannot be asked
  about this kernel. That is a finding about the call's settings (below),
  not a claim either way.
- **The counter is a word**, so the interval is below 2^32 − 1; the
  standard allows 2^48.
- **Whole blocks only.** A request is m × 256 bits.

## The reference, and the differential

- [`drbg.py`](./drbg.py) is Hash_DRBG written from SP 800-90A Rev. 1's
  text, nothing like the kernel's registers. Its parts:
  - `hash_df` and `drbg_instantiate` (§10.3.1, §10.1.1.2);
  - `drbg_generate` (§10.1.1.4);
  - `drbg_image` and `drbg_outcome`: what the kernel's region must hold
    before and after;
  - `drbg_region`: the whole region afterwards.
- [`cavp/Hash_DRBG_SHA256.txt`](./cavp/Hash_DRBG_SHA256.txt) is every
  SHA-256 group without additional input and without prediction
  resistance, from NIST's CAVP DRBG vectors (drbgvectors_no_reseed.zip):
  120 cases, copied unchanged but for the header, which says where from and
  the zip's SHA-256. Each case:
  1. instantiate from EntropyInput, Nonce and PersonalizationString;
  2. Generate 1024 bits twice;
  3. ReturnedBits is the second.

  `python3 drbg.py` gives all 120.
- [`differential/differential.py`](./differential/differential.py) runs
  every case on the Lean model (`rv32run`) and the RTL. The kernel
  generates 4 blocks; the region it leaves, as it is, is the image of the
  second Generate. On both, each region must be the image with
  `drbg_outcome`'s bytes and nothing else, and the second's blocks must be
  NIST's. The model must halt after exactly `COST 4 = 4294`. Then ten
  states chosen for their edges:
  - V and C all ones (every byte carries, every sum wraps);
  - data + 1 wrapping to zero;
  - a counter of 0x00ffffff;
  - the counter at the interval, and one past it;
  - the largest counter allowed;
  - one block, seven and forty.

  All pass. The RTL's minstret for a Generate of 4 blocks is 4318: the
  proof's 4294, plus the harness's 3 and 1 around every run, plus 4 for
  each of the five HASHB calls.

## The shell

[`shell/`](./shell/), built twice by [`build.sh`](./build.sh): for the
Pico 2 (`build/vk26-alice-4.uf2`, 64 KiB of flash: the code, then the 120
cases, 48,968 bytes in all) and for the RTL (`build/sim.bin`). For each of
the 120 cases, forever on the chip:

1. The 64 KiB region is zeroed. kernel.bin's 280 bytes go at its start,
   checked against kernel.sha256.
2. The state goes where the kernel keeps it:
   - m = 4, the interval 2, the counter 1;
   - V and C as drbg.py instantiates them (gen.py compiles them in);
   - the byte 3, the number 1.
3. The kernel runs three times on the same region, each run from where the
   last left it:
   - **run 1 and run 2**: Generates. Each must halt with 0 at the RTL's
     minstret.
   - **run 3**: the counter is now 3, past the interval, so it must halt
     with 1 at the RTL's minstret for the reseed check.

The kernel's one call, HASHB, is answered by the shell. Its arguments are
held to what the model accepts (`tools/hazard3/harness/hashcall.h`).
- **On the chip** it goes to the RP2350's SHA-256 block.
  `tools/hazard3/shell/sha_hw.h` takes only whole 64-byte blocks from a
  word-aligned address, and HASHB's inputs are 55 and 56 bytes, the second
  from 0x43f. So `board_chip.c` gathers the bytes into words itself and
  pads them itself: 0x80, zeros to 56 bytes into a block, the length in
  bits.
- **On the RTL** it goes to `tools/hazard3/harness/sha256.c`.

The checks, numbered as the LED counts them:

1. the kernel's bytes were kernel.sha256's;
2. the Generates halted with 0 and the third with 1, by HALT;
3. minstret is the RTL's: 4318 a Generate, 11 the reseed check;
4. after the second Generate:
   - its 4 blocks are NIST's ReturnedBits;
   - the region's first 0x700 bytes hash to what drbg.py says they hold;
   - the rest are zero;
   - and after the third run, still so.

On the RTL all 120 cases pass, each with minstret 4318, 4318 and 11. mcycle
is 42,739 for every Generate, HASHB in software included, and 15 for the
reseed check.

Eight wrong shells are each caught by the check they name:
- kernel.sha256 not the kernel's;
- HASHB answered a byte short;
- the counter starting at 2;
- an interval of 3;
- one instruction more expected;
- the number 1 put a byte early;
- a stray byte past the window;
- a trap in the shell itself.

### The lines

```
STATE round i k bytes          V (k = 0) and C (1) before the first run; V after Generate 1 (2) and 2 (3)
BLOCK round i n j bytes        block j of Generate n
RUN round i n code counter minstret mcycle
CASE round i name              every run of the case as it should be
REVISION 1                     before every ROUND
ROUND round cases
```

### The LED

A short blink as each case ends, about one a second. After the 120th, one
long light, then 2 s dark. speak.h's own codes as before: N flashes and 3 s
dark is a USB stage; 2 s of light first is an error, its count the check
that failed.

## The page

[`drbg.html`](./drbg.html) generates every case again, from the V and C
the board says it started from. It uses SP 800-90A §10.1.1.4 written in
JavaScript, the browser's own SHA-256 (WebCrypto), and BigInt for the
2^440 arithmetic. It shares nothing with the kernel, the shell, drbg.py or
the chip's SHA-256 block. It holds to its own:
- each of the 8 blocks;
- V after each Generate;
- each counter;
- each halt code (the third must be 1, the counter being past the
  interval);
- each minstret.

It starts the second Generate from its own V, not the board's, so a wrong
V is caught once, where it happens.

The page does not instantiate. NIST's vectors are checked on the chip
(check 4) and, for a saved log, by `fixtures.py --board`. That holds every
case's V and C to drbg.py's instantiation of NIST's inputs, and the
second Generate's blocks to NIST's ReturnedBits.

- **The tests:** [`page_test.mjs`](./page_test.mjs) holds the page's
  Generate to drbg.py's at the edge where V and C are all ones (data + 1
  wraps to zero, and so does the sum). It runs the page on
  [`fixtures.py`](./fixtures.py)'s logs:
  - two good rounds of all 120 cases;
  - a bit of a block flipped;
  - a bit of the board's V flipped (caught, and the next Generate still
    right);
  - a counter off;
  - a third run that generates;
  - a minstret off;
  - a BLOCK line lost;
  - a page that joins mid-case;
  - one Generate 30 cycles slower (nothing wrong, the cycles differ).
- **Wrong pages:** eight, made from the built page, are caught.
- [`../pages/browser.mjs`](../pages/browser.mjs) runs the built page in
  headless Chromium against a stand-in board.

## Running it on a board, from a phone

Needs a Pico 2 and an Android phone with Chrome; one BOOTSEL press.

1. Hold BOOTSEL, plug the Pico 2 into the phone, and drop
   `build/vk26-alice-4.uf2` on the drive that appears.
2. Watch the LED: a short blink a case, about one a second, then a long
   light after the 120th.
3. Open `build/drbg.html` from the Files app with Chrome, press Connect and
   choose "vk26-alice-4". Wait for one ROUND line, about two minutes. Then
   press Save and send the file back as an attachment; it
   goes into `board/` as it is.

What the run will say, stated before it happens:
- **Every case right, as on the RTL.** The one thing here no machine has
  checked is `board_chip.c`'s padding on the SHA-256 block for 55 and 56
  bytes. If it is wrong, the first case fails check 4: 2 s of light, then
  four flashes, and a `FAIL 00000004 00000000` line.
- minstret 4318, 4318 and 11 for every case.
- **mcycle: not predicted.** HASHB's time on the block is inside the
  window, and vk26-alice-3 found that what the shell reads from flash
  before a run moves the harness's two lines in and out of the XIP cache.

## On the board

[`board/round1.txt`](./board/round1.txt): a Pico 2 running
`vk26-alice-4.uf2` (`4843dec1…`, committed in 05083dd), the page on a
phone, the file Save gave back, kept as it came.

The page joined in round 0's case 33 and saved during round 1's case 91.
It saw 168 CASE lines, judged 165 right, 0 wrong and 3 incomplete, with no
FAIL line. `fixtures.py --board` agrees, against NIST:
- every whole case's V and C are drbg.py's instantiation of NIST's inputs;
- the first Generate's blocks are drbg.py's;
- the second Generate's 1024 bits are NIST's ReturnedBits;
- every halt code, counter and minstret is the RTL's: 4318, 4318 and 11.

The predictions:
- **Every case right: held.** The one untested piece, `board_chip.c`'s
  padding on the SHA-256 block for 55 and 56 bytes, is right. Had it been
  wrong, the first case would have failed check 4.
- **minstret: held,** in every one of the 495 runs.
- **mcycle, not predicted:**
  - Every second Generate took 15,078 cycles, all 165, whatever V and C
    were.
  - The first took 15,078 in 125 cases. The other 40 took 110 to 1,596
    more.
  - The reseed check took 15 cycles in 162 cases, and 115 to 135 in 3.

  The slow first runs come in runs of neighbouring cases (40–43, 49–51,
  69–72, 77–80). Of the 54 cases seen whole in both rounds, 41 took the
  same cycles both times, and the slow ones were mostly slow both times.
  Case 67's reseed check was slow in both rounds. That points at where
  each case's data lies in flash, not at its values. Before the first run
  the shell reads that case's V and C out of flash, so this is
  vk26-alice-3's XIP cache finding again. Here the code that misses
  includes HASHB's handler, which runs inside the timed window. The second
  run comes straight after the first, everything warm, and is one number.

**Lines lost on the way to the phone.** Of the three incomplete cases:
- the first is where the page joined, mid-case;
- the other two lie in round 1, where the log jumps from case 25's
  second Generate to case 31's CASE line, and then to the end of case 36.
  Cases 26–30 and 32–35 never reached the page at all.

Every line in the log is whole, so whole lines were lost, not bytes. The
board drops a whole line when its 1024-byte queue is full and counts it in
the status line's `dropped`. The last status line before the gap says
`dropped=0`, and none came after it. So the log cannot say whether the
board or the phone lost them. The page and fixtures.py claimed nothing
about the cases they lost: an incomplete case is not judged.

## What it does not say

- That Instantiate is right: drbg.py's Hash_df is checked only through
  NIST's vectors. It is in no proof here.
- That the kernel runs in constant time. The checker cannot be asked (see
  below), and HASHB's time on the chip is the shell's.
- Anything about reseeding, prediction resistance, or additional input:
  this Generate has none of them.
- That the chip's SHA-256 block is SHA-256 on other lengths: the board
  checked 55 and 56 bytes, every HASHB this kernel makes.
- Why the first Generate is slow for some cases: the cache explanation
  fits the pattern, and alice-3 measured it, but this run did not probe it.

## What the trial found in the call's settings

Found while making this experiment, and recorded in
[alice's README](../README.md#五預期會測到的徵集設定問題):

- **NIST's vectors could be had.** Discussion point 4 asked whether the
  CAVP Hash_DRBG vectors were reachable from the cloud VM. They were, from
  csrc.nist.gov. The file is committed with its source and hash, so a
  later run needs no network.
- **Ct.lean cannot be asked about this kernel.** The constant-time
  checker's `ecall` rule knows HASH (t0 = 0) and HALT, not HASHB (t0 = 2).
  It also refuses `jal` and `jalr`, which is why exp229 inlined its
  kernel. A kernel that hashes any length (exp228, this one) or calls a
  subroutine (this one) cannot be put to it. Recorded, not changed: the
  checker is in `lean/`, which S2 keeps out of a proposal.
- **The SHA-256 block's helper takes whole blocks only.** `sha_hw.h` hashes
  multiples of 64 bytes from word-aligned addresses: HASH's rule, not
  HASHB's. exp228 answered HASHB in software on the chip. Here the padding
  for any length is in alice-4's own `board_chip.c`, as `trng_raw.h` was
  for alice-3, because S2 keeps `tools/` closed. If a second proposal needs
  it, it belongs beside `sha_hw.h`.
- **The big-endian lemmas live in this experiment's proof**, not in
  `alice/lean/` as the plan said. Nothing else uses them yet. The second
  caller is where they move, and vk26-alice-5's Hash_df will be one.

## Running it

```sh
./check.sh     # everything that needs no board, about four minutes
./run.sh       # the same, recorded to capture.txt
./build.sh     # build/vk26-alice-4.uf2 and build/sim.bin
python3 ../pages/build.py drbg.html build/drbg.html   # the page, as one file
```

## Expected output

[capture.txt](./capture.txt), recorded by `run.sh` from a clean commit.

Pasted from it — the theorems, the mutants, NIST's vectors, the build, the
first and last cases on the RTL:

```
=== vk26-alice-4 — the state the generator keeps ===
recorded at 2026-10-14T07:44:45Z from commit 05083dd

>>> the theorems, and what they rest on
'Drbg.from_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
'Drbg.reseed_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
'Drbg.generate_twice' depends on axioms: [propext, Classical.choice, Quot.sound]
'Drbg.after_out' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
reseed_run    reseed when the counter equals the interval, not only past it (§10.1.1.4 step 1)   refused in reseed_run
generate_run  V is copied to data one byte short                                                  refused in generate_run
gen_iter      Hashgen hashes 54 bytes of data, not seedlen's 55                                   refused in gen_iter
generate_run  H is Hash(V), the 0x03 left off                                                     refused in generate_run
generate_run  V += H twice, C never added                                                         refused in generate_run
generate_run  the counter's third byte is written over its second                                 refused in generate_run
generate_run  the counter is stored back as it was                                                refused in generate_run
add_iter      ADD's carry is the sum shifted by 9, not 8                                          refused in add_iter
generate_run  the claim: one instruction fewer to the halt                                        refused in generate_run
generate_run  the specification: V's next value leaves the counter out                            refused in generate_run
generate_run  the specification: H is Hash(0x02 ‖ V)                                            refused in generate_run
blocks_out    the claim: block j is the hash of V + j + 1                                         refused in blocks_out

>>> drbg.py, from SP 800-90A's text, against NIST's vectors
120 of 120 NIST cases: instantiate, Generate twice, the second's 1024 bits NIST's

>>> the shell, for the chip and for the RTL
build/expect.h: kernel de65172659774701…, 120 NIST cases, RTL minstret a Generate 4318, the reseed check 11: the proof's 4294 and 7
build/vk26-alice-4.bin  48968 bytes, the build allows 65536
build/vk26-alice-4.uf2  98304 bytes  sha256 4843dec170130112df02522e98daf47363e603bf77de9299c28901d5385dc615

>>> on the RTL, every NIST case: CASE i, then minstret mcycle of each of its three runs; then DONE cases
43415345 00000000 000010de 0000a6f3 000010de 0000a6f3 0000000b 0000000f
43415345 00000001 000010de 0000a6f3 000010de 0000a6f3 0000000b 0000000f
...
43415345 00000077 000010de 0000a6f3 000010de 0000a6f3 0000000b 0000000f
444f4e45 00000078 exit=0 
```
