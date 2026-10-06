# exp212 — the cycles the chip counts

<!-- SPDX-License-Identifier: Apache-2.0 -->

**exp213's key generator and signer on a Pico 2, under sixteen seeds: each
seed's key generation, then a signature with the tree it just made, and once
the signer on another message. exp207 proved that the seed cannot move a
single step of either kernel, and the RTL counted the same cycles under every
seed it was given. This asks the chip: does every seed take the same
`mcycle` on silicon — and is it the RTL's number?**

This is the verified-kernel road's "time on the chip" step, and the first
time `mcycle` is read on silicon. exp209 and exp210 settled `minstret`, the
number of instructions; exp210's README says outright that it says nothing
about time.

## Running it on the board

You need a **Pico 2** (not a Pico 2 W), a USB cable, and a computer — the same
as exp210.

1. Check the file: its SHA-256 must be the one in
   [`exp212.uf2.sha256`](./exp212.uf2.sha256).
2. **If the board has ever run exp139 to exp145**, or you are not sure, flash
   [exp209](../exp209-the-count-the-led-blinks/)'s UF2 first, the same way —
   exp210's README, *Why exp209 first*, says why. A board that last ran
   exp209 or exp210 needs nothing.
3. Hold **BOOTSEL**, plug the board in, then let go. A drive called `RP2350`
   appears.
4. Copy `exp212.uf2` onto it. The drive disappears and the board restarts.
5. The LED comes on and stays on while the runs go. **Wait until it starts
   to blink** — give it three minutes — then say which of these it is. This
   is revision 4; *What the board has said* below is why.

### What the LED says

| You see | It means |
| --- | --- |
| **slow blinking**, about 2 s on, 2 s off, without pause | every seed took the same cycles, and they are the RTL's |
| **1 flash**, then about 2 s dark, repeated | a check failed: the kernel, its halt, its region, its `minstret` or the SHA-256 block |
| **2 flashes**, then dark | **silicon − RTL = a + c·S**: a fixed cost per HASH call (and per run) — the trap in and out |
| **3 flashes**, then dark | **silicon − RTL = a + b·minstret**: a fixed cost per instruction — the memory |
| **4 flashes**, then dark | the same difference on every kind of run: a fixed cost per run only |
| **5 flashes**, then dark | the difference is on neither line |
| **6 flashes**, then dark | two seeds of a kind took different times, or the other message took the signer's |
| on, steady, after three minutes | the shell hung, or trapped itself |
| dark | the shell never ran |

Each flash is about 0.36 s on and 0.36 s off, and the dark between groups
about 2 s. **Say "slow", or how many flashes.** Every answer but 1 and 6
says again that the seed did not move the time; 2 to 5 say how silicon's
cycles differ from the RTL's, which revision 3 found that they do.

## What the shell does

For each of 16 seeds, from `random.Random(212)`:

1. **the key generator**: zero the region, write `keygen.bin`, the seed and
   the 0xee scratch exactly as [`mss.py`](../../tools/hazard3/mss.py)'s
   `keygen_image` does, and run it; keep the 992-byte tree it wrote;
2. **the signer**: zero the region, write `sign.bin`, the message, leaf 5,
   the seed and *that tree* as `sign_image` does, and run it.

Before all of it, seed 0's key generation once, as a **warm-up**: held to
every check below, but its cycles are not compared with anything. Revision 2
found the shell's first run out of line on the board (*What the board has
said*), and the warm-up is there so that no timed run is the first.

After the first seed's signature, the signer once more on another message,
under the same seed and tree. The message is public: it sets how far each
chain walks, so it must move the time, and if it does not the measurement is
blind.

Every run is checked — the same kind of check exp210 made, so that equal
cycles cannot come from a run that did something else:

1. the kernel's bytes in SRAM hash to exp213's `.sha256` (the shell's own
   software SHA-256, never the block);
2. it halted with code 0, not a fault;
3. **the whole 64 KiB region hashes to what the Lean model left there**,
   run at `0x20070000` on the same image;
4. `minstret` is the RTL's for that kind of run;
5. the SHA-256 block never flagged a write while busy.

