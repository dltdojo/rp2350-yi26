# exp140-a-checksum-that-passes — a CRC is not a signature, shown not said

The design note this arc came from says an over-the-air update should "write to
Slot B, then verify the CRC". Every guide says something like it, and it is
half right in a way that is worth taking apart on real firmware rather than
nodding at.

Needs: **no board at all.** This is the first experiment since exp102 that runs
entirely on a machine. The whole thing is `cargo test` in
[`crates/image-integrity`](../../crates/image-integrity/), plus a demonstration
against any `.uf2` this repository has built.

## Two words that get used as one

- **Reliability** — did the bytes arrive intact? A cable drops a bit, a flash
  write flips one, a packet is truncated. A CRC catches all of that, and it is
  genuinely good at it. This is not a reason to remove CRCs.
- **Authenticity** — are these bytes *from who I think*? A CRC answers this not
  at all, and the gap is not small. It is the difference between "the file is
  undamaged" and "the file is yours".

A CRC check on an update conflates them, and the conflation is invisible until
somebody hands you a file built to pass it.

## The forgery, on this repository's own output

`crates/image-integrity` forges a CRC. Not "detects a weakness" — produces a
different image whose CRC32 is exactly the one you were checking against, by
changing **four bytes**, at the same size, in a way a loader would accept.
Against a real `exp138.uf2`:

```text
good CRC32:   0xfb397940
evil CRC32:   0xd960d650   (a different image, before forging)
evil CRC32:   0xfb397940   (after forging four bytes at offset 46076)
  -> the CRC check PASSES on an image that is not the one it checked against
```

The four bytes are in the tail — padding, spare room every image has. The
result is the same length, parses the same, and carries the CRC of a file it is
not. A bootloader that "verified the CRC" would write it and boot it.

## Why four bytes is enough, and always will be

CRC32 is **linear over GF(2)**. Flipping an input bit flips a fixed set of
output bits — every time, no matter what the other input bits are. So the
question *"which four bytes make the CRC come out to X"* is 32 linear equations
in 32 unknowns, and a linear system is **solved**, not searched. Four bytes is
32 bits, which is exactly the width of the CRC, so there is always a solution
and it is found instantly.

The forge in [`crates/image-integrity`](../../crates/image-integrity/) does
this in plain arithmetic you can read: zero the four bytes, measure the CRC's
response to each of the 32 window bits one at a time, and solve the resulting
matrix. No search, no luck.

## The same attack, against a hash

The experiment's real point is the contrast, and it is asserted rather than
described. `forge_hash_the_same_way` runs the **identical** method against
SHA-256 — same 32 measurements, same matrix, same solve — and the four bytes it
produces do not work:

```text
good SHA-256:  0ee3f9eb7cc5720e…
evil SHA-256:  7718fb3341799c9c…
  -> the hashes differ, and no four bytes make them agree
```

Not "harder". **The method does not apply.** A cryptographic hash is built so
that the output bits a flipped input bit changes depend on all the other input
bits, so there is no fixed matrix to build and nothing to solve. The test
`the_same_attack_does_not_forge_a_hash` is that failure, pinned.

And a hash *can* be matched — by the only route left once solving is gone:
trying inputs until one hashes right. `forging_a_hash_means_searching_and_that_
is_the_cost` does it for a **four-bit** target, finishes instantly, and says
what it means: scale four bits to 256 and the search stops finishing. That is
the whole security argument, made by watching where the shortcut disappears.

## So what should an update check?

This experiment does not build the answer — it makes the question unavoidable.
A CRC belongs on the wire, catching the damaged transfer. What decides whether
to *run* an image is a different question with a different tool: a hash you
compare against one you trust, or a signature you verify against a key. The
RP2350's ROM has the second built in (exp138 listed `explicit_buy`, the hash
items, the signature item), and turning it on is a decision with its own cost —
which is why signing is named as its own road and not folded in here.

The one thing this experiment settles: **"verify the CRC" is a reliability
check wearing an authenticity check's clothes,** and now you have seen the
forgery it does not catch.

## The code IS the walkthrough

- [`../../crates/image-integrity/src/lib.rs`](../../crates/image-integrity/src/lib.rs)
  — `crc32` by hand (the linearity is the lesson), `forge_crc32`, and
  `forge_hash_the_same_way` which is the same code aimed at a target it cannot
  hit.
