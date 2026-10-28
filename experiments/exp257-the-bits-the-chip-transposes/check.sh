#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp257 quick check — non-interactive, and no board anywhere in it.
#
#   1. proof/Chip.lean: exp240's box in the chip's bit order is bridged to the box exp240 proved, so the chip decides
#      every access as the model does; and each condition of the bridge is needed -- on Lean's axioms only;
#   2. proof/mutants.txt: wrong boxes, a reversed claim and a loosened bridge, each refused by Lean;
#   3. privrun builds, with `--pmp`: lean/Rv32/PmpChip.lean's chipCheck, compiled;
#   4. differential/pmpdiff.py: chipCheck in erratum E6's order decides as the core the RP2350 was built from
#      (tb_e6-rp2350), and in the specification's as the pinned core (tb-rp2350), on every one of 4,400 cases; and
#      each order is told apart from the other core;
#   5. probes/probes.py --check: what the two cores read back, as probes/table.txt recorded;
#   6. model/mutants.py: every wrong chipCheck in model/mutants.txt is refused by the differential.
#
# Needs Lean (tools/lean/setup.sh) and, for 4 to 6, the Hazard3 testbenches (tools/hazard3/setup.sh: git,
# verilator, clang++), each fetched once. Without Lean it says SKIP and succeeds; without the testbenches, 4 to 6
# say SKIP. The whole of it takes a few minutes.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# No board, no person: a machine and nothing else. Both cores are simulated, on this machine.
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
TBDIR=../../tools/hazard3/Hazard3/test/sim/tb_verilator

# 1, 2. The proof, and its mutants
$LEAN check proof/Chip.lean || FAILED=1
$LEAN mutants proof/Chip.lean || FAILED=1

if [[ "$($LEAN version 2>&1)" != Lean* ]]; then
    echo "SKIP  the differential: needs tools/lean/setup.sh"
    exit "$FAILED"
fi

# 3. privrun
if PRIVRUN="$($LEAN exe privrun)"; then
    pass "privrun builds: PrivMachine.step and, with --pmp, PmpChip.chipCheck, compiled, from lean/PrivExec.lean"
else
    fail "privrun builds" "$LEAN exe privrun"
    exit "$FAILED"
fi
export PRIVRUN

# 4 to 6. The two cores
if [[ -x "$TBDIR/tb_e6-rp2350" && -x "$TBDIR/tb-rp2350" ]]; then
    python3 differential/pmpdiff.py || FAILED=1
    python3 probes/probes.py --check || FAILED=1
    python3 model/mutants.py || FAILED=1
else
    echo "SKIP  the two cores: needs tools/hazard3/setup.sh"
fi

exit "$FAILED"
