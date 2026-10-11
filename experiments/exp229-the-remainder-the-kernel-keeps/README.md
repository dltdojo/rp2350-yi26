# exp229 — the remainder the kernel keeps

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Addition, subtraction and multiplication modulo secp256k1's
p = 2^256 − 2^32 − 977, on numbers of eight 32-bit words, in 190 RV32IM
instructions with no branch on a number. Every loop runs a fixed count, and
the one choice the arithmetic needs, whether to subtract p, is made with a
mask. On the Lean model and on the Hazard3 RTL, every edge pair and hundreds
of drawn ones leave Python's remainder, and each operation takes the same
number of instructions, and on the RTL the same number of cycles, whatever
the numbers are. The proof is in progress.**

Needs: **no board**. The first step on the
[hardware-wallet road](../../docs/2026-10-11-0610-verified-bytes-for-a-hardware-wallet-zh-tw.md):
the field every BIP340 operation stands on.

## The kernel

`kernel.py` writes it from labels into `proof/Field.lean` (through
`tools/lean/kasm.py`). The layout of the region, from base:

```
0x0000  the kernel             0x0a00  T  a · b, sixteen words
0x0800  PRIME  p               0x0a40  U  the first fold, ten words
0x0900  OPW    0 add, 1 sub,   0x0a80  V  the next fold's high words
               2 mul           0x0ac0  W  the second fold
0x0904  A      a < p           0x0b00  X  the third fold
0x0924  B      b < p           0x0b40  D  x - p
0x0944  R      the result      0x0b80  S  a + b, nine words
```

| Operation | How | Model instructions | RTL instret, cycles |
| --- | --- | --- | --- |
| add | `S = A + B`, nine words; then `R = S` or `S - p`, by mask | 338 | 342, 384 |
| sub | `D = A - B`; then `R = D + (p & mask)`, the mask all ones if it borrowed | 242 | 246, 274 |
| mul | `T = A · B`; three folds by `2^256 ≡ 2^32 + 977`; then `R = X` or `X - p` | 1876 | 1880, 2104 |

The subroutines are loops of eight over the words, least significant first:
`ADDM` (add, the second operand under a mask), `SUBN` (subtract, the borrow
returned), `SEL` (`d ^ ((d ^ x) & mask)`), `MUL` (schoolbook, 64 products by
`mul` and `mulhu`), `FOLD` (`L + H·977 + H·2^32`) and `HSET`.

Three folds where two usually suffice: the third does something only when the
second carried, which [exp228's](../exp228-the-script-the-kernel-runs/) C
`fe_mul` reaches with a branch that 200,000 drawn products never took. Here
there is no branch: the third fold always runs, and the proof covers what it
does.

## Running it

```sh
./check.sh
```

## Expected output

Not yet captured.
