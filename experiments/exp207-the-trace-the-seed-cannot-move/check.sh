#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp207 quick check — non-interactive, and no board anywhere in it.
#
#   1. the proof checks, and rests on Lean's own axioms only: the checker in
#      lean/Rv32/Ct.lean is sound — whatever it accepts runs in lock step with
#      itself from any two states that agree on what is public — and it
#      accepts exp213's key generator (nothing public but its code) and signer
#      (the message, the index and the digit scratch public), so their traces
#      do not depend on the seed;
#   2. every non-constant-time kernel, wrong claim and unsound checker rule in
#      proof/mutants.txt is refused;
#   3. on the model and the RTL, the key generator under two seeds and the
#      signer under three take the same count, minstret and mcycle — and
#      another message, a public input, does move them.
#
# Needs Lean (tools/lean/setup.sh); (3) also the Hazard3 testbench
# (tools/hazard3/setup.sh). Without either it says SKIP for what it cannot
# run. About twenty minutes: (2) on four cores, and two key generations on
# the RTL, six minutes each.
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
$LEAN check proof/Trace.lean || FAILED=1
$LEAN mutants proof/Trace.lean || FAILED=1

if ! ../../tools/hazard3/sim.sh ready; then
    echo "SKIP  the RTL: needs tools/hazard3/setup.sh"
elif [[ "$($LEAN version 2>&1)" != Lean* ]]; then
    echo "SKIP  the model: needs tools/lean/setup.sh"
else
    python3 timing.py | grep -E '^(PASS|FAIL)' || FAILED=1
    [[ ${PIPESTATUS[0]} -eq 0 ]] || FAILED=1
fi

exit "$FAILED"
