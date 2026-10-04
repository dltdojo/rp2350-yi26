#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp205 — the proved kernel, on the model and on the RTL, against Python.
#
#   ./compare.sh       one line per case, then PASS/FAIL lines
#
# For each image images.py builds — kernel.bin, a message, a signature and a
# public key of 67 chains, and scratch that starts as 0xee — Python says the
# verdict and how many HASH calls a verifier makes for that message, S:
#   - the model halts with Python's verdict after exactly 4142 + 3 S
#     instructions, the count the proof states — read from the proof;
#   - the RTL halts with the same verdict, and its minstret is that count plus
#     the harness's constant plus S HASH calls at the per-call cost, both
#     measured by tools/hazard3/hash-cost.sh;
#   - the whole region is byte for byte the same on both, and Python — not
#     the model — agrees that only the 131 bytes of scratch changed and that
#     the 67 digits there are the message's and the checksum's.
# And once more on the model alone, at 0x20070000.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
SIM=../../tools/hazard3/sim.sh
RUN="$(../../tools/lean/lean.sh exe rv32run)" || exit 2
read -r BASE SIZE < <($SIM region)
# The count the theorem states, A + B · steps, read from the proof.
read -r A B < <(sed -n "s/.*∃ s', run env (\([0-9]*\) + \([0-9]*\) \* steps s.mem base) s\$/\1 \2/p" proof/Wots.lean | head -1)
read -r C P < <(../../tools/hazard3/hash-cost.sh --quiet | sed -n 's/.*RTL − model = \([0-9]*\) + \([0-9]*\) × .*/\1 \2/p')
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

status=0; n=0; ok_l=0; ok_r=0; same=0; kept=0; far=0
printf '%-24s %-9s %-26s %-34s %s\n' case "python S" "model at $BASE" "RTL" "model at 0x20070000"
while read -r name want steps; do
    img="build/$name.bin"; n=$((n + 1))
    l="$($RUN "$img" "$BASE" "$SIZE" 20000 $((SIZE)) "$work/l.sig")"
    r="$($SIM run "$img" --dump $((SIZE)) "$work/r.sig" --cycles 100000000)"
    f="$($RUN "$img" 0x20070000 "$SIZE" 20000)"
    printf '%-24s %-9s %-26s %-34s %s\n' "$name" "$want $steps" "$l" "$r" "$f"
    code="$(printf '%08x' "$want")"
    count=$((A + B * steps))
    [[ "$l" == "halt code=$code count=$count" ]] && ok_l=$((ok_l + 1))
    [[ "$r" == "halt code=$code instret=$((count + C + P * steps)) "* ]] && ok_r=$((ok_r + 1))
    [[ "$f" == "halt code=$code count=$count" ]] && far=$((far + 1))
    cmp -s "$work/l.sig" "$work/r.sig" && same=$((same + 1))
    python3 images.py verify "$name" "$work/r.sig" > /dev/null && kept=$((kept + 1))
done < <(python3 images.py build build)
echo
check() { if [[ $1 -eq $2 ]]; then echo "PASS  $3"; else echo "FAIL  $3 — $1 of $2"; status=1; fi; }
check "$ok_l" "$n" "the model gives Python's verdict after exactly $A + $B S instructions, the count proved, on all $n cases"
check "$ok_r" "$n" "the RTL gives the same verdict and counts $A + $B S proved + $C for the harness + $P S for HASH, on all $n"
check "$same" "$n" "the whole region is byte for byte the same on both, on all $n"
check "$kept" "$n" "Python agrees: only the 131 bytes of scratch changed, and the digits there are right, on all $n"
check "$far" "$n" "at 0x20070000 the same bytes give the same verdict after the same count, on all $n"
exit "$status"
