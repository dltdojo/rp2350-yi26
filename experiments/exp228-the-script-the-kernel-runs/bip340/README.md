# bip340/

<!-- SPDX-License-Identifier: BSD-2-Clause -->

Two files from BIP340, unchanged, as published in
[bitcoin/bips](https://github.com/bitcoin/bips/tree/927b6de9915c9262615a6399de51b200f81e5aa4/bip-0340)
at commit `927b6de9915c9262615a6399de51b200f81e5aa4`. BIP340 is licensed
BSD-2-Clause.

| File | sha256 |
| --- | --- |
| `reference.py` | `4b1d4ad9e60820df4a6d239733d52b014bc03e4c47afd757a2fe4d3b586d892c` |
| `test-vectors.csv` | `34c9d1d9c3a88d524bc80778540dc43f8306ec249a7485293063c376db851c2d` |

`reference.py` signs the cases' signatures and is the oracle `script.py` is
told; `test-vectors.csv` is what the shell's C signature check is held to.
Neither is part of what the kernel's proof is about: `OP_CHECKSIG`'s answer is
a parameter of the theorem.
