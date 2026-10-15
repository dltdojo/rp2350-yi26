# vk26-alice-5 — the seed the tests passed

<!-- SPDX-License-Identifier: Apache-2.0 -->

**SP 800-90A's Hash_DRBG Instantiate turns a seed material into the state
Generate keeps: V = Hash_df(seed material), C = Hash_df(0x00 ‖ V), the
counter 1. A 61-instruction RV32IM kernel does it with SHA-256's seedlen of
55 bytes. Lean proves, for every seed material of up to 128 bytes and every
hash function, that it halts with 0 after exactly 241 instructions. The
region is then laid out exactly as vk26-alice-4's Generate asks for it
(`Seed.inst_run`). Then the chain (`Seed.chain`): vk26-alice-2's kernel, this
one and vk26-alice-4's, run one after another on one region, the shell's
only step between them putting the next kernel's bytes at the region's
start. vk26-alice-2's kernel halts with 0 exactly when its hash passed the
KAT and both windows of samples passed their tests. Only then do the other
two run, and block j of the bits is Hash(V + j) for V = Hash_df(digest ‖
nonce). Each round the shell runs NIST's 120 cases through Instantiate and
two Generates, then the chain twice on samples from the TRNG, the second
time with the hash's answer to the KAT spoiled. On the Lean model and the
Hazard3 RTL every case and every chain is seed.py's. Along the way, the RTL
explained the one instruction vk26-alice-1 and vk26-alice-2 counted and
could not account for: minstret counts one more when the word after the
halting `ecall` is a legal instruction. On a Pico 2, read on a phone, the
saved log holds 202 whole NIST cases and both chains of one round, all
right and no FAIL. Hash_df's 53-, 61- and 85-byte inputs to the chip's
SHA-256 block come out SHA-256's. The TRNG's chain made bits the page made
again, and the spoiled one stopped with 2. The chip counts as the RTL does,
the Instantiate kernel 260 alone and 261 in the chain.**

This is the fifth experiment of [alice's trial proposal](../README.md) for
the vk26 call, and the one the first four were for.

## Why the chain

The first four experiments each proved one stage:
- [vk26-alice-1](../vk26-alice-1-the-run-across-the-seam/): SP 800-90B's
  health tests, the run carried across windows;
- [vk26-alice-2](../vk26-alice-2-the-hash-tested-first/): the hash asked a
  known answer before it is trusted, then the start-up window, then the
  digest of the next window;
- [vk26-alice-3](../vk26-alice-3-the-count-the-estimate-rests-on/): the count
  the min-entropy estimate rests on;
- [vk26-alice-4](../vk26-alice-4-the-state-the-generator-keeps/): Hash_DRBG's
  Generate, from a state.

Between the digest and the state lies SP 800-90A's Instantiate
(§10.1.1.2, no personalization string beyond what the seed material
carries):

1. seed_material = entropy_input ‖ nonce ‖ personalization_string;
2. V = Hash_df(seed_material, 440);
3. C = Hash_df(0x00 ‖ V, 440);
4. reseed_counter = 1.

Hash_df (§10.3.1) for 440 bits is two hashes,
Hash(0x01 ‖ 00 00 01 b8 ‖ input) ‖ Hash(0x02 ‖ 00 00 01 b8 ‖ input), cut to
55 bytes; 0x1b8 is 440. Nothing at run time notices a Hash_df told the wrong
length, a C hashed without its 0x00, or the two halves swapped: the output
still looks random. That is why it is proved, and why the proof's last
theorem is about the chain and not the kernel: the claim worth having is
that the bits come out of SP 800-90A's construction applied to a seed that
passed its tests, and come out only then.

The plan proposed one kernel built from the four blocks. The interrogation
chose instead to run the three proved kernels in order. vk26-alice-2's and
vk26-alice-4's kernels, proofs and committed `kernel.bin` stay as they are,
and what passes between them is what each one's theorem says it leaves.

## The kernel

`Seed.kernel`, 61 instructions, 244 bytes, written to `kernel.bin` by the
proof (`sha256 d89e5fba…`). Offsets from `base`, the region's start:

```
0x23fb  Hash_df's counter byte and 00 00 01 b8, then the seed material at 0x2400
0x2480  m, the interval (words), and the seed material's length S
0x43a   Hash_df's prefix for C: counter, 00 00 01 b8, 00, then V at 0x440
out:    m, the interval and the counter 1 at 0x400; 0x03 at 0x43f; V at
        0x440; C at 0x480; 23 and 51 zeros at 0x500 and 0x540; the number
        1 at 0x580 — what Drbg.generate_run asks of a region

 0-2     s0 = base, s1 = base + 0x2000
 3-6     00 00 01 b8 to 0x23fc; s2 = 5 + S
 7-20    V: HASHB(0x23fb, 5 + S) to 0x440 with counter 1, to 0x460 with 2
 21-41   C: the prefix; HASHB(0x43a, 61) to 0x480 with 1, to 0x4a0 with 2
 42-43   0x03 to 0x43f
 44-49   46 words of zeros from 0x500
 50-51   1 to 0x5b6
 52-57   m, the interval, and 1 to 0x400
 58-60   HALT 0
```

The seed material sits right after vk26-alice-2's digest at 0x2400, so
Hash_df's input is never copied. The 5-byte prefix goes just before it, at
0x23fb, the counter byte rewritten for the second hash. V lands at 0x440,
where vk26-alice-4's Generate keeps it, so the prefix for C goes just before
V and C's Hash_df too reads in place. The two hashes for each are written
whole, 64 bytes, and the 9 bytes past 55 are left where Generate's own
fields are cleared or overwritten next. The hash is `ecall` with t0 = 2,
exp228's HASHB.

## What is proved

[proof/Seed.lean](./proof/Seed.lean), on Lean's own axioms only (no `sorry`,
no `native_decide`), against vk26-alice-2's and vk26-alice-4's proofs in
alice's package ([`../lean/Alice/Trust.lean`](../lean/Alice/Trust.lean),
[`../lean/Alice/Drbg.lean`](../lean/Alice/Drbg.lean)), which this experiment
moved there as their second user:

- **`inst_run` / `inst_boot`**: the region holds the kernel at its start,
  the seed material's length S ≤ 0x80, m and the interval at 0x2480. Then
  the kernel halts with 0 after exactly 241 instructions, the region then
  `Laid`:
  - V at 0x440 is `dfV`, Hash_df of the seed material;
  - C at 0x480 is `dfC`, Hash_df of 0x00 ‖ V;
  - 0x03 at 0x43f, 23 and 51 zeros, the number 1, m, the interval and the
    counter 1: each of `Drbg.generate_run`'s hypotheses, byte for byte;
  - every byte outside what it wrote as it was.

  This holds for *any* `env.hash`.
- **`chain`**: an image holding vk26-alice-2's kernel and its inputs (the
  KAT, 2048 samples), a nonce at 0x2420, and at 0x2480 the length 48, m and
  the interval. Then:
  1. vk26-alice-2's kernel halts with its code (`Trust.from_boot`);
  2. that code is 0 **if and only if** the hash passed the KAT and both
     windows passed their tests (`code_zero_iff`);
  3. with 0, the shell's step (`restart`: the next kernel's bytes at the
     region's start, every other byte as the last kernel left it, the pc at
     base, any registers) and this kernel halts with 0 after 241;
  4. the shell's step again, and vk26-alice-4's Generate halts with 0
     after `COST m`;
  5. block j at 0x600 is Hash(V + j) for V = Hash_df(digest ‖ nonce)
     (`seedMat`): the digest of the second window as vk26-alice-2's kernel
     wrote it, the 16 bytes of the nonce as the shell wrote them.

The steps underneath:
- `df_run`: one of Hash_df's hashes, seven instructions (`dfHash`): the
  counter byte stored, then HASHB.
- `zero_loop`: 46 words of zeros, by induction (`ZInv`).
- `c_input`: what C's HASHB reads is 0x00 ‖ V with its prefix.
- `code_loaded`, `loaded_past`: the shell's step leaves a kernel's code
  where `CodeAt` wants it, and the rest of the region alone.

Eleven wrong versions are each refused (`proof/mutants.txt`):
- Hash_df told 432 bits;
- V's second hash written over C;
- C hashed over 60 bytes;
- C's second hash with the counter 1 again;
- one word fewer of zeros;
- the counter starting at 2;
- the byte before V 0x02, not 0x03;
- and four wrong claims: one instruction fewer, C without its 0x00, a seed
  material with 15 bytes of the nonce, a chain that goes on when the
  start-up window failed.

**Not proved:**
- **The shell's step.** `restart` is a definition: the shell in C is held
  to it by the RTL (the region after each run hashes as seed.py says) and
  by checking each kernel's bytes against its kernel.sha256, not by proof.