and its `mcycle` is kept. [`shell/verdict.h`](./shell/verdict.h) then
decides, from all 34 runs — the warm-up's checks, and the other 33's checks
and cycles — the first of these that applies:

| | |
| --- | --- |
| **slow** | every check passed; the 16 key generations took one number of cycles, the 16 signatures one number, the other message another; and all three are the RTL's |
| **6** | two seeds of a kind took different numbers, or the other message took the signatures' |
| then, with d = silicon − RTL for each of the three kinds: | |
| **4** | d the same for all three, and not 0 |
| **2** | d = a + c·S, S the kind's HASH calls (17183, 547, 517) |
| **3** | d = a + b·minstret (145191, 5915, 5705) |
| **5** | neither |

**1**, a failed check or a missing run, comes before all of them. A line
through three points is tested exactly, in 64-bit integers:
`(d₁ − d₀)(x₂ − x₁) = (d₂ − d₁)(x₁ − x₀)`. The three kinds' (S, minstret)
points are not on one line themselves, so a d that is not constant can fit
only one of the two — and a constant one fits both, which is why 4 is asked
first.

## What is counted

[`harness.S`](../../tools/hazard3/harness/harness.S) holds `mcycle` and
`minstret` with `mcountinhibit` everywhere except while the kernel runs, and
zeroes them before it starts. So the count is the kernel's own time, from the
`mret` into it to the first instruction of the trap that ends it, with every
HASH call's trap in and `mret` back — and **not** the time the SHA-256 block
or the shell's handler takes. That is exactly the part exp207's theorem is
about: the kernel's steps and addresses, not HASH's.

The two things on silicon that could still move it with the seed are the
ones the theorem's observer cannot see: an instruction whose time depends on
its operands, and a memory whose time depends on the data. Neither kernel
multiplies or divides, and Hazard3 has no cache in front of SRAM.

