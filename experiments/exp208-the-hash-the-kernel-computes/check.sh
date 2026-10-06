#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp208 quick check — non-interactive, and no board anywhere in it.
#
#   1. the proof checks, and rests on Lean's own axioms only: from `base`, the
#      kernel halts with 0 after exactly 4990 + 4873 n instructions, and the
#      32 bytes it leaves at R + 0x140 are the specification's SHA-256 of the
#      n-block message — for every base and every message that fits;
#   2. every wrong kernel, wrong claim and wrong specification in
#      proof/mutants.txt is refused;
#   3. sha.bin is the bytes the proof is about — Lean writes them again, byte
#      for byte — and its SHA-256 is the committed one;
#   4. on ten messages the model and the RTL leave hashlib's SHA-256, the
#      model in the theorem's count and the RTL 3 more, and the specification,
#      run, says the same.
#
# Needs Lean (tools/lean/setup.sh); (4) also the Hazard3 testbench
# (tools/hazard3/setup.sh). Without either it says SKIP for what it cannot
# run. About ten minutes on four cores, nearly all of it the mutants.
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
$LEAN check proof/Sha.lean || FAILED=1
$LEAN mutants proof/Sha.lean || FAILED=1

if [[ "$($LEAN version 2>&1)" != Lean* ]]; then
    echo "SKIP  sha.bin against the proof: needs tools/lean/setup.sh"
else
    work="$(mktemp -d)"
    $LEAN exec proof/Sha.lean kernel "$work/sha.bin" > /dev/null
    if cmp -s "$work/sha.bin" sha.bin; then
        pass "sha.bin is the bytes the proof is about: Lean writes the same $(stat -c %s sha.bin)"
    else
        fail "sha.bin is the bytes the proof is about" "Lean wrote something else"
    fi
    rm -rf -- "$work"
fi
if [[ "$(sha256sum sha.bin | cut -d' ' -f1)" == "$(cat sha.sha256)" ]]; then
    pass "sha.bin's SHA-256 is the committed one: $(cut -c1-16 sha.sha256)…"
else
    fail "sha.bin's SHA-256 is the committed one"
fi

if ! ../../tools/hazard3/sim.sh ready; then
    echo "SKIP  the RTL: needs tools/hazard3/setup.sh"
elif [[ "$($LEAN version 2>&1)" != Lean* ]]; then
    echo "SKIP  the model and the specification: needs tools/lean/setup.sh"
else
    python3 compare.py "$($LEAN exe rv32run)" sha.bin "$LEAN exec proof/Sha.lean digest" | grep -E '^(PASS|FAIL)'
    [[ ${PIPESTATUS[0]} -eq 0 ]] || FAILED=1
fi

exit "$FAILED"
