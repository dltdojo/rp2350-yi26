#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp206 quick check — non-interactive, and no board anywhere in it.
#
#   1. the proof checks, and rests on Lean's own axioms only: the kernel halts
#      with 0 exactly when the 67 chain ends of a WOTS (w = 16) signature make
#      a leaf that the authentication path and the index's low four bits lift
#      to the root, and with 1 otherwise, at exactly instruction 3295 + 3 S,
#      S the HASH calls the chains make, writing nothing outside its two
#      scratch areas — for every base, every input, every HASH; and an image
#      holding what a signer produces under any of the 16 leaves is accepted;
#   2. every wrong kernel and every wrong claim in proof/mutants.txt is refused;
#   3. kernel.bin is the bytes the proof is about — Lean writes them again and
#      they are byte for byte the committed file — and its SHA-256 is the one
#      committed beside it;
#   4. the model, the RTL and Python give the same verdict and the same count
#      on 29 cases — all 16 leaves of one key signing, and 13 that must be
#      rejected or are edge cases — the region byte for byte the same.
#
# Needs Lean (tools/lean/setup.sh); (4) also the Hazard3 testbench
# (tools/hazard3/setup.sh) and clang, lld and llvm-objcopy. Without either it
# says SKIP for what it cannot run. About twenty minutes, most of it (2).
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
$LEAN check proof/Mss.lean || FAILED=1
$LEAN mutants proof/Mss.lean || FAILED=1

if [[ "$($LEAN version 2>&1)" != Lean* ]]; then
    echo "SKIP  kernel.bin against the proof: needs tools/lean/setup.sh"
else
    work="$(mktemp -d)"
    $LEAN exec proof/Mss.lean "$work/kernel.bin" > /dev/null
    if cmp -s "$work/kernel.bin" kernel.bin; then
        pass "kernel.bin is the bytes the proof is about: Lean writes the same $(stat -c %s kernel.bin)"
    else
        fail "kernel.bin is the bytes the proof is about" "Lean wrote something else"
    fi
    rm -rf -- "$work"
fi
if [[ "$(sha256sum kernel.bin | cut -d' ' -f1)" == "$(cat kernel.sha256)" ]]; then
    pass "kernel.bin's SHA-256 is the committed one: $(cut -c1-16 kernel.sha256)…"
else
    fail "kernel.bin's SHA-256 is the committed one"
fi

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
