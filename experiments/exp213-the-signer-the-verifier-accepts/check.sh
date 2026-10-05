#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp213 quick check — non-interactive, and no board anywhere in it.
#
#   1. the proof checks, and rests on Lean's own axioms only: the key
#      generator halts with 0 after exactly 76456 instructions, the seed's
#      whole tree written; the signer halts with 0 after exactly 2284 + 3 S,
#      a signature, a path and a root written where exp206's verifier reads
#      them; and exp206's verifier, given what the signer left, halts with 0
#      — for every base, seed, message, index below 16 and HASH;
#   2. every wrong kernel and every wrong claim in proof/mutants.txt is refused;
#   3. keygen.bin and sign.bin are the bytes the proof is about — Lean writes
#      them again, byte for byte — and their SHA-256 are the committed ones;
#   4. the model, the RTL and Python agree on both kernels' cases, region and
#      count, and the three binaries run one after another are accepted on
#      the model and on the RTL.
#
# Needs Lean (tools/lean/setup.sh); (4) also the Hazard3 testbench
# (tools/hazard3/setup.sh) and clang, lld and llvm-objcopy. Without either it
# says SKIP for what it cannot run. About an hour: twenty minutes of (2), and
# six minutes for each key generation on the RTL in (4).
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# No board, no person, nothing to look at: a machine and nothing else.
PRESENCE=0
LIFELINE="no: no firmware of its own"
presence_check
lifeline_check

USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

LEAN=../../tools/lean/lean.sh
$LEAN check proof/Complete.lean || FAILED=1
$LEAN mutants proof/Complete.lean || FAILED=1

if [[ "$($LEAN version 2>&1)" != Lean* ]]; then
    echo "SKIP  keygen.bin and sign.bin against the proof: needs tools/lean/setup.sh"
else
    work="$(mktemp -d)"
    $LEAN exec proof/Complete.lean "$work/keygen.bin" "$work/sign.bin" > /dev/null
    for k in keygen sign; do
        if cmp -s "$work/$k.bin" $k.bin; then
            pass "$k.bin is the bytes the proof is about: Lean writes the same $(stat -c %s $k.bin)"
        else
            fail "$k.bin is the bytes the proof is about" "Lean wrote something else"
        fi
    done
    rm -rf -- "$work"
fi
for k in keygen sign; do
    if [[ "$(sha256sum $k.bin | cut -d' ' -f1)" == "$(cat $k.sha256)" ]]; then
        pass "$k.bin's SHA-256 is the committed one: $(cut -c1-16 $k.sha256)…"
    else
        fail "$k.bin's SHA-256 is the committed one"
    fi
done

if ! ../../tools/hazard3/sim.sh ready; then
    echo "SKIP  the RTL: needs tools/hazard3/setup.sh"
elif [[ "$($LEAN version 2>&1)" != Lean* ]]; then
    echo "SKIP  the RTL comparison: needs tools/lean/setup.sh"
else
    ../../tools/hazard3/hash-cost.sh --quiet || FAILED=1
    ./compare.sh | grep -E '^(PASS|FAIL)' || FAILED=1
    [[ ${PIPESTATUS[0]} -eq 0 ]] || FAILED=1
fi

exit "$FAILED"
