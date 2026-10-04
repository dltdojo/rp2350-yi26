#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp202 — every built binary, on the Lean model and on the Hazard3 RTL.
#
#   ./compare.sh [RV32RUN]   one line per binary, then PASS/FAIL lines;
#                            exit 0 = all agree
#
# RV32RUN is the model to run, built from lean/ when not given; the mutants
# in semantics/ pass a model built from a wrong copy.
#
# For each binary it asks, of the same bytes:
#   1. how does it end, on each?  halt and its code, or a fault, its kind and
#      the address it stopped at — the model's pc, the RTL's mepc. The two
#      must end the same way. For riscv-tests that means both pass; for the
#      probes it is often the same fault.
#   2. is the whole 64 KiB region byte for byte the same afterwards?
#
# (2) is the strong one. A test that passes checks the values it chose to
# check; the region is everything either executor wrote, checked or not.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
RUN="${1:-$(../../tools/lean/lean.sh exe rv32run)}" || exit 2
SIM=../../tools/hazard3/sim.sh
read -r BASE SIZE < <($SIM region)
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# One spelling for both: `halt 00000000`, or `fault <mcause> at <address>`.
# The model's fault kinds are named; each is the mcause the privileged
# specification gives the same event.
ending_lean() {
    local kind
    case "$1" in
        "halt code="*) echo "halt $(sed 's/halt code=\([0-9a-f]*\).*/\1/' <<< "$1")"; return;;
        "timeout"*) echo timeout; return;;
    esac
    kind="$(awk '{print $2}' <<< "$1")"
    case "$kind" in
        fetch-misaligned) kind=0;; fetch-access) kind=1;; illegal*) kind=2;;
        load-misaligned) kind=4;; load-access) kind=5;;
        store-misaligned) kind=6;; store-access) kind=7;; *) kind="$kind";;
    esac
    echo "fault $kind at $(sed 's/.*pc=\([0-9a-f]*\).*/\1/' <<< "$1")"
}
ending_rtl() {
    case "$1" in
        "halt code="*) echo "halt $(sed 's/halt code=\([0-9a-f]*\).*/\1/' <<< "$1")";;
        "fault "*) echo "fault $((16#$(sed 's/.*mcause=\([0-9a-f]*\).*/\1/' <<< "$1"))) at $(sed 's/.*mepc=\([0-9a-f]*\).*/\1/' <<< "$1")";;
        *) echo timeout;;
    esac
}

suite=0; lean_pass=0; rtl_pass=0; probes=0; ends=0; same=0; n=0; status=0
printf '%-24s %-26s %s\n' binary "Lean model" "Hazard3 RTL"
for bin in build/*.bin; do
    name="$(basename "$bin" .bin)"
    n=$((n + 1))
    l="$(ending_lean "$($RUN "$bin" "$BASE" "$SIZE" 1000000 $((SIZE)) "$work/l.sig")")"
    r="$(ending_rtl "$($SIM run "$bin" --dump $((SIZE)) "$work/r.sig")")"
    mark=""
    [[ "$l" == "$r" ]] && ends=$((ends + 1)) || mark="  <- differs"
    if cmp -s "$work/l.sig" "$work/r.sig"; then same=$((same + 1)); else mark+="  <- region differs"; fi
    printf '%-24s %-26s %s%s\n' "$name" "$l" "$r" "$mark"
    if [[ "$name" == probe-* ]]; then
        probes=$((probes + 1))
    else
        suite=$((suite + 1))
        [[ "$l" == "halt 00000000" ]] && lean_pass=$((lean_pass + 1))
        [[ "$r" == "halt 00000000" ]] && rtl_pass=$((rtl_pass + 1))
    fi
done

echo
check() { if [[ $1 -eq $2 ]]; then echo "PASS  $3"; else echo "FAIL  $3 — $1 of $2"; status=1; fi; }
check "$lean_pass" "$suite" "the Lean model passes all $suite riscv-tests"
check "$rtl_pass" "$suite" "the Hazard3 RTL passes all $suite riscv-tests"
check "$ends" "$n" "every binary ends the same way on both — $suite tests and $probes probes"
check "$same" "$n" "after every one, the whole region is byte for byte the same on both ($n × $((SIZE)) bytes)"
exit "$status"
