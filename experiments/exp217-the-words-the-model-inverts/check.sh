#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp217 quick check — non-interactive, and no board anywhere in it.
#
#   1. the proof checks, and rests on Lean's own axioms only: exp214's
#      `invert` program, run on lean/Pio/Machine.lean, hands back the
#      complement of every word in TX, in order, and waits when TX is empty;
#   2. every wrong model in proof/mutants.txt is refused by it;
#   3. the model, step by step, against rp2040js and rp2040-pio-emulator on
#      700 seeded cases: every disagreement is one of the emulator's named
#      deviations, each with the datasheet's reason;
#   4. every wrong model in differential/mutants.txt passes the proof and is
#      refused by (3) — what a theorem about one program cannot see.
#
# Needs Lean (tools/lean/setup.sh) and the emulators
# (tools/pio-emulators/setup.sh), with node and python3; without either it
# says SKIP for what it cannot run. A few minutes, most of it the fifteen
# wrong models rebuilding the library.
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

$LEAN check proof/Invert.lean || FAILED=1
$LEAN mutants proof/Invert.lean || FAILED=1

if ! ../../tools/pio-emulators/setup.sh ready; then
    echo "SKIP  the emulator differential: needs tools/pio-emulators/setup.sh"
elif [[ "$($LEAN version 2>&1)" != Lean* ]]; then
    echo "SKIP  the emulator differential: needs tools/lean/setup.sh"
else
    work="$(mktemp -d)"
    if differential/traces.sh "$work" --lean; then
        said="$(python3 differential/differential.py "$work"/{cases,lean,js,py})" || FAILED=1
        grep -E '^(PASS|FAIL)' <<< "$said"
    else
        echo "FAIL  the three runners ran on the cases"; FAILED=1
    fi
    rm -rf "$work"
    differential/gap.sh || FAILED=1
fi

exit "$FAILED"
