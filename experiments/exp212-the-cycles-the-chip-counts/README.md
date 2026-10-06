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
   is revision 2; *What the board has said* below is why.

### What the LED says

| You see | It means |
| --- | --- |
| **slow blinking**, about 2 s on, 2 s off, without pause | **every seed took the same cycles, and they are the RTL's** |
| **1 flash**, then about 2 s dark, repeated | a check failed: the kernel, its halt, its region, its `minstret` or the SHA-256 block |
| **2 flashes**, then dark | every seed took the same cycles, **but not the RTL's number** |
| **3 flashes**, then dark | **only the first key generation** took a different time; every other one, and every signature, agreed |
| **4 flashes**, then dark | the key generations differ, beyond the first |
| **5 flashes**, then dark | the signatures differ |
| **6 flashes**, then dark | the other message took the signer's time: the measurement cannot see a difference |
| on, steady, after three minutes | the shell hung, or trapped itself |
| dark | the shell never ran |

Each flash is about 0.36 s on and 0.36 s off, and the dark between groups
about 2 s. **Say "slow", or how many flashes.** Slow and 2 both mean the
seed did not move the time; 2 adds that silicon counts cycles differently
from the RTL, which is a finding, not a failure. 3 says the same about the
seed, and names the shell's own first run as the thing that moved.

## What the shell does

For each of 16 seeds, from `random.Random(212)`:

1. **the key generator**: zero the region, write `keygen.bin`, the seed and
   the 0xee scratch exactly as [`mss.py`](../../tools/hazard3/mss.py)'s
   `keygen_image` does, and run it; keep the 992-byte tree it wrote;
2. **the signer**: zero the region, write `sign.bin`, the message, leaf 5,
   the seed and *that tree* as `sign_image` does, and run it.

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
decides, from all 33 runs, the first of these that applies:

| | |
| --- | --- |
| **slow** | every check passed; the 16 key generations took one number of cycles, the 16 signatures one number; the other message did not take the signatures' number; and all three are the RTL's |
| **1** | a check failed, or a run is missing |
| **2** | every seed alike and the other message moved, but at least one of the three numbers is not the RTL's |
| **3** | the first key generation alone is out of line: the other fifteen agree with each other, every signature agrees, the other message moved |
| **4** | the key generations differ otherwise |
| **5** | the signatures differ |
| **6** | the other message took the signatures' number |

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

- **`verdict.h` on the host**, fed made-up results: each of its seven
  answers from the results that must give it, sixteen cases; and eleven
  wrong versions of it, each caught — among them one that blames the first
  key generation when the others differ too;
- `gen.py`: 33 runs on the Lean model, each halting with code 0 at one count
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

Revision 1 answered slow, a double flash, or fast, and fast was five
different things. Revision 2 runs the same 33 runs with the same checks and
says which of the five came first, as a count — 3 being the one that
separates the leading suspect, the shell's own cold XIP cache on run 0,
from the seed. Nothing else changed: `verdict.h` and the LED's last word.

Not yet run on a board: revision 2.

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
recorded at 2026-10-06T03:50:47Z from commit 7395d5e

>>> every check
PASS  no lifeline, and it says why: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back
PASS  slow: every run as the RTL counted it
PASS  double: every seed alike, but every number off the RTL's
PASS  double: every seed alike, only the key generator off the RTL's
PASS  double: every seed alike, only the other message off the RTL's
PASS  fast: the second seed's key generation one cycle longer
PASS  fast: the last seed's signature one cycle shorter
PASS  fast: the first seed's key generation alone one cycle longer
PASS  fast: the other message as long as the signer's: blind
PASS  fast: the last run's region not the model's
PASS  fast: a run with the wrong minstret
PASS  fast: one run missing
PASS  fast: a schedule with no other message
PASS  verdict.h is caught when it does not count the runs
PASS  verdict.h is caught when it ignores a failed check
PASS  verdict.h is caught when it does not compare the seeds
PASS  verdict.h is caught when it does not compare with the RTL
PASS  verdict.h is caught when it lets a blind measurement through
PASS  verdict.h is caught when it stops one run short
PASS  verdict.h is caught when it does not ask that every kind ran
PASS  verdict.h is caught when it says slow off the RTL's numbers
PASS  the shell builds for the chip and for the RTL, the chip's 7792 bytes in its 32 KiB
PASS  gen.py: 16 seeds, 33 runs on the model — code 0, one count per kind, the tree mss.py's — and the RTL's minstret count + 3 + 4 S
PASS  all 31 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 32 KiB of flash, 0x10000000..0x10008000
PASS  together they are exactly the 7792-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: 24846d1362f8dbb6…
PASS  on the RTL the shell passes every check of all 5 runs, reads the RTL harness's mcycle on each, and says slow

