#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp204 — the proved kernel, on the model and on the RTL, against Python.
#
#   ./compare.sh       one line per case, then PASS/FAIL lines
#
# For each image images.py builds — kernel.bin, a message, a signature, a
# public key, and scratch that starts as 0xee:
#   - the model halts with the verdict Python expects (0 accept, 1 reject)
#     after exactly the number the proof states, valid signature or not;
#   - the RTL halts with the same verdict, and its minstret is that number plus
#     the harness's constant plus 256 HASH calls at the per-call cost, both
#     measured by tools/hazard3/hash-cost.sh;
#   - the whole region is byte for byte the same on both, and Python — not the
#     model — agrees that only the 96 bytes of scratch changed.
# And once more on the model alone, at 0x20070000, where the chip's shell is
# planned to put it.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
SIM=../../tools/hazard3/sim.sh
RUN="$(../../tools/lean/lean.sh exe rv32run)" || exit 2
read -r BASE SIZE < <($SIM region)
# The number the theorems state, read from the proof rather than repeated here.
PROVED="$(sed -n 's/.*run env \([0-9]*\) s = \.halted (if Verifies.*/\1/p' proof/Lamport.lean | head -1)"
read -r C P < <(../../tools/hazard3/hash-cost.sh --quiet | sed -n 's/.*RTL − model = \([0-9]*\) + \([0-9]*\) × .*/\1 \2/p')
EXPECT_RTL=$((PROVED + C + 256 * P))
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

status=0; n=0; ok_l=0; ok_r=0; same=0; kept=0; far=0
printf '%-24s %-6s %-26s %-34s %s\n' case python "model at $BASE" "RTL" "model at 0x20070000"
while read -r name want; do
    img="build/$name.bin"; n=$((n + 1))
    l="$($RUN "$img" "$BASE" "$SIZE" 20000 $((SIZE)) "$work/l.sig")"
    r="$($SIM run "$img" --dump $((SIZE)) "$work/r.sig" --cycles 50000000)"
    f="$($RUN "$img" 0x20070000 "$SIZE" 20000)"
    printf '%-24s %-6s %-26s %-34s %s\n' "$name" "$want" "$l" "$r" "$f"
    code="$(printf '%08x' "$want")"
    [[ "$l" == "halt code=$code count=$PROVED" ]] && ok_l=$((ok_l + 1))
    [[ "$r" == "halt code=$code instret=$EXPECT_RTL "* ]] && ok_r=$((ok_r + 1))
    [[ "$f" == "halt code=$code count=$PROVED" ]] && far=$((far + 1))
    cmp -s "$work/l.sig" "$work/r.sig" && same=$((same + 1))
    python3 images.py verify "$name" "$work/r.sig" > /dev/null && kept=$((kept + 1))
done < <(python3 images.py build build)
echo
check() { if [[ $1 -eq $2 ]]; then echo "PASS  $3"; else echo "FAIL  $3 — $1 of $2"; status=1; fi; }
check "$ok_l" "$n" "the model gives Python's verdict after exactly $PROVED instructions, the number proved, on all $n cases"
check "$ok_r" "$n" "the RTL gives the same verdict and counts $EXPECT_RTL = $PROVED proved + $C for the harness + 256 HASH × $P, on all $n"
check "$same" "$n" "the whole region is byte for byte the same on both, on all $n"
check "$kept" "$n" "Python agrees: only the 96 bytes of scratch changed, on all $n"
check "$far" "$n" "at 0x20070000 the same bytes give the same verdict after $PROVED, on all $n"
exit "$status"
