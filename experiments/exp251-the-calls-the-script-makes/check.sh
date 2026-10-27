#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp251 quick check — non-interactive, zero hardware requirements. No firmware of its own:
# it is about exp228's kernel.bin, whose own check.sh holds it to its proof.
#
#   1. proof/Calls.lean checks on Lean's own axioms: it holds exp228's proof/Script.lean as exp228's
#      check.sh holds it, and reads its run with lean/Rv32/Join.lean's calls_of_halted: in a world
#      that does not serve HASH, every call is HALT, HASHB or CHECKSIG with its ranges in the box.
#   2. Every mutant in proof/mutants.txt -- a claim that says more, the model loosened -- is refused.
#   3. proof/Calls.lean is what proof/gen.py writes from exp228's proof and tail.lean.
#   4. On the emulator: exp228's kernel alone on its 34 scripts and 120 fuzzed, every call recorded.
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

# 1. Formally proved theorems on Lean's axioms only
LEAN=../../tools/lean/lean.sh
# A refused mutant is a proof that fails, and a failing proof holds its goals in memory: two at a time.
export LEAN_JOBS="${LEAN_JOBS:-2}"
$LEAN check proof/Calls.lean || FAILED=1

# 2. Mutants check
[[ -f proof/mutants.txt ]] && { $LEAN mutants proof/Calls.lean || FAILED=1; }

# 3. The proof is what its generator writes
if python3 proof/gen.py --check; then
    echo "PASS  proof/Calls.lean is what proof/gen.py writes, from exp228's Script.lean and tail.lean"
else
    echo "FAIL  proof/Calls.lean is not what proof/gen.py writes"
    FAILED=1
fi

# 4. The calls on the emulator
python3 suite/calls.py || FAILED=1

exit "$FAILED"
