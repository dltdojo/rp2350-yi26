# exp229 — the remainder the kernel keeps

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Addition, subtraction and multiplication modulo secp256k1's
p = 2^256 − 2^32 − 977, on numbers of eight 32-bit words, in 458 RV32IM
instructions with no branch on a number. Lean proves, for every a and b below
p, that the kernel halts with 0 having left (a + b), (a − b) or (a · b) mod p
in R, after exactly 331, 238 or 1903 instructions; and, through exp207's
checker, that two runs on different a and b are observed the same at every
step. On the model and the Hazard3 RTL, every edge pair and hundreds of drawn
ones agree with Python's integers, in one count per operation.**

Needs: **no board**. The first step on the
[hardware-wallet road](../../docs/2026-10-11-0610-verified-bytes-for-a-hardware-wallet-zh-tw.md):
the field every BIP340 operation stands on. A plain-language account, and how
this compares with writing the same thing in Rust or C, is in
[WHY.zh-TW.md](./WHY.zh-TW.md).

## The kernel

`kernel.py` writes it from labels into `proof/Field.lean` (through
`tools/lean/kasm.py`), with a list of every loop and where its pointers start.
The layout of the region, from base:

```
0x0000  the kernel             0x0a00  T  a · b, sixteen words
0x0800  PRIME  p               0x0a40  U  the first fold, ten words
0x0900  OPW    0 add, 1 sub,   0x0a80  V  the next fold's high words
               2 mul           0x0ac0  W  the second fold
0x0904  A      a < p           0x0b00  X  the third fold
0x0924  B      b < p           0x0b40  D  x - p
0x0944  R      the result      0x0b80  S  a + b, nine words
```

| Operation | How | Instructions, proved | RTL instret, cycles |
| --- | --- | --- | --- |
| add | `S = A + B`, nine words; then `R = S` or `S - p`, by mask | 331 | 335, 370 |
| sub | `D = A - B`; then `R = D + (p & mask)`, the mask all ones if it borrowed | 238 | 241, 266 |
| mul | `T = A · B`, eight rows; three folds by `2^256 ≡ 2^32 + 977`; then `R = X` or `X - p` | 1903 | 1907, 1979 |

Every piece is a loop of eight over the words, least significant first, and
every loop has one shape: two loads, a straight line of register instructions,
a store, the three pointers on a word and the counter down one, the branch
back. `ADDM` adds under a mask, `SUBN` subtracts and leaves the borrow, `SEL`
is `y ^ ((x ^ y) & mask)`, `ZERO` stores each word less itself, a row adds
`a[i] · B` into `T[i ..]` in place, `FOLD` is `L + H·977 + H·2^32`, `HSET`
carries a fold's two top words into the next, and `CSUB` is SUBN, the mask,
SEL.

## The proof

`proof/Field.lean`, on Lean's own axioms only (`./check.sh` says so):

- **`field`**: from base, with the kernel in memory, p at PRIME, the operation
  at OPW and a, b < p at A and B, the kernel runs `count op − 1` instructions,
  the next one halts with 0, and R holds `spec op a b` — `(a + b) % p`,
  `(a + p − b) % p` or `(a · b) % p`. The count is a function of the operation
  alone.
- **`accepted`** and **`field_constant_time`**: exp207's checker, decided over
  all 458 instructions with p and the operation the only public bytes; so two
  images that begin with the kernel and agree on p and the operation run in
  lock step — the same `pc`, the same address loaded or stored, the same end —
  whatever a and b they hold.

Underneath: one lemma, `word_body`, runs one round of any loop of the shape
above; each loop's invariant is proved once on it (`addm_loop` … `fold_loop`);
each piece from its first instruction (`addm_run` … `csub_run`); where each
piece sits in the kernel is decided against the kernel (`m_row0`, `a_csub`, …);
and the three operations compose them (`add_run`, `sub_run`, `mul_run`). The
multiplication's arithmetic is the fold's: `T = L + 2^256·H = L + (2^32 +
977)·H + p·H`, three times, and the third leaves X below 2^256, so one
conditional subtraction finishes it.

What `field` takes as given: p at PRIME. The image carries it (`field.py`
writes it there and the differential reads the result back), but no theorem
reads it out of the bytes.

`proof/mutants.txt` holds eight wrong versions, each refused: 976 for 977 in
every fold, CSUB's mask turned around, subtraction that never adds p back, a
SEL loop that branches on the word it chose, the operation word called secret
(the dispatch then branches on a secret), and three wrong claims — a·b + 1, a
count one short, a wrong p.

## What the proof changed

**The kernel had subroutines; the checker takes none.** The first kernel was
190 instructions, its pieces called with `jal ra` and left with `jalr`. exp207's
checker refuses both: it follows registers through straight lines and loops,
not through a return address. So each piece is now written where it is used,
458 instructions, and the counts went from 338, 242 and 1876 to 331, 238 and
1903.

**The product's outer loop is written out eight times.** The checker knows a
pointer as a fixed offset plus a multiple of one counter. A row's store
pointer is `T + 4(i + j)` — two counters. Written out, each row's pointers
are `T + 4i` plus a multiple of its own counter.

**Three folds where two usually suffice.** The third does something only when
the second carried, which [exp228's](../exp228-the-script-the-kernel-runs/) C
`fe_mul` reaches with a branch that 200,000 drawn products never took. Here
the third always runs, and `mul_run` proves that what it leaves is below 2^256.

**A match on numbers ran Lean out of memory.** `spec` and `count` were first
written by `match` on 0, 1 and the rest; unfolding `spec 1` sent Lean's
definitional check into the run itself until the process was killed. Written
with `if`, `simp` unfolds them in a moment.

**`toBytes_words` is now proved once.** exp223, exp224 and exp225 each
compute, by `decide`, that a kernel's bytes are its instructions; on 458
instructions the computation ran out of memory. `lean/Rv32/Place.lean` now
proves it for any program.

## Running it

```sh
./check.sh        # the proof, the mutants, kernel.bin, the differential
./run.sh          # the same, and more drawn cases, into capture.txt
```

## Expected output

Not yet captured.