**Why 2 is a possible answer.** On the chip the shell runs from flash,
through the XIP cache, and the harness's trap entry and its `csrwi
mcountinhibit, 0; mret` are among the instructions inside the counted window.
On the RTL they come from RAM. A per-trap difference there would make every
seed's number equal and every one different from the RTL's — two flashes.

**Why 3 is.** The same window, the first time. Before the first key
generation's first HASH call, the harness's `trap` has never run, so its
first instruction is a miss in the XIP cache, inside the count; after it the
whole shell, under 8 KiB, sits in the 16 KiB cache. If that is what moved,
only run 0 is long — the seed had nothing to do with it. The LED cannot say by how much; a USB report could, and was decided
against (exp210's reasoning: the person is needed to read the LED anyway, and
a USB stack would multiply the shell's trust base).

## What is checked without the board

`check.sh`:

- **`verdict.h` on the host**, fed made-up results built on the real HASH
  calls, minstret and RTL cycles: each of its seven answers from the
  results that must give it, eighteen cases; and eleven wrong versions of
  it, each caught — among them a HASH line drawn through minstret, a sign
  wrong in the line test, and a warm-up timed as a key generation;
- `gen.py`: 34 runs on the Lean model, each halting with code 0 at one count
  per kind; the key generator's tree is `mss.py`'s `tree_of` (so the signer's
  image the chip builds from it is `sign_image`); and the RTL's three runs at
  `minstret = count + 3 + 4·S`;
- the UF2, read back independently: family `absolute`, every block in the
  first 32 KiB, exactly the image, the jump and the IMAGE_DEF block; and,
  with the recorded toolchain, byte for byte the committed hash;
- **the same shell on the Hazard3 RTL** with two seeds (a key generation
  takes the RTL minutes): every check of every run passes, each run reads
  exactly the `mcycle` the RTL harness counted for its kind, and the verdict
  is slow.

The SHA-256 block's driver is exp210's, moved to
[`tools/hazard3/shell/sha_hw.h`](../../tools/hazard3/shell/sha_hw.h) for
its second user; exp210's check still holds it against the fake, and
exp210's board ran it. `led.h` gained the counted flashes. exp209's and
exp210's UF2s still build byte for byte.

## What only the board can say, and what it cannot

- **Whether 16 seeds take the same `mcycle` on silicon**, for each kernel.
- **Whether that number is the RTL's.**
- **Not the wall-clock time.** `mcycle` counts the core's clock, whatever it
  runs at; the clock is the bootrom's, and nothing here measures it. A
  logic analyser on a GPIO would, and was left out: it would be this
  repository's first extra instrument.
- **Not that every seed is safe.** Sixteen seeds on one board is evidence;
  exp207's theorem is the claim about every seed, and holds on a core with
  no data-dependent timing — which is what this run is evidence for.

## What the board has said

| Run | UF2 (SHA-256) | Reported, as said | Read as |
| --- | --- | --- | --- |
| 1 | revision 1, `24846d1362f8dbb6f28c673a6c5e68617abdbe19bf36a79abcdc8381755c02b3` | **「快閃」** — fast blinking | **something did not hold, and revision 1 could not say what**: its fast blinking was a check failing, any two seeds of a kind differing, and the other message taking the signer's time, all at once |
| 2 | revision 2, `02107d4fc97af415ed25a6bb63b2913f1d23b71710f6ee3dc21c7c2e48780d88`, the same board | **「閃 3 下」** — three flashes | **only the first key generation was out of line.** All 33 runs passed every check — the kernel, its halt with code 0, all 65,536 bytes of its region as the Lean model left them, the RTL's minstret, the SHA-256 block's error flag. Key generations 2 to 16, under fifteen different seeds, took one number of cycles; all sixteen signatures took one number; the other message took a different one |
| 3 | revision 3, `9d4e60b0282a4b4779b80f1f597132165bf6af4cbc3417a29f3de6df0db90c3e`, the same board | **「閃 2 下」** — two flashes | **every seed alike, and not the RTL's number.** All 34 runs passed every check. After the warm-up, all sixteen key generations — seed 0's timed run among them — took one number of cycles, all sixteen signatures another, and the other message a third; and at least one of those three is not what the RTL counted |

Revision 1 answered slow, a double flash, or fast, and fast was five
different things. Revision 2 runs the same 33 runs with the same checks and
says which of the five came first, as a count — 3 being the one that
separates the leading suspect, the shell's own cold XIP cache on run 0,
from the seed. Nothing else changed: `verdict.h` and the LED's last word.

**What run 2 settles.** On silicon, fifteen seeds of the key generator and
sixteen of the signer could not be told apart by `mcycle` — each one exact to
the cycle, not within a tolerance — and the measurement was not blind: a
public input moved it. That is what exp207's theorem predicts, measured.

**What it does not.** Why run 0 was different. It came first, under seed 0,
and only it: the cold XIP cache on the harness's `trap` is the explanation
that fits, and it is consistent with this answer, but the answer does not
single it out — seed 0 also ran only once, first. And whether silicon's
numbers are the RTL's: answer 3 is decided before the RTL is consulted, so
that question is still open.

Revision 3 settles both in one flash: it runs seed 0's key generation twice,
times only the second, and compares every number with the RTL's. If the
second joins the others, the first run's difference was the shell's cold
start, and the answer is slow or 2; if it is 3 again, seed 0 itself is
different, which is a finding about the seed.

**What run 3 settles.** Seed 0's timed key generation joined the other
fifteen, so revision 2's odd run was the shell's own first run, not the
seed: once nothing timed is first, **sixteen seeds of the key generator and
sixteen of the signer take the same `mcycle` on silicon, to the cycle**, and
a public input still moves it. That is the claim this experiment set out to
check, and exp207's theorem predicted it.

**What it adds, and leaves open.** Silicon does not count the RTL's cycles
for these kernels, though it counts the RTL's instructions (check 4 held on
every run). Which of the three numbers differ, and by how much, one LED
cannot say. The explanation already written above fits: the harness's trap
entry and `mret` are fetched from flash through the XIP cache inside the
counted window on the chip, from RAM on the RTL — a per-trap cost would move
every number and no seed. It would also make the difference grow with the
HASH calls, which revision 4 tests without reading a number off the LED:
whether silicon minus RTL is `a + c·S` for the same `a` and `c` across the
three kinds of run — or `a + b·minstret`, the other explanation, which the
three kinds tell apart from the first.

Not yet run on a board: revision 4.

## Running it

```sh
./build.sh       # build/exp212.uf2, and the RTL build; gen.py takes ~9 minutes the first time
./check.sh       # everything above; no board
./run.sh         # records capture.txt
```

Needs clang, lld, llvm-objcopy, cargo, a host C compiler, Lean
(`tools/lean/setup.sh`) and the Hazard3 testbench (`tools/hazard3/setup.sh`).

## Expected output

The board half is in **What the board has said** above, as reported. The
cloud half:

```text
=== exp212 — the cycles the chip counts (cloud half) ===
recorded at 2026-10-06T04:45:42Z from commit b8cce4a (working tree dirty — this recording is not reproducible from the commit alone)