- **Constant time.** As in vk26-alice-4, lean/Rv32/Ct.lean's checker knows
  HASH and HALT but not HASHB, so it cannot be asked.
- **Which function the hash is.** NIST's vectors say SHA-256 for
  Instantiate and Generate; vk26-alice-2's KAT says so for HASH on the chip.
- **The nonce's uniqueness.** It is the shell's round counter; a board that
  restarts reuses nonces. SP 800-90A wants a nonce never repeated for the
  same entropy, and the entropy here is fresh each round.

## The reference, and the differential

- [`seed.py`](./seed.py) writes the chain from the standard's text:
  vk26-alice-2's kernel as alice's [`trustref.py`](../tools/trustref.py)
  states it, Instantiate and Generate from
  [`hashdrbg.py`](../tools/hashdrbg.py). Both moved into alice's
  [`tools/`](../tools/) when this experiment became their second user;
  vk26-alice-2's `trust.py` and vk26-alice-4's `drbg.py` import them.
  `inst_region` is the whole 64 KiB region after the Instantiate kernel.
  `python3 seed.py` runs every NIST case through Instantiate and two
  Generates: all 120 give NIST's ReturnedBits.
- [`differential/differential.py`](./differential/differential.py) runs the
  three kernels on the Lean model (`rv32run`) and the RTL, chained as the
  shell chains them:
  - every NIST case: the Instantiate kernel's region seed.py's, the model
    after exactly 241 instructions, then Generate twice from it, the
    second's bits NIST's;
  - every stream of trustref.py's, 14, through the whole chain with a
    different nonce each: alice-2's code as trustref.py says (0, 1 or 3),
    and with 0 the bits seed.py's;
  - three expected KAT digests the hash fails: the chain stops at the first
    kernel with 2.

  All pass.

## The shell

[`shell/`](./shell/), built twice by [`build.sh`](./build.sh): for the Pico
2 (`build/vk26-alice-5.uf2`, the first 64 KiB of flash: the code, the three
kernels and the 120 cases, 49,076 bytes) and for the RTL
(`build/sim.bin`). A round, forever on the chip:

1. **Every NIST case.** The region zeroed, the Instantiate kernel at its
   start, the seed material (entropy ‖ nonce ‖ personalization) at 0x2400,
   m = 4, the interval 2 and its length at 0x2480. The Instantiate kernel
   runs; then vk26-alice-4's kernel is put in its place and runs twice.
2. **The chain, twice**, on 2048 samples from the TRNG, drawn once a round:
   vk26-alice-2's kernel, its KAT and samples as its shell puts them, the
   round as a 16-byte little-endian nonce at 0x2420, the length 48 at
   0x2488. With 0, the Instantiate kernel is put in, then Generate. The
   second time the shell flips one bit of HASH's answer to the KAT, so the
   chain must stop at the first kernel with 2.

