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
   to blink** — give it three minutes — then say which of these it is.

### What the LED says

| You see | It means |
| --- | --- |
| **slow blinking**, about 2 s on, 2 s off | **every seed took the same cycles, and they are the RTL's** |
| **double flash**: two quick flashes, then about 2 s dark | every seed took the same cycles, **but not the RTL's number** |
| **fast blinking**, several times a second | something failed, or two seeds took different times |
| on, steady, after three minutes | the shell hung, or trapped itself |
| dark | the shell never ran |

**Say "slow", "double" or "fast".** Slow and double both mean the seed did
not move the time; double adds that silicon counts cycles differently from
the RTL, which is a finding, not a failure.

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
decides, from all 33 runs:

| | |
| --- | --- |
| **slow** | every check passed; the 16 key generations took one number of cycles, the 16 signatures one number; the other message did not take the signatures' number; and all three are the RTL's |
| **double** | all of that, except that at least one of the three is not the RTL's |
| **fast** | anything else |

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

**Why double is a possible answer.** On the chip the shell runs from flash,
through the XIP cache, and the harness's trap entry and its `csrwi
mcountinhibit, 0; mret` are among the instructions inside the counted window.
On the RTL they come from RAM. A per-trap difference there would make every
seed's number equal and every one different from the RTL's — the double
flash. The LED cannot say by how much; a USB report could, and was decided
against (exp210's reasoning: the person is needed to read the LED anyway, and
a USB stack would multiply the shell's trust base).

## What is checked without the board

`check.sh`:

- **`verdict.h` on the host**, fed made-up results: each of the three
  answers from the results that must give it, twelve cases; and eight wrong
  versions of it, each caught;
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
exp210's board ran it. exp209's and exp210's UF2s still build byte for byte.

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

(pending — no board has run this yet)

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
(pending)
```