>>> every check
PASS  no lifeline, and it says why: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back
PASS  slow: every run as the RTL counted it
PASS  slow: the warm-up alone long: the cold shell, as revision 2 saw
PASS  2 flashes: the warm-up long, every timed run off the RTL's
PASS  1 flash: the warm-up's region not the model's
PASS  1 flash: the last run's region not the model's
PASS  1 flash: a run with the wrong minstret
PASS  1 flash: one run missing
PASS  2 flashes: every seed alike, but every number off the RTL's
PASS  2 flashes: every seed alike, only the key generator off the RTL's
PASS  2 flashes: every seed alike, only the other message off the RTL's
PASS  3 flashes: the first key generation alone one cycle longer
PASS  3 flashes: the first key generation alone longer, and the rest all off the RTL's
PASS  4 flashes: the second seed's key generation one cycle longer
PASS  4 flashes: the last seed's key generation one cycle longer
PASS  4 flashes: the first key generation longer, and a signature too: not only the first
PASS  5 flashes: the last seed's signature one cycle shorter
PASS  5 flashes: the first seed's signature one cycle longer
PASS  6 flashes: the other message as long as the signer's: blind
PASS  1 flash: a schedule with no other message
PASS  verdict.h is caught when it does not count the runs
PASS  verdict.h is caught when it ignores a failed check
PASS  verdict.h is caught when it does not ask that every kind ran
PASS  verdict.h is caught when it does not compare the key generations
PASS  verdict.h is caught when it blames the first key generation when the others differ too
PASS  verdict.h is caught when it blames the first key generation when a signature differs too
PASS  verdict.h is caught when it does not compare the signatures
PASS  verdict.h is caught when it does not compare with the RTL
PASS  verdict.h is caught when it lets a blind measurement through
PASS  verdict.h is caught when it compares one run short
PASS  verdict.h is caught when it says slow off the RTL's numbers
PASS  verdict.h is caught when it times the warm-up too
PASS  verdict.h is caught when it does not check the warm-up
PASS  the shell builds for the chip and for the RTL, the chip's 8076 bytes in its 32 KiB
PASS  gen.py: 16 seeds and a warm-up, 34 runs on the model — code 0, one count per kind, the tree mss.py's — and the RTL's minstret count + 3 + 4 S
PASS  all 32 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 32 KiB of flash, 0x10000000..0x10008000
PASS  together they are exactly the 8076-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: 9d4e60b0282a4b47…
PASS  on the RTL the shell passes every check of all 6 runs, reads the RTL harness's mcycle on each, and says slow

>>> the RTL harness, once per kind of run
keygen halt code=00000000 instret=145191 cycles=195653
sign halt code=00000000 instret=5915 cycles=7600
sign-other halt code=00000000 instret=5705 cycles=7314