Before each kernel runs, its bytes in the region are checked against its
kernel.sha256. HASH and HASHB are answered by the shell, their arguments
held to what the model accepts (`tools/hazard3/harness/hashcall.h`). On the
chip both go to the RP2350's SHA-256 block, HASHB through vk26-alice-4's
padding, now alice's [`../shell/hashb_chip.h`](../shell/hashb_chip.h)
(vk26-alice-4's UF2 is byte for byte the same); on the RTL to
`tools/hazard3/harness/sha256.c`.

The checks, numbered as the LED counts them:

1. a kernel's bytes were its kernel.sha256's;
2. every halt code as it must be: 0 for every NIST run; alice-2's 2
   exactly when the shell spoiled the KAT's answer; Instantiate and
   Generate after it 0;
3. every minstret the RTL's (below);
4. a NIST case's region 0x400..0x600 after Instantiate hashes to what
   seed.py says, and its second Generate's bits are NIST's; alice-2's KAT
   scratch holds what HASH answered, and with 0 its digest is SHA-256 of
   window 1;
10. the TRNG gave nothing.

What the chain's bits are for the TRNG's samples, nothing on the chip can
say: the samples are new each round. The shell sends every stage instead,
and the page and `fixtures.py --board` do it all again.

### One instruction more, explained

vk26-alice-1 and vk26-alice-2 found the RTL counting one instruction more
than the proof plus the harness's for some halt codes, and wrote it down as
a pattern, not an explanation: it appeared when the halting `ecall` was not
the kernel's last instruction. vk26-alice-3, whose `ecall` is last, saw no
extra one.

Here one kernel showed both. The Instantiate kernel alone counts 260 on the
RTL (241, plus 3 for the harness, plus 4 for each of four HASHB calls); in
the chain it counts 261, the same kernel on the same kind of input. Its
`ecall` is its last instruction both times. What differs is the word after
it: zeros alone, vk26-alice-2's code in the chain, which the shell leaves
past the Instantiate kernel's 244 bytes, as `restart` says. Putting each of
five words at 0xf4, right after the `ecall`, and running the kernel alone:

| the word at 0xf4 | minstret |
| --- | --- |
| 0x00000000 | 260 |
| `addi x0, x0, 0` (nop) | 261 |
| `addi x10, x0, 1` | 261 |
| 0xffffffff | 260 |
| `ecall` | 261 |

So Hazard3 counts one more when the word after the halting `ecall` is a
legal instruction, and not when it is an illegal one (all zeros and all
ones are both illegal in RV32I). That accounts for every count across the
five experiments:
- vk26-alice-1's HALT 0 and vk26-alice-2's HALT 0, 1 and 2 are followed by
  more of their own code: one more;
- vk26-alice-2's HALT 3 and vk26-alice-3's halt are their kernels' last
  instructions, followed by the zeros before the samples: none;
- vk26-alice-4's HALT 0 is followed by its RESEED branch and HALT 1 by its
  ADD subroutine: one more each, 4318 and 11. Its README counted that one
  as the harness's, "3 and 1 around every run"; the Instantiate kernel
  alone, 241 + 3 + 4 × 4 = 260, shows the harness's share is 3. It is measured on the RTL; that the chip
counts the same is vk26-alice-1's and vk26-alice-2's logs, where it did.
The shell holds the chip to each figure: 260 for a NIST case's
Instantiate, 261 in the chain (check 3).

### On the RTL

On the RTL the shell runs one round, the TRNG's stand-in its samples, and
prints minstret and mcycle of every run, HASH and HASHB in software
(`sha256.c`), so most of each mcycle is the hash:
- every NIST case: minstret 260, 4318 and 4318, its state and bits right;
  Instantiate 36,830 cycles for the 60 cases whose seed material is 48
  bytes and 46,718 for the 60 whose is 80 (Hash_df's input one SHA-256
  block or two), every Generate 42,749;
- the chain from the stand-in TRNG: vk26-alice-2's kernel halted with 0 at
  34,897 instructions and 381,651 cycles, then Instantiate at 261 and
  36,830, Generate at 4318 and 42,749;
- the chain with the KAT spoiled: halted with 2 at 51 instructions, and
  nothing after it.

Seven wrong shells are each caught by the check they name:
- kernel.sha256 not the Instantiate kernel's (1);
- HASHB answered one byte short (4, the state after Instantiate);
- the seed material's length given one long (4);
- vk26-alice-4's kernel never put in, so Instantiate runs again (3);
- one instruction more expected for a Generate (3);
- the second chain's KAT not spoiled after all (2);
- a trap in the shell itself (a fault, not a check).

### The lines

```
SEED round i s bytes           a NIST case's seed material, s bytes
STATE round i k bytes          V (k = 0) and C (1) after Instantiate
BLOCK round i j bytes          block j of the second Generate
RUN round i n minstret mcycle  n = 0 Instantiate, 1 and 2 the Generates
CASE round i name              the case, every check passed

BITS round s k w0 … w15        chain s's samples 512k to 512k + 511
KAT round s spoil bytes        HASH's answer to the KAT, as alice-2's kernel saw it
TRUST round s code minstret mcycle
                               alice-2's kernel; with code 0 only:
DIGEST round s bytes           its digest of window 1, at 0x2400
CSTATE round s k bytes         V (0) and C (1) after Instantiate
CBLOCK round s j bytes         block j of Generate
CRUN round s n minstret mcycle n = 0 Instantiate, 1 Generate
CHAIN round s code             the chain, every check passed; its nonce is the round

REVISION 1, ROUND round cases  every round
```

### The LED

A short blink as each NIST case ends, about one a second. After each chain,
its code in flashes: one long light for 0 (bits made), two short ones for
the spoiled KAT; then 2 s dark. speak.h's own codes as before: N flashes and
3 s dark is a USB stage; 2 s of light first is an error, its count the check
that failed.

## The page

[`seed.html`](./seed.html) does every stage again from what the board sends,
sharing nothing with the kernels, the shell or seed.py:
- SP 800-90B's tests over the samples: alice's
  [`../pages/health.js`](../pages/health.js), vk26-alice-1's and
  vk26-alice-2's pages' too;
- the KAT and the digest: the browser's own SHA-256 (WebCrypto);
- Hash_df and Instantiate: this page's;
- Generate: alice's [`../pages/drbg.js`](../pages/drbg.js), which this
  experiment moved out of vk26-alice-4's page as its second user.

A NIST case is right when the page's Instantiate of its seed material is the
board's V and C, its two Generates end in the board's four blocks, and every
minstret is the RTL's. A chain is right when:
- HASH's answer to the KAT is SHA-256's, with the one bit flipped when the
  shell says it spoiled it;
- the code is what that answer and the samples' tests give;
- with 0, the digest is SHA-256 of window 1, V and C the page's
  Instantiate of digest ‖ nonce (the round), the blocks its Generate, and
  every minstret the RTL's: 261 for the chain's Instantiate;
- with any other code, nothing after TRUST.

A case or chain one of whose lines never arrived is incomplete and claims
nothing.

- **The tests:** [`page_test.mjs`](./page_test.mjs) runs the page's checking
  code under node on [`fixtures.py`](./fixtures.py)'s logs, written from
  seed.py, hashdrbg.py and trustref.py:
  - two good rounds of all 120 cases and both chains;
  - for a NIST case: a bit of V, a bit of a block, the seed material a byte
    short, the Instantiate kernel's minstret off;
  - for a chain: the start-up window digested instead, a bit of the digest,
    the nonce left out, a bit of C, a bit of a block, Instantiate counted
    260 as it is alone, the spoiled chain going on to bits, the KAT
    answered wrong with nothing spoiling it;
  - the TRNG stuck at 1 and a run across the seam: both chains stopped by
    the tests, nothing wrong;
  - a BLOCK and a BITS line lost, a page that joins mid-case, one Generate
    30 cycles slower (nothing wrong, the cycles differ).

  Each wrong log is caught, and the page says at which stage.
- **Wrong pages:** ten, made from the built page, are caught.
- [`../pages/browser.mjs`](../pages/browser.mjs) runs the built page in
  headless Chromium against a stand-in board.

## Running it on a board, from a phone

Needs a Pico 2 and an Android phone with Chrome; one BOOTSEL press.

1. Hold BOOTSEL, plug the Pico 2 into the phone, and drop
   `build/vk26-alice-5.uf2` on the drive that appears.
2. Watch the LED: a short blink a case, about one a second; after the
   120th, one long light (the chain made bits), 2 s dark, two flashes (the
   spoiled chain stopped), 2 s dark.
3. Open `build/seed.html` from the Files app with Chrome, press Connect and
   choose "vk26-alice-5". Wait for one ROUND line, about two minutes. Then
   press Save and send the file back as an attachment; it goes into
   `board/` as it is.

What the run will say, stated before it happens:
- **Every NIST case right, as on the RTL.** Every piece the chip runs here
  has run on a board before: HASHB's padding for 55 and 56 bytes in
  vk26-alice-4. Hash_df's HASHB is 53 or 85 bytes for V (5 bytes of prefix
  and a seed material of 48 or 80) and 61 for C: lengths the padding has
  not met on a board. If it is wrong for any of them, the first case fails check 4.
