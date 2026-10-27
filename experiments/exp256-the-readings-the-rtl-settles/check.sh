#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp256 quick check — non-interactive, and no board anywhere in it.
#
#   1. privrun builds: the Tier 2 model, `PrivMachine.step`, compiled (lean/PrivExec.lean);
#   2. differential/differential.py: every run every monitor suite here makes, on the model after every step and, from reset,
#      on the Hazard3 RTL as the RP2350 configures it -- every difference one of the kinds README.md names;
#   3. probes/probes.py --check: twenty-three probes on the emulator, the model and two RTL configurations print
#      what probes/table.txt recorded;
#   4. model/mutants.py: every wrong model in model/mutants.txt is refused by the differential.
#
# Needs Lean (tools/lean/setup.sh) and the Hazard3 testbenches (tools/hazard3/setup.sh: git, verilator, clang++),
# each fetched once. Without Lean it says SKIP and succeeds; without the testbenches, (2) holds the model alone and
# (3) is skipped. (2) runs about sixteen million steps twice over, and (4) rebuilds the model twelve times: the
# whole of it is the better part of an hour.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# No board, no person: a machine and nothing else. The RTL is the chip's core, simulated, on this machine.
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
TB=../../tools/hazard3/Hazard3/test/sim/tb_verilator/tb-rp2350

if [[ "$($LEAN version 2>&1)" != Lean* ]]; then
    echo "SKIP  the differential: needs tools/lean/setup.sh"
    exit "$FAILED"
fi

if PRIVRUN="$($LEAN exe privrun)"; then
    pass "privrun builds: PrivMachine.step, compiled, from lean/PrivExec.lean"
else
    fail "privrun builds" "$LEAN exe privrun"
    exit "$FAILED"
fi
export PRIVRUN

if [[ -x "$TB" ]]; then
    python3 differential/differential.py || FAILED=1
    python3 probes/probes.py --check || FAILED=1
else
    echo "SKIP  the RTL half: needs tools/hazard3/setup.sh"
    python3 differential/differential.py --model || FAILED=1
fi
python3 model/mutants.py || FAILED=1

exit "$FAILED"