>>> every run the chip will make, as gen.py found it on the Lean model
keygen-warm seed  0  model count 76456  region 2bf0995d341fde7a…  RTL minstret 145191  mcycle 195653
keygen      seed  0  model count 76456  region 2bf0995d341fde7a…  RTL minstret 145191  mcycle 195653
sign        seed  0  model count  3724  region 77f82e763ab65377…  RTL minstret   5915  mcycle   7600
sign-other  seed  0  model count  3634  region 80923f9d4ca56ce6…  RTL minstret   5705  mcycle   7314
keygen      seed  1  model count 76456  region dd0abecb658d6322…  RTL minstret 145191  mcycle 195653
sign        seed  1  model count  3724  region 954a3e1cb331c580…  RTL minstret   5915  mcycle   7600
keygen      seed  2  model count 76456  region 6c2abdbb833f3932…  RTL minstret 145191  mcycle 195653
sign        seed  2  model count  3724  region 716e29cdd985a3c0…  RTL minstret   5915  mcycle   7600
keygen      seed  3  model count 76456  region b548c65d1f386677…  RTL minstret 145191  mcycle 195653
sign        seed  3  model count  3724  region aca4639e23769d05…  RTL minstret   5915  mcycle   7600
keygen      seed  4  model count 76456  region 51f7b5219cfba323…  RTL minstret 145191  mcycle 195653
sign        seed  4  model count  3724  region e62e4009b9bfb5cf…  RTL minstret   5915  mcycle   7600
keygen      seed  5  model count 76456  region 48f8e05b35a20c6f…  RTL minstret 145191  mcycle 195653
sign        seed  5  model count  3724  region 3fb70a4c9cd2e492…  RTL minstret   5915  mcycle   7600
keygen      seed  6  model count 76456  region 8696def983b4d684…  RTL minstret 145191  mcycle 195653
sign        seed  6  model count  3724  region fe0392800f149b5b…  RTL minstret   5915  mcycle   7600
keygen      seed  7  model count 76456  region ea8249ae028f3688…  RTL minstret 145191  mcycle 195653
sign        seed  7  model count  3724  region 339a2219be8788b8…  RTL minstret   5915  mcycle   7600
keygen      seed  8  model count 76456  region 7e4937698262a3e6…  RTL minstret 145191  mcycle 195653
sign        seed  8  model count  3724  region d7c7b0869e871ff4…  RTL minstret   5915  mcycle   7600
keygen      seed  9  model count 76456  region bb9fe6e58aba993f…  RTL minstret 145191  mcycle 195653
sign        seed  9  model count  3724  region d5a5aa581c6dd075…  RTL minstret   5915  mcycle   7600
keygen      seed 10  model count 76456  region 1d55925215cec136…  RTL minstret 145191  mcycle 195653
sign        seed 10  model count  3724  region df4afeeda15b2931…  RTL minstret   5915  mcycle   7600
keygen      seed 11  model count 76456  region bca03e3c9ad0cf27…  RTL minstret 145191  mcycle 195653
sign        seed 11  model count  3724  region 28d1a9680ccd76c2…  RTL minstret   5915  mcycle   7600
keygen      seed 12  model count 76456  region cdcaac0e97243db9…  RTL minstret 145191  mcycle 195653
sign        seed 12  model count  3724  region 194f24ced5e3c217…  RTL minstret   5915  mcycle   7600
keygen      seed 13  model count 76456  region a30ca1c25ce63f3a…  RTL minstret 145191  mcycle 195653
sign        seed 13  model count  3724  region c7864c773335946e…  RTL minstret   5915  mcycle   7600
keygen      seed 14  model count 76456  region 8a6a76ba226ff960…  RTL minstret 145191  mcycle 195653
sign        seed 14  model count  3724  region 23ede6692e812e3b…  RTL minstret   5915  mcycle   7600
keygen      seed 15  model count 76456  region b6bdb3ebfd9658c7…  RTL minstret 145191  mcycle 195653
sign        seed 15  model count  3724  region bedd1fdcad52cc41…  RTL minstret   5915  mcycle   7600
expect.h: 16 seeds, 34 runs

>>> the same shell on the Hazard3 RTL, two seeds (HASH in software)
run                failed  mcycle  minstret
keygen-warm seed 0 -       195653  145191
keygen seed 0      -       195653  145191
sign seed 0        -         7600  5915
sign-other seed 0  -         7314  5705
keygen seed 1      -       195653  145191
sign seed 1        -         7600  5915
52455054 00000000 exit=0
```
