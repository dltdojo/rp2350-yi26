#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp235 quick check — non-interactive, zero hardware requirements.
#
#   1. Rv32.Machine zero-line modification check: lean/Rv32/Machine.lean has no diff
#      against the commit before the privileged model.
#   2. The bridge proof checks, on Lean's own axioms only:
#      - Hazard3 PMP NAPOT readback quirks (bits [1:0] == 0b11)
#      - Default-deny when PMP entries are OFF
#      - Illegal instruction traps for CSR and MRET in U-mode
#      - Counter inhibit invariance (mcycle and minstret)
#      - PMP UBoxed equivalence
#      - Tier 2 to Tier 1 step-for-step simulation without traps
#      - n-step refinement of Rv32.run (running and halted), the box kept, minstret + n
#   3. Every wrong version and wrong claim in proof/mutants.txt is refused.
#   4. Python test vectors for NAPOT decoding and PMP boundaries, run against the
#      Lean model itself (napot_eval.lean), which must agree on every one.
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

# 1. Tier 1 immutability: against the commit before Priv.lean existed, not against
#    the index — a plain `git diff` is empty the moment the change is committed.
TIER1_BASE=70ca711
if ! git cat-file -e "$TIER1_BASE^{commit}" 2>/dev/null; then
    fail "lean/Rv32/Machine.lean cannot be compared: commit $TIER1_BASE is not in this clone (shallow?)"
elif git diff --quiet "$TIER1_BASE" -- ../../lean/Rv32/Machine.lean; then
    pass "lean/Rv32/Machine.lean is byte-for-byte what it was at $TIER1_BASE, before the privileged model (0 lines modified)"
else
    fail "lean/Rv32/Machine.lean differs from $TIER1_BASE (violates Tier 1 zero-modification rule)"
fi

# 2. Check proof on Lean's axioms only
LEAN=../../tools/lean/lean.sh
$LEAN check proof/Bridge.lean || FAILED=1

# 3. Mutants check
[[ -f proof/mutants.txt ]] && { $LEAN mutants proof/Bridge.lean || FAILED=1; }

# 4. Python test vectors
python3 test_vectors.py || FAILED=1

exit "$FAILED"

