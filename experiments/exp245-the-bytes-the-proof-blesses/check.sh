#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp245 quick check — non-interactive, zero hardware requirements.
#
#   1. monitor.bin: monitor.S assembles to it byte for byte, the SHA-256 matches, it is within
#      200 words, `monitorCode` in proof/Bless.lean is its words, and monitor.S with the three
#      charms taken away is exp240's monitor.bin, byte for byte.
#   2. proof/Bless.lean checks on Lean's own axioms: exp240's theorems for this binary, each
#      charm's own theorem, and for each the exposure theorem that says what it does not do.
#   3. Every mutant in proof/mutants.txt -- a charm's word, a claim, a word the monitor shares
#      with exp240, a rule of the model -- is refused.
#   4. proof/Bless.lean and proof/mutants.txt are what proof/gen.py writes.
#   5. On the emulator: the four acts of suite/charms_audit.py.
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

# 1. The binary, its budget, and the charms taken away
python3 monitor.py --check || FAILED=1

# 2. Formally proved theorems on Lean's axioms only
LEAN=../../tools/lean/lean.sh
# A refused mutant is a proof that fails, and a failing proof holds its goals in memory: two at a time.
export LEAN_JOBS="${LEAN_JOBS:-2}"
$LEAN check proof/Bless.lean || FAILED=1

# 3. Mutants check
[[ -f proof/mutants.txt ]] && { $LEAN mutants proof/Bless.lean || FAILED=1; }

# 4. The proof and its mutants are what the generator writes
if python3 proof/gen.py --check; then
    echo "PASS  proof/Bless.lean and proof/mutants.txt are what proof/gen.py writes"
else
    echo "FAIL  proof/Bless.lean or proof/mutants.txt is not what proof/gen.py writes"
    FAILED=1
fi

# 5. The four acts on the emulator
python3 suite/charms_audit.py || FAILED=1

exit "$FAILED"
