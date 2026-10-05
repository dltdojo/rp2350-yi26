#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tools/hazard3 — a proved kernel on the model and on the RTL, against Python:
# the loop exp205 wrote and exp206 needed second.
#
#   kernelcompare.sh A B EXTRA KEPT     run from the experiment's directory
#
# For each image the experiment's images.py builds — it prints each case's
# name, Python's verdict (0 accept, 1 reject) and S, the HASH calls the
# message's chains make:
#   - the model halts with Python's verdict after exactly A + B S
#     instructions, the count the experiment's proof states;
#   - the RTL halts with the same verdict, and its minstret is that count plus
#     the harness's constant plus S + EXTRA HASH calls at the per-call cost,
#     both measured by tools/hazard3/hash-cost.sh — EXTRA is the calls the
#     kernel makes beyond its chains;
#   - the whole region is byte for byte the same on both, and Python — not
#     the model — accepts what is left (`images.py verify`), which KEPT says
#     in words;
# and once more on the model alone, at 0x20070000. One line per case, then
# PASS/FAIL lines; exit 0 when every one passes.
#
# STEPS and CYCLES in the environment raise the model's step limit (20000)
# and the testbench's cycle limit (100000000), for a kernel that runs longer:
# exp213's key generator takes 76456 instructions and 17183 HASH calls.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM="$HERE/sim.sh"
A="$1" B="$2" EXTRA="$3" KEPT="$4"
STEPS="${STEPS:-20000}" CYCLES="${CYCLES:-100000000}"
RUN="$("$HERE/../lean/lean.sh" exe rv32run)" || exit 2
read -r BASE SIZE < <("$SIM" region)
read -r C P < <("$HERE/hash-cost.sh" --quiet | sed -n 's/.*RTL − model = \([0-9]*\) + \([0-9]*\) × .*/\1 \2/p')
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

status=0; n=0; ok_l=0; ok_r=0; same=0; kept=0; far=0
printf '%-24s %-9s %-26s %-34s %s\n' case "python S" "model at $BASE" "RTL" "model at 0x20070000"
while read -r name want steps; do
    img="build/$name.bin"; n=$((n + 1))
    l="$($RUN "$img" "$BASE" "$SIZE" "$STEPS" $((SIZE)) "$work/l.sig")"
    r="$("$SIM" run "$img" --dump $((SIZE)) "$work/r.sig" --cycles "$CYCLES")"
    f="$($RUN "$img" 0x20070000 "$SIZE" "$STEPS")"
    printf '%-24s %-9s %-26s %-34s %s\n' "$name" "$want $steps" "$l" "$r" "$f"
    code="$(printf '%08x' "$want")"
    count=$((A + B * steps))
    [[ "$l" == "halt code=$code count=$count" ]] && ok_l=$((ok_l + 1))
    [[ "$r" == "halt code=$code instret=$((count + C + P * (steps + EXTRA))) "* ]] && ok_r=$((ok_r + 1))
    [[ "$f" == "halt code=$code count=$count" ]] && far=$((far + 1))
    cmp -s "$work/l.sig" "$work/r.sig" && same=$((same + 1))
    python3 images.py verify "$name" "$work/r.sig" > /dev/null && kept=$((kept + 1))
done < <(python3 images.py build build)
echo
hashes="S"; [[ "$EXTRA" == 0 ]] || hashes="(S + $EXTRA)"
check() { if [[ $1 -eq $2 ]]; then echo "PASS  $3"; else echo "FAIL  $3 — $1 of $2"; status=1; fi; }
check "$ok_l" "$n" "the model gives Python's verdict after exactly $A + $B S instructions, the count proved, on all $n cases"
check "$ok_r" "$n" "the RTL gives the same verdict and counts $A + $B S proved + $C for the harness + $P $hashes for HASH, on all $n"
check "$same" "$n" "the whole region is byte for byte the same on both, on all $n"
check "$kept" "$n" "Python agrees: $KEPT, on all $n"
check "$far" "$n" "at 0x20070000 the same bytes give the same verdict after the same count, on all $n"
exit "$status"