- [`../../crates/image-integrity/examples/forge.rs`](../../crates/image-integrity/examples/forge.rs)
  — the demo `run.sh` and `check.sh` run against a real `.uf2`.

## Do this, in order

Like [exp102](../exp102-rust-toolchain/), this experiment never touches a
board. Unlike every other one, **its substance is a test suite rather than a
firmware**, so its zip carries the account and the verdict but the doing of it
needs the repository — a zip carries no buildable source, and a demonstration
rewritten in some other language to fit in one would be a second, unchecked
statement of the same claim.

So this walkthrough is short, and step 1 is the honest part.

WHAT YOU NEED
  * A machine with `cargo` — [exp102](../exp102-rust-toolchain/) puts it there.
  * `git`. No board. Do not plug anything in.

1. GET THE REPOSITORY. There is nothing to flash, so this is not a detour
   around the zip: it is where this particular experiment lives.

       git clone https://github.com/dltdojo/rp2350-yi26.git
       cd rp2350-yi26/experiments/exp140-a-checksum-that-passes

2. RUN THE ARITHMETIC. No board, no firmware, no network.

       ./check.sh

   Expect seven `PASS` lines and exit 0. The two that are the experiment:

       PASS  a real .uf2 was forged to carry another image's CRC (exp152.uf2)
       PASS  and the SHA-256 of the forgery does not match

   **Both of those parentheses vary.** The script forges whichever `.uf2` it
   finds first in your checkout, so the filename depends on what you have
   built, and the CRC value depends on the file. A fresh clone that has built
   nothing gets `exp138.uf2`, because the script builds that one rather than
   have nothing to demonstrate on. The words are fixed; the numbers are not.

3. READ WHAT IT JUST PROVED. Four bytes of a real firmware image were changed
   so that its CRC32 came out equal to a *different* image's CRC32 — exactly,
   not approximately. The same code, aimed at SHA-256, cannot do it and says
   so. A CRC answers "did this arrive intact"; it does not answer "is this the
   image I meant", and no amount of CRC checking turns one question into the
   other.

4. OPTIONAL — MAKE IT LIE ABOUT SOMETHING ELSE.

       cd ../../crates/image-integrity && cargo test

   Expect the crate's own tests, including `only_the_four_bytes_moved` (the
   forgery is bounded, so a check that compared lengths or hashed the file
   would notice) and `the_same_attack_does_not_forge_a_hash`.

IF IT DOES NOT WORK
  * `toolchain present — run exp102 first` — there is no `cargo` on this
    machine. That experiment is the one that installs it.
  * The `.uf2` PASS lines are missing — the script looks for a built firmware
    anywhere in the checkout and builds exp138 if it finds none. If that build
    failed, the arithmetic still ran; the demo against a real artifact did not.

## Two ways to do it

```sh
./run.sh      # guided: forge a real artifact's CRC, then watch the hash refuse
./check.sh    # verdict: the crate's tests, plus the demo on a real .uf2
```

## Expected output

`./check.sh`:

```text
PASS  toolchain present (cargo)
PASS  the image-integrity crate's tests pass (forge a CRC, fail to forge a hash)
PASS  the forgery is bounded to four bytes (a check would notice more)
PASS  the same attack is asserted to FAIL against SHA-256
PASS  a real .uf2 was forged to carry another image's CRC (exp138.uf2)
PASS  the forged CRC equals the target exactly (0xfb397940)
PASS  and the SHA-256 of the forgery does not match — the check that would have caught it
```

The forged CRC value depends on which `.uf2` the check found first, so that one
number varies between machines. Everything else is fixed.

## Make it yours

1. Forge four bytes at a *different* offset — the front of the image instead of
   the tail. It still works, and now the forgery is in code rather than
   padding, which is worse and just as undetectable to a CRC.
2. Change the CRC to CRC-16 or a one-byte checksum and re-run. Fewer bits to
   solve, so *fewer* bytes are needed to forge it. Weaker checksums are easier
   to forge, not harder — the opposite of the intuition.
3. Give `forge_hash_the_same_way` a target that is only 8 bits wide and let the
   search in the last test run to completion. Time it. Add bits until your
   patience runs out, and read the exponent off the wall.

## Next

The bridge out of the update road, and the reason it is the last step on it:
everything before this was about not bricking a board, and this is about not
trusting the wrong bytes. Signing — verifying against a key rather than
comparing against a hash — is its own road, named under
[Planned](../README.md#planned), because enabling it on this chip burns OTP and
cannot be undone.
