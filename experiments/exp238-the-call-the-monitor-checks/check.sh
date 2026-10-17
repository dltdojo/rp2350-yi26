#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp238 quick check — non-interactive, zero hardware requirements.
#
#   1. monitor.bin: monitor.S assembles to it byte for byte, the SHA-256 matches, it is within
#      200 instructions, and `monitorCode` in proof/Calls.lean is its words, in order.
#   2. proof/Calls.lean checks on Lean's own axioms, and proves what monitor.bin does when
#      PrivMachine runs its words: HALT, the faults, HASHB and CHECKSIG served and refused, one
#      trap and what follows it, however many calls, from reset to the end.
#   3. Every mutant in proof/mutants.txt — a word of the monitor — is refused.
#   4. proof/Calls.lean is what proof/gen.py writes.
#   5. On the emulator: exp228's kernel runs its 34 scripts under the monitor, and 120 more.
#   6. On the emulator: payloads that lean on the calls are served or refused as they should be.
#   7. On the emulator: monitors with one thing wrong each are caught by 5 and 6.
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
# A refused mutant is a proof that fails, and a failing proof holds its goals in memory: two at a time.
export LEAN_JOBS="${LEAN_JOBS:-2}"
$LEAN check proof/Calls.lean || FAILED=1

# 3. Mutants check
[[ -f proof/mutants.txt ]] && { $LEAN mutants proof/Calls.lean || FAILED=1; }

# 4. The proof is what its generator writes
if python3 proof/gen.py --check; then
    echo "PASS  proof/Calls.lean is what proof/gen.py writes"
else
    echo "FAIL  proof/Calls.lean is not what proof/gen.py writes"
    FAILED=1
fi

# 5. exp228's kernel and its scripts under the monitor
python3 suite/kernel_cases.py || FAILED=1

# 6. Payloads that lean on the calls
python3 suite/attack_cases.py || FAILED=1

# 7. Monitors with one thing wrong each
python3 suite/broken_monitors.py || FAILED=1

exit "$FAILED"
