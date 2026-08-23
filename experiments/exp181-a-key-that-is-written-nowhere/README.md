# exp181 — a key that is written nowhere

The [identity road](../README.md#the-identity-road) asks where a board's own
secret comes from, and had three answers, all of them *not from here*: OTP
stores but does not hide ([exp154](../exp154-somewhere-to-put-a-key/)), a TRNG
key dies at reset ([exp159](../exp159-a-key-that-was-never-in-flash/)), and a
compiled-in key is readable and identical on every board — which
[exp175](../exp175-the-secret-is-the-file/) proved by forging a working WebAuthn
assertion from a `.uf2` and no board at all.

[exp179](../exp179-what-survives-a-reset/) opened a fourth: **the RP2350 does not
clear SRAM on power-on.** This is the key made out of that.

> **Verified on hardware, 2026-08-23.** Two cable pulls. The first enrolled on a
> window that came up at **51.1% one-bits**; the second reconstructed from one at
> **50.7%**, and **all 256 key bits came back**. **494 of 7,936 cells had
> changed — a 6.22% error rate** — and a 31-fold repetition code carried it with
> room to spare: 1.93 flips per key bit where 16 would be needed to break one.

## What is stored, and what is not

```text
  in flash:  helper data, a hash of the key, the enrolment's uniformity
  in SRAM:   whatever the cells settle to when power arrives
  the key:   neither
```

The helper is `H = K ⊕ w`: a code-offset fuzzy commitment, with each of 256 key
bits spread across **31 SRAM cells** and reconstruction by majority vote.
Anybody who dumps this flash gets `H`, which is the key XORed with a pattern
that exists only inside a powered chip.

**That is the property exp175 said was missing.** Its finding was that
possession of the image is possession of the identity, because the key was a
pure function of a compiled-in constant. Here the image contains no key and the
flash contains no key; what the image plus the flash gives you is one half of an
XOR whose other half you have to be holding the board to see.

## The margin, computed rather than quoted

```text
  494 of 7936 cells changed        6.22% error rate
  1.93 flips per key bit of 31     16 needed to break one
  P(a key bit fails)  6.18e-12
  P(the key fails)    1.58e-09     about one reconstruction in 632 million
```

That last number is arithmetic on **one** measurement of the error rate, and the
error rate is the thing a PUF lives or dies by. It moves with temperature, with
voltage, with the age of the part, and with how long the board was unpowered —
none of which this experiment varied. What it establishes is that at the error
rate seen on this board, on this day, the code was not close to its limit.

The error count is free, which is worth saying because it is why nothing had to
be stored to get it: **the minority in each majority vote is exactly the number
of cells that changed**. And it is exact only because every key bit reconstructed
— if one had not, its count would be inverted and nobody could tell which. So
the number is always reported beside the hash comparison, never on its own.

## Two traps, both handed over by exp179

**Enrolling on a cleared window.** exp179 measured that the flashing path zeroes
SRAM: on the boot straight after `yi26 flash`, bank 8 reads 0.00%. Enrolling
there would store `H = K ⊕ 0 = K` — the key sitting in flash in plain sight,
which is exp175's failure reinvented by the experiment meant to fix it. So
enrolment **refuses** outside a 40–60% band, and
[`capture-refused.txt`](./capture-refused.txt) is that refusal happening:

```text
  bank 8 now: 0.0% one-bits — cleared, so this board was just flashed (exp179)
  REFUSED to enrol: the window is not a power-on reading
```

It is checked in because a guard should be shown firing, not described.

**Counting a warm reset as evidence.** exp179 also measured that a reset which
keeps the power clears nothing — so reconstruction after one is exact by
construction and proves nothing at all. `breadcrumb` says how the boot began,
and anything but a genuinely fresh one is printed with `NOT EVIDENCE` beside it.
The transcript that counts says `boot #1, a power-on or a flash — nothing before
it`, and the 50.7% beside it rules out the flash.

## Why bank 8

`0x2008_0000` is outside the 512 KB the linker knows about, so nothing this
firmware places can land in it — no `.bss`, no `.data`, no stack.
[exp159](../exp159-a-key-that-was-never-in-flash/) put a key there for the same
reason, and exp179 measured that it comes up at 51.0% after power and keeps what
it holds across a reset that does not. A window in `.uninit` would work too;
this one cannot be reached by accident.

## What this is not

- **Not shown to be unique to this chip.** Uniqueness needs a second board, and
  this repository's other one [lives with a phone](../../docs/debugging-on-a-phone.md).
  What is shown is that the key is **not in the image**. Those are different
  sentences and a reader will merge them unless they are kept apart. A PUF that
  is stable but not unique is a chip that reliably reconstructs *somebody else's*
  key, and nothing here rules that out.
- **Not hidden while it is in use.**
  [exp163](../exp163-how-long-is-a-secret-in-the-open/) measured how long a key
  sits readable in SRAM and every word applies. A PUF changes where a key comes
  from, not whether it can be read while it is being used.
- **Not measured across conditions.** One enrolment, one reconstruction, one
  temperature, one board, one day. The error rate is the quantity that matters
  and there is one sample of it.
- **Not error-corrected in any sophisticated way.** A repetition code is the
  simplest thing that works and it is deliberately not a BCH or Reed–Solomon
  code: at 31 cells per bit it spends a quarter of the window on 256 bits. The
  earlier private work on this chip proposed a fuzzy extractor twice and built
  neither; this is the smallest one that can be read in an afternoon.
- **Not a key anybody should trust.** Every key this repository produces is a
  test key.

## Running it

```console
cargo build --release
elf2flash convert -b rp2350 target/thumbv8m.main-none-eabihf/release/exp181-a-key-that-is-written-nowhere target/exp181.uf2
yi26 flash target/exp181.uf2
```

Then **pull the cable and put it back, twice**, a few seconds each time. Not to
let it cool — what is needed is that the power actually went. The first pull
enrols, the second reconstructs, and the board reports either result for as long
as it is powered.

```console
yi26 log --seconds 20
./check.sh
python3 verify.py capture-reconstructed.txt
```

Flashing it again erases nothing: the record survives at 3 MiB into flash, and
the board will reconstruct against the enrolment it already has. To start over,
erase that sector.

## Expected output

```text
PASS  python3 present
PASS  firmware compiles (213800 byte ELF)
PASS  the firmware says the key is not printed, in the log itself
PASS  exactly one thing is written to flash, and it is the record
PASS  and there is only one such write in the whole firmware
PASS  the SRAM window is never written to flash — storing it would be storing the key
PASS  enrolment refuses a window outside the power-on band (exp179's 0.00% trap)
PASS  a reconstruction after a warm reset is labelled as not evidence (exp179 again)
PASS  the TRNG uses exp109's sample count, not the driver's default
      ruling on capture-refused.txt
PASS  the transcript reports what bank 8 held
PASS  it refused on a window reading 0.0% — which is a cleared one, not a power-on one
PASS  and it names the experiment that measured why the window is cleared
PASS  even a refusal says the key is not printed and not stored
      This transcript is the guard firing. There is no key in it, which is the point.
      ruling on capture-reconstructed.txt
PASS  the transcript reports what bank 8 held
PASS  bank 8 came up at 50.7% one-bits — a power-on reading, not a cleared one
PASS  the record says what it was enrolled at
PASS  and that was 51.1%, within a few points of this boot — the same kind of reading, not a different kind
PASS  the boot began from no power — exp179 measured that a reset which keeps it leaves the window untouched, so anything else here would be circular
PASS  the key came back
PASS  every one of the 256 key bits reconstructed, which is what makes the error count below exact
PASS  the transcript reports how many cells changed
      494 of 7936 cells changed: a 6.22% error rate, 1.93 flips per key bit of 31, and 16 needed to break one
      so P(a key bit fails) = 6.18e-12, P(the key fails) = 1.58e-09
PASS  the code had margin: about one reconstruction in 632 million would fail **at this error rate**, which is one measurement of it
PASS  and the error rate is 6.22%, well inside what a 31-fold repetition can carry
PASS  the key is not in the transcript, and the firmware says so
PASS  a board is running exp181 — pull the cable and it does the whole thing again
PASS  the README names exp179, which is what unlocked this
PASS  the README names exp175, whose gap this closes
PASS  and exp163, which says what this does not fix
```

The two transcripts it rules on are checked in beside it:
[`capture-refused.txt`](./capture-refused.txt), where nothing happened and that
was correct, and [`capture-reconstructed.txt`](./capture-reconstructed.txt),
where the key came back.
