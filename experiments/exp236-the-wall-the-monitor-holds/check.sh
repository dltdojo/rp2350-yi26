#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp236 quick check — non-interactive, zero hardware requirements.
#
#   1. monitor.bin: monitor.S assembles to it byte for byte, the SHA-256 matches, it is within
#      150 instructions, and `monitorCode` in proof/Monitor.lean is its words, in order.
#   2. proof/Monitor.lean checks on Lean's own axioms, and proves what monitor.bin does when
#      PrivMachine runs its words:
#        - boot: from reset, the PMP fences the payload into 64 KiB, the machine is in U-mode
#          at the payload's first word, every register but sp is zero;
#        - the trap handler: HALT, a trap, a bad ecall each end parked, with every register but
#          a0 zero, mscratch and the saved words zero;
#        - the payload: in U-mode it stays boxed or traps, and writes only inside the box;
#        - end to end: from reset, whatever the payload does.
#   3. Every mutant in proof/mutants.txt — a word of the monitor, or a rule of the model — is refused.
#   4. On the emulator: the exp229 field kernel runs under the monitor and its results are right.
#   5. On the emulator: hostile payloads end parked and scrubbed with the hardware's cause.
#   6. On the emulator: twelve monitors with one thing wrong each are caught by 4 and 5.
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

# 6. Monitors with one thing wrong each
python3 cases/broken_monitors.py || FAILED=1

exit "$FAILED"
