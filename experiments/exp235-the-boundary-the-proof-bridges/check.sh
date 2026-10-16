#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp235 quick check — non-interactive, zero hardware requirements.
#
#   1. Rv32.Machine zero-line modification check: lean/Rv32/Machine.lean has no diff.
#   2. The bridge proof checks, on Lean's own axioms only:
#      - Hazard3 PMP NAPOT readback quirks (bits [1:0] == 0b11)
#      - Default-deny when PMP entries are OFF
#      - Illegal instruction traps for CSR and MRET in U-mode
#      - Counter inhibit invariance (mcycle and minstret)
#      - PMP UBoxed equivalence
#      - Tier 2 to Tier 1 step-for-step simulation without traps
#   3. Every wrong version and wrong claim in proof/mutants.txt is refused.
#   4. Independent Python test vectors for NAPOT decoding and PMP boundary checks.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=0
LIFELINE="no: no firmware of its own"
presence_check
lifeline_check

USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

# 1. Tier 1 immutability check
if git diff --quiet ../../lean/Rv32/Machine.lean; then
    pass "lean/Rv32/Machine.lean is completely untouched (0 lines modified)"
else
    fail "lean/Rv32/Machine.lean was modified (violates Tier 1 zero-modification rule)"
fi

# 2. Check proof on Lean's axioms only
LEAN=../../tools/lean/lean.sh
$LEAN check proof/Bridge.lean || FAILED=1

# 3. Mutants check
[[ -f proof/mutants.txt ]] && { $LEAN mutants proof/Bridge.lean || FAILED=1; }

# 4. Python test vectors
python3 test_vectors.py || FAILED=1

exit "$FAILED"