- **The TRNG's chain: code 0** each round, with the bits the page makes
  again; the spoiled one stopped with 2. A code 1 or 3 from the TRNG would
  be the tests doing their job, not a failure, and the page says so.
- **minstret** 260, 4318, 4318 for each NIST case; in the chain alice-2's
  34897, then 261 and 4318: the RTL's, the one more included.
- **mcycle: not predicted.** vk26-alice-4's board found the first Generate
  slower for some cases, by where they lie in flash.

## On the board

[`board/round1.txt`](./board/round1.txt): a Pico 2 running
`vk26-alice-5.uf2` (`a411ebbe…`, committed in 8a4ffa0), the page on a
phone, the file Save gave back, kept as it came.

The page joined at round 0's case 31 and saved during round 1's case 113.
It judged 202 NIST cases right, 0 wrong and 0 incomplete, and both of
round 0's chains right: one gave bits, one was refused at the KAT. It saw
no FAIL line, and every status line says `dropped=0 errors=0`.
`fixtures.py --board` agrees:
- every case's seed material is NIST's for its name, its V and C
  hashdrbg.py's instantiation, its second Generate's 1024 bits NIST's
  ReturnedBits;
- round 0's chain from the TRNG, done again by seed.py from its BITS
  lines: alice-2's code 0, the digest SHA-256 of window 1, V and C the
  Instantiate of digest ‖ nonce 0, the four blocks seed.py's;
