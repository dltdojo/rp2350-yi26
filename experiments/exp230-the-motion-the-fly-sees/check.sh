#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp230 quick check — non-interactive, and no board anywhere in it.
#
#   1. the proof checks, on Lean's own axioms only: the kernel, from base,
#      halts with 0 after exactly 70924 instructions having written what moved
#      up and what moved down at each of 256 steps between 257 frames, and
#      their totals (T1); a frame moved one cell is seen moving its way unless
#      it has period two (T2); and whatever the ring holds, Rule 30 is seen
#      moving up or not at all (T3) — so the kernel shown exp225's life
#      reports up at least down, every step; and every wrong kernel and wrong
#      claim in proof/mutants.txt is refused;
#   2. kernel.py writes the kernel the proof holds, and kernel.bin is what the
#      proof writes, its SHA-256 the committed one;
#   3. the model and the RTL, on the named stimuli and random frames, against
#      fly.py: every step's counts, the totals, and one count of instructions.
#
# Needs Lean (tools/lean/setup.sh) and the Hazard3 testbench
# (tools/hazard3/setup.sh); without them it says SKIP for what it cannot run.
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

# No board, no person, nothing to look at: a machine and nothing else.
USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

LEAN=../../tools/lean/lean.sh
$LEAN check proof/Fly.lean || FAILED=1
[[ -f proof/mutants.txt ]] && { $LEAN mutants proof/Fly.lean || FAILED=1; }

if python3 kernel.py --check; then
    pass "proof/Fly.lean's kernel is what kernel.py writes from its labels"
else
    fail "proof/Fly.lean's kernel is what kernel.py writes from its labels"
fi

if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! ../../tools/hazard3/sim.sh ready; then
    echo "SKIP  kernel.bin and the differential: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi
work="$(mktemp -d)"
$LEAN exec proof/Fly.lean "$work/kernel.bin" > /dev/null
if cmp -s "$work/kernel.bin" kernel.bin && [[ "$(sha256sum kernel.bin | cut -d' ' -f1)" == "$(cat kernel.sha256)" ]]; then
    pass "kernel.bin is what proof/Fly.lean writes, $(stat -c %s kernel.bin) bytes, and kernel.sha256 is its hash"
else
    fail "kernel.bin is what proof/Fly.lean writes"
fi
rm -rf -- "$work"
python3 differential/differential.py "$($LEAN exe rv32run)" kernel.bin 20 || FAILED=1

exit "$FAILED"
