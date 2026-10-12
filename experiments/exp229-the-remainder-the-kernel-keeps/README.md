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

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp229 — the remainder the kernel keeps ===
recorded at 2026-10-12T00:55:54Z from commit b71d11e

>>> the theorems, and what they rest on
'Exp229.addm_loop' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp229.word_body' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp229.subn_loop' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp229.sel_loop' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp229.zero_loop' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp229.row_loop' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp229.fold_loop' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp229.field' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp229.accepted' depends on axioms: [propext, Quot.sound]
'Exp229.field_constant_time' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
fold976        each fold multiplies the high words by 976: 2^256 is taken to be 2^32 + 976 modulo p                      refused in m_fold1
keep_turned    CSUB's mask is turned around: it keeps the sum when the sum is p or more, and subtracts when it is less   refused in m_csub
sub_no_p       subtraction never adds p back: a borrow is left as 2^256 - (b - a)                                        refused in sub_run
secret_branch  the select loop branches on the word it chose, a word of the secret, instead of on its counter            refused in m_csub
op_secret      the operation word is called secret: the dispatch then branches on a secret, and the checker refuses it   refused in accepted
spec_off       the specification asks for a·b + 1 modulo p                                                              refused in field
count_short    the multiplication is claimed to halt one instruction sooner than it does                                 refused in field
prime_off      the prime is taken to be 2^256 - 2^32 - 978                                                               refused in sub_run

>>> the model and the RTL against Python's integers: every edge pair, then 1000 drawn
PASS  2083 cases on the model, the first 1143 on the RTL too: each halts with 0 and leaves (a op b) mod p — 0 wrong
PASS  one count per operation, whatever the numbers: model add ['331'], sub ['238'], mul ['1903']; RTL add ['instret=335 cycles=370'], sub ['instret=241 cycles=266'], mul ['instret=1907 cycles=1979']

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  Field.lean checks, with no errors and no warnings
PASS  all 10 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  fold976: the proof refuses a version where each fold multiplies the high words by 976: 2^256 is taken to be 2^32 + 976 modulo p
PASS  keep_turned: the proof refuses a version where CSUB's mask is turned around: it keeps the sum when the sum is p or more, and subtracts when it is less
PASS  sub_no_p: the proof refuses a version where subtraction never adds p back: a borrow is left as 2^256 - (b - a)
PASS  secret_branch: the proof refuses a version where the select loop branches on the word it chose, a word of the secret, instead of on its counter
PASS  op_secret: the proof refuses a version where the operation word is called secret: the dispatch then branches on a secret, and the checker refuses it
PASS  spec_off: the proof refuses a version where the specification asks for a·b + 1 modulo p
PASS  count_short: the proof refuses a version where the multiplication is claimed to halt one instruction sooner than it does
PASS  prime_off: the proof refuses a version where the prime is taken to be 2^256 - 2^32 - 978
PASS  proof/Field.lean's kernel is what kernel.py writes from its labels
PASS  kernel.bin is what proof/Field.lean writes, 2080 bytes, and kernel.sha256 is its hash
PASS  1283 cases on the model, the first 1143 on the RTL too: each halts with 0 and leaves (a op b) mod p — 0 wrong
PASS  one count per operation, whatever the numbers: model add ['331'], sub ['238'], mul ['1903']; RTL add ['instret=335 cycles=370'], sub ['instret=241 cycles=266'], mul ['instret=1907 cycles=1979']
```