>>> the RTL harness, once per kind of run
keygen halt code=00000000 instret=145191 cycles=195653
sign halt code=00000000 instret=5915 cycles=7600
sign-other halt code=00000000 instret=5705 cycles=7314

>>> every run the chip will make, as gen.py found it on the Lean model
keygen     seed  0  model count 76456  region 2bf0995d341fde7a…  RTL minstret 145191  mcycle 195653
sign       seed  0  model count  3724  region 77f82e763ab65377…  RTL minstret   5915  mcycle   7600
sign-other seed  0  model count  3634  region 80923f9d4ca56ce6…  RTL minstret   5705  mcycle   7314
keygen     seed  1  model count 76456  region dd0abecb658d6322…  RTL minstret 145191  mcycle 195653
sign       seed  1  model count  3724  region 954a3e1cb331c580…  RTL minstret   5915  mcycle   7600
keygen     seed  2  model count 76456  region 6c2abdbb833f3932…  RTL minstret 145191  mcycle 195653
sign       seed  2  model count  3724  region 716e29cdd985a3c0…  RTL minstret   5915  mcycle   7600
keygen     seed  3  model count 76456  region b548c65d1f386677…  RTL minstret 145191  mcycle 195653
sign       seed  3  model count  3724  region aca4639e23769d05…  RTL minstret   5915  mcycle   7600
keygen     seed  4  model count 76456  region 51f7b5219cfba323…  RTL minstret 145191  mcycle 195653
sign       seed  4  model count  3724  region e62e4009b9bfb5cf…  RTL minstret   5915  mcycle   7600
keygen     seed  5  model count 76456  region 48f8e05b35a20c6f…  RTL minstret 145191  mcycle 195653
sign       seed  5  model count  3724  region 3fb70a4c9cd2e492…  RTL minstret   5915  mcycle   7600
keygen     seed  6  model count 76456  region 8696def983b4d684…  RTL minstret 145191  mcycle 195653
sign       seed  6  model count  3724  region fe0392800f149b5b…  RTL minstret   5915  mcycle   7600
keygen     seed  7  model count 76456  region ea8249ae028f3688…  RTL minstret 145191  mcycle 195653
sign       seed  7  model count  3724  region 339a2219be8788b8…  RTL minstret   5915  mcycle   7600
keygen     seed  8  model count 76456  region 7e4937698262a3e6…  RTL minstret 145191  mcycle 195653
sign       seed  8  model count  3724  region d7c7b0869e871ff4…  RTL minstret   5915  mcycle   7600
keygen     seed  9  model count 76456  region bb9fe6e58aba993f…  RTL minstret 145191  mcycle 195653
sign       seed  9  model count  3724  region d5a5aa581c6dd075…  RTL minstret   5915  mcycle   7600
keygen     seed 10  model count 76456  region 1d55925215cec136…  RTL minstret 145191  mcycle 195653
sign       seed 10  model count  3724  region df4afeeda15b2931…  RTL minstret   5915  mcycle   7600
keygen     seed 11  model count 76456  region bca03e3c9ad0cf27…  RTL minstret 145191  mcycle 195653
sign       seed 11  model count  3724  region 28d1a9680ccd76c2…  RTL minstret   5915  mcycle   7600
keygen     seed 12  model count 76456  region cdcaac0e97243db9…  RTL minstret 145191  mcycle 195653
sign       seed 12  model count  3724  region 194f24ced5e3c217…  RTL minstret   5915  mcycle   7600
keygen     seed 13  model count 76456  region a30ca1c25ce63f3a…  RTL minstret 145191  mcycle 195653
sign       seed 13  model count  3724  region c7864c773335946e…  RTL minstret   5915  mcycle   7600
keygen     seed 14  model count 76456  region 8a6a76ba226ff960…  RTL minstret 145191  mcycle 195653
sign       seed 14  model count  3724  region 23ede6692e812e3b…  RTL minstret   5915  mcycle   7600
keygen     seed 15  model count 76456  region b6bdb3ebfd9658c7…  RTL minstret 145191  mcycle 195653
sign       seed 15  model count  3724  region bedd1fdcad52cc41…  RTL minstret   5915  mcycle   7600
expect.h: 16 seeds, 33 runs

>>> the same shell on the Hazard3 RTL, two seeds (HASH in software)
run                failed  mcycle  minstret
keygen seed 0      -       195653  145191
sign seed 0        -         7600  5915
sign-other seed 0  -         7314  5705
keygen seed 1      -       195653  145191
sign seed 1        -         7600  5915
52455054 00000002 exit=0
```
