#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp213 — the two proved kernels on the model and on the RTL, against Python,
# then the three binaries in a row.
#
#   ./compare.sh       one line per case, then PASS/FAIL lines
#
# Each kernel goes through tools/hazard3/kernelcompare.sh with its own cases
# (images.py, EXP213_KERNEL) and the count its own theorem states, read from
# the library: the key generator takes 76456 instructions whatever the seed,
# and makes 16 · 67 · 16 + 16 + 15 = 17183 HASH calls; the signer takes
# 2284 + 3 S, S = Σ dᵢ its walks' calls, and makes 67 more for the secrets.
# Then endtoend.py runs keygen, sign and exp206's verify one after another,
# on the model and on the RTL, copying between them what the shell copies —
# what proof/Complete.lean's `three_binaries` assumes and nothing more.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
LIB=../../lean/Rv32
read -r KA < <(sed -n "s/^    ∃ s', run env \([0-9]*\) s = .halted 0 s' ∧ Out base s.mem s'.mem\$/\1/p" $LIB/MssKeygen.lean)
read -r SA SB < <(sed -n "s/^    ∃ s', run env (\([0-9]*\) + \([0-9]*\) \* dsum s.mem base) s = .halted 0 s' ∧ Out base s.mem s'.mem\$/\1 \2/p" $LIB/MssSign.lean)
status=0
echo ">>> the key generator"
EXP213_KERNEL=keygen STEPS=100000 ../../tools/hazard3/kernelcompare.sh "$KA" 0 17183 \
    "the tree is the one Python builds from the seed" || status=1
echo
echo ">>> the signer"
EXP213_KERNEL=sign ../../tools/hazard3/kernelcompare.sh "$SA" "$SB" 67 \
    "the signature, the path and the root are the ones Python signs" || status=1
echo
echo ">>> the three in a row"
python3 endtoend.py model 0 5 10 15 || status=1
python3 endtoend.py rtl 0 15 || status=1
exit "$status"
