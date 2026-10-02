#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp203 — the proved kernel, on the model and on the RTL.
#
#   ./compare.sh       one line per data set, then PASS/FAIL lines
#
# For each image images.py builds — kernel.bin, then 64 source bytes and a
# destination with canaries either side:
#   - the model halts with 0 after exactly the number the proof states;
#   - the RTL halts with 0, and its minstret is that number plus the harness's
#     constant, measured by accounting/measure.sh;
#   - the whole region is byte for byte the same on both, and Python — not the
#     model — agrees it holds a copy and nothing else changed.
# And once more on the model alone, at 0x20070000, where the chip's shell is
# planned to put it: the same bytes, somewhere else, the same count.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
SIM=../../tools/hazard3/sim.sh
RUN="$(../../tools/lean/lean.sh exe rv32run)" || exit 2
read -r BASE SIZE < <($SIM region)
# The number the theorems state, read from the proof rather than repeated here.
PROVED="$(sed -n 's/.*run env \([0-9]*\) s = \.halted 0 s.*/\1/p' proof/Copy64.lean | head -1)"
OFFSET="$(accounting/measure.sh --quiet | sed -n 's/.*RTL − model = \([0-9]*\) .*/\1/p')"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
python3 images.py build build > /dev/null

status=0; n=0; ok_l=0; ok_r=0; same=0; copy=0; far=0
printf '%-12s %-26s %-32s %s\n' data "model at $BASE" "RTL" "model at 0x20070000"
for img in build/*.bin; do
    name="$(basename "$img" .bin)"; n=$((n + 1))
    l="$($RUN "$img" "$BASE" "$SIZE" 1000 $((SIZE)) "$work/l.sig")"
    r="$($SIM run "$img" --dump $((SIZE)) "$work/r.sig")"
    f="$($RUN "$img" 0x20070000 "$SIZE" 1000)"
    printf '%-12s %-26s %-32s %s\n' "$name" "$l" "$r" "$f"
    [[ "$l" == "halt code=00000000 count=$PROVED" ]] && ok_l=$((ok_l + 1))
    [[ "$r" == "halt code=00000000 instret=$((PROVED + OFFSET)) "* ]] && ok_r=$((ok_r + 1))
    [[ "$f" == "halt code=00000000 count=$PROVED" ]] && far=$((far + 1))
    cmp -s "$work/l.sig" "$work/r.sig" && same=$((same + 1))
    python3 images.py verify "$name" "$work/r.sig" > /dev/null && copy=$((copy + 1))
done
echo
check() { if [[ $1 -eq $2 ]]; then echo "PASS  $3"; else echo "FAIL  $3 — $1 of $2"; status=1; fi; }
check "$ok_l" "$n" "the model halts with 0 after exactly $PROVED instructions, the number proved, on all $n data sets"
check "$ok_r" "$n" "the RTL halts with 0 and counts $((PROVED + OFFSET)) = $PROVED proved + $OFFSET for the harness, on all $n"
check "$same" "$n" "the whole region is byte for byte the same on both, on all $n"
check "$copy" "$n" "Python agrees: the destination is the source and nothing else changed, on all $n"
check "$far" "$n" "at 0x20070000 the same bytes halt with 0 after $PROVED, on all $n"
exit "$status"