- the spoiled chain: the answer to the KAT hashlib's with its first bit
  flipped, code 2, nothing after it;
- every minstret the RTL's.

The predictions:
- **Every NIST case right: held.** 104 of the cases have a 48-byte seed
  material and 99 an 80-byte one, so the chip's SHA-256 block answered
  HASHB on 53 and 85 bytes for V and 61 for C, through vk26-alice-4's
  padding, now `hashb_chip.h`, and got SHA-256 each time.
- **The TRNG's chain, code 0: held,** once, in round 0. The samples' tests
  passed and the page made the same 1024 bits from them. The spoiled chain
  stopped with 2 at 51 instructions. Round 1's chains were not reached
  before Save.
- **minstret: held** in every run: 260, 4318, 4318 for each case; 34,897,
  261 and 4318 in the chain; 51 for the spoiled one. So the chip, too,
  counts the same Instantiate kernel 260 alone (203 times) and 261 after
  alice-2's code: the one more is on silicon, where the word after the
  `ecall` is an instruction, and not where it is zero.
- **mcycle, not predicted:**
  - Every second Generate took 15,088 cycles, all 203; vk26-alice-4's
    took 15,078.
  - Instantiate took 9,212 at the least for a 48-byte seed material (62 of
    104) and 11,372 for an 80-byte one (78 of 99): 2,160 more for the two
    extra SHA-256 blocks of V's two hashes, 1,080 a block.
  - The chain's Instantiate took 9,212, the fastest NIST one's figure,
    though it retired one more instruction.
  - vk26-alice-2's kernel took 58,945 cycles for code 0 and 1,547 for the
    spoiled KAT.

  The slow runs (an Instantiate or a first Generate) fall in 40 cases, and
  they come in clusters 16 cases apart: 0–4, 16–19, 31–38, 47–50, 63–69,
  79–82, 95–99, 111–113. A case is 260 bytes of the table in flash, so 16
  cases is about 4 KiB. Of the 83 cases seen whole in both rounds, 28 were
  slow in both. That is vk26-alice-4's pattern again, with a period this
  time. It points at where a case's bytes lie in flash and the XIP cache,
  as vk26-alice-3 measured; this run did not probe it.

## What it does not say

- That the TRNG's samples carry the entropy SP 800-90B asks for: the
  health tests exclude a source plainly broken, and say nothing more.
- That the shell does only what `restart` says: that is checked by the RTL
  and the region hashes, not proved.
- That a nonce never repeats: it is the round, and a board restarted starts
  again at 0.
- Anything about reseeding, prediction resistance or additional input.
- That the one more is a property of Hazard3 beyond these runs: five
  words after one `ecall` on the RTL, and on the chip this kernel's 260
  and 261 and two earlier experiments' logs.
- That the chain works every round: the log holds one round's chains.
- Why some first runs are slow: the clusters fit the cache explanation,
  and this run did not probe it.

## What the trial found in the call's settings

