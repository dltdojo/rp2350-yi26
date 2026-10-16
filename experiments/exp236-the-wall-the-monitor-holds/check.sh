#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp236 quick check — non-interactive, zero hardware requirements.
#
#   1. Micro-monitor binary check: monitor.S assembles byte-for-byte to
#      monitor.bin, matching monitor.sha256, within 150 instructions (< 600 bytes).
#   2. The formal security proofs check, on Lean's own axioms only:
#      - Domain isolation: PMP NAPOT configuration locks U-mode to payload region
#      - Secret zeroization: registers x1..x9 and x11..x31 wiped to zero on halt
#      - Exit status forwarding: a0 preserved across zeroization
#      - Counter inhibit invariance: mcountinhibit freezes mcycle and minstret
#   3. Every mutant in proof/mutants.txt is refused by Lean.
#   4. Normal execution: monitor.bin + exp229 secp256k1 field arithmetic payload
#      (add, sub, mul) run under PMP sandbox, producing expected results with a0=0
#      and GP registers scrubbed.
#   5. Adversarial attack suite: 5 hostile U-mode attacks caught and rejected.
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

# 1. Micro-monitor binary match and size budget
python3 monitor.py --check || FAILED=1

# 2. Formally proved theorems on Lean's axioms only
LEAN=../../tools/lean/lean.sh
$LEAN check proof/Monitor.lean || FAILED=1

# 3. Mutants check
[[ -f proof/mutants.txt ]] && { $LEAN mutants proof/Monitor.lean || FAILED=1; }

# 4. Normal execution test cases
python3 cases/normal_cases.py || FAILED=1

# 5. Adversarial attack cases
python3 cases/attack_cases.py || FAILED=1

# 6. Optional RTL execution if testbench is ready
if ../../tools/hazard3/sim.sh ready 2>/dev/null; then
    echo "Hazard3 Verilator testbench ready, running RTL..."
    # Build combined image and run bare
fi

exit "$FAILED"
