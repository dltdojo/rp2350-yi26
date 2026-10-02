#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp203 quick check — non-interactive, and no board anywhere in it.
#
#   1. the proof checks, and rests on Lean's own axioms only: the kernel copies
#      64 bytes and halts with 0 at exactly instruction 105, for every base,
#      every input, every register;
#   2. every wrong kernel and every wrong claim in proof/mutants.txt is refused;
#   3. kernel.bin is the bytes the proof is about — Lean writes them again and
#      they are byte for byte the committed file — and its SHA-256 is the one
#      committed beside it, which is the number the chip's shell will check;
#   4. on the RTL, minstret is the proved count plus a constant the harness
#      spends, each instruction counted once (accounting/measure.sh); and the
#      model and the RTL agree on four data sets, byte for byte.
#
# Needs Lean (tools/lean/setup.sh); (4) also the Hazard3 testbench
# (tools/hazard3/setup.sh) and clang, lld and llvm-objcopy. Without either it
# says SKIP for what it cannot run. About two minutes, most of it (2).
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
$LEAN check proof/Copy64.lean || FAILED=1
$LEAN mutants proof/Copy64.lean || FAILED=1

if [[ "$($LEAN version 2>&1)" != Lean* ]]; then
    echo "SKIP  kernel.bin against the proof: needs tools/lean/setup.sh"
else
    work="$(mktemp -d)"
    $LEAN exec proof/Copy64.lean "$work/kernel.bin" > /dev/null
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
    accounting/measure.sh --quiet || FAILED=1
    ./compare.sh | grep -E '^(PASS|FAIL)' || FAILED=1
    [[ ${PIPESTATUS[0]} -eq 0 ]] || FAILED=1
fi

exit "$FAILED"