Found while making this experiment, and recorded in
[alice's README](../README.md#五預期會測到的徵集設定問題):

- **The judge's bundle must follow `import`.** Moving vk26-alice-2's and
  vk26-alice-4's proofs into alice's package left their `proof/*.lean` a few
  lines of `import`, and G1.5 failed: J1's bundle had no proof to read.
  Fixed in its own commit: `judge-bundle.sh` follows `import Alice.X` into
  the proposer's package, with a selftest case.
- **Extraction at the second copy, five times.** vk26-alice-2's and
  vk26-alice-4's Lean, their Python references, vk26-alice-4's padding and
  its page's Generate each had a second user here. All moved into alice's
  shared directories; both kernel.bin files and vk26-alice-4's UF2 stayed
  byte for byte the same. `duplication.sh` found two names clashing
  (`rounds`, `chain`) and one copy in vk26-alice-4's fixtures that
  `alice/tools/lines.py` already had.
- **The one more instruction**, above: not a setting, but the question
  vk26-alice-1 and vk26-alice-2 left for a later experiment, closed.

## Files

| File | What |
| --- | --- |
| [proof/Seed.lean](./proof/Seed.lean) | the kernel, `inst_run`, `inst_boot`, `chain`; writes kernel.bin |
| [proof/mutants.txt](./proof/mutants.txt) | eleven wrong kernels and claims |
| kernel.bin, kernel.sha256 | the Instantiate kernel, as the proof writes it |
| [seed.py](./seed.py) | the chain from the standard's text |
| [differential/differential.py](./differential/differential.py) | model and RTL against seed.py |
| [gen.py](./gen.py) | what the shell compiles in, with the RTL's counts |
| [shell/](./shell/), [build.sh](./build.sh) | the shell, for the chip and the RTL |
| vk26-alice-5.uf2.sha256, build-toolchain.txt | the UF2's hash, and the clang it was built with |
| [seed.html](./seed.html) | the page |
| [fixtures.py](./fixtures.py), [page_test.mjs](./page_test.mjs) | the page's tests; `fixtures.py --board` for a saved log |
| [check.sh](./check.sh), [run.sh](./run.sh), [capture.txt](./capture.txt) | the checks, and their run recorded |
| [board/round1.txt](./board/round1.txt) | the log a phone saved from a Pico 2 |
| [WHY.zh-TW.md](./WHY.zh-TW.md) | for students, in Traditional Chinese |

## Expected output

[capture.txt](./capture.txt), recorded by `run.sh` from a clean commit.

Pasted from it — the theorems, the mutants, NIST's vectors, the build, the
first and last NIST cases and both chains on the RTL:

```
=== vk26-alice-5 — the seed the tests passed ===
recorded at 2026-10-15T01:21:21Z from commit d5aed77

>>> the theorems, and what they rest on
'Seed.inst_run' depends on axioms: [propext, Classical.choice, Quot.sound]
'Seed.inst_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
'Seed.chain' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
inst_run       Hash_df is told 432 bits, not 440 (00 00 01 b0)                                refused in inst_run
inst_run       V's second hash is written over C, not after V's first                         refused in inst_run
inst_run       C is Hash_df of 60 bytes, V's last left off                                    refused in inst_run
inst_run       C's second hash has the counter 1 again                                        refused in inst_run
inst_run       one word fewer of zeros: the number 1's field is not cleared                   refused in inst_run
inst_run       the counter starts at 2                                                        refused in inst_run
inst_run       the byte before V, which Generate's H needs, is 0x02                           refused in inst_run
inst_run       the claim: one instruction fewer to the halt                                   refused in inst_run
inst_run       the specification: C is Hash_df of V, the 0x00 before it left off              refused in inst_run
chain          the specification: the seed material is the digest and 15 bytes of the nonce   refused in chain
code_zero_iff  the claim: the chain goes on when the start-up window failed                   refused in code_zero_iff

>>> seed.py, from SP 800-90A's text, against NIST's vectors
120 of 120 NIST cases: the Instantiate kernel's region holds hashdrbg's V and C, and two Generates from it give NIST's ReturnedBits

>>> the shell, for the chip and for the RTL
build/expect.h: Instantiate d89e5fba3fed788e…, alice-2's a02eb99737e609aa…, alice-4's de65172659774701…, 120 NIST cases; RTL minstret Instantiate 260 (the proof's 241; 261 in the chain), Generate 4318, alice-2's 34897 17470 51 34885 for codes 0 to 3
build/vk26-alice-5.bin  49076 bytes, the build allows 65536
build/vk26-alice-5.uf2  98304 bytes  sha256 a411ebbef2fd8a92e484e72eada821dc916b5d049cb469a9df1dd3e6e58c72bd

>>> on the RTL, every NIST case: CASE i, then minstret mcycle of Instantiate and two Generates;
>>> then each chain: CHN s code, alice-2's minstret mcycle, and with 0 Instantiate's and Generate's; then DONE cases
43415345 00000000 00000104 00008fde 000010de 0000a6fd 000010de 0000a6fd
43415345 00000001 00000104 00008fde 000010de 0000a6fd 000010de 0000a6fd
...
43415345 00000077 00000104 0000b67e 000010de 0000a6fd 000010de 0000a6fd
43484e00 00000000 00000000 00008851 0005d2d3 00000105 00008fde 000010de 0000a6fd
43484e00 00000001 00000002 00000033 00002d89
444f4e45 00000078 exit=0
```
