#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp215 quick check — non-interactive, and no board anywhere in it.
#
#   1. the proof checks, and rests on Lean's own axioms only: lean/Pio/Isa.lean's
#      encoder and decoder agree in both directions, so a PIO word has one
#      reading;
#   2. every wrong version in proof/mutants.txt is refused;
#   3. pioasm agrees with Lean over all 65536 words: each word Lean decodes,
#      printed and assembled, is that word again; and every instruction
#      pioasm accepts, at every delay, makes a word Lean decodes — together
#      exactly the words Lean decodes;
#   4. every wrong version in differential/mutants.txt passes both theorems
#      and is refused by (3) — the gap the theorems cannot close.
#
# Needs Lean (tools/lean/setup.sh) and pioasm (tools/pioasm/setup.sh); without
# either it says SKIP for what it cannot run. A few minutes, nearly all of it
# the ten mutants rebuilding the library.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# No board, no person, nothing to look at: a machine and nothing else.
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

$LEAN check proof/Roundtrip.lean || FAILED=1
$LEAN mutants proof/Roundtrip.lean || FAILED=1

if [[ ! -x ../../tools/pioasm/pioasm-2.3.1/pioasm ]]; then
    echo "SKIP  the pioasm differential: needs tools/pioasm/setup.sh"
elif [[ "$($LEAN version 2>&1)" != Lean* ]]; then
    echo "SKIP  the pioasm differential: needs tools/lean/setup.sh"
else
    $LEAN exec differential/Gen.lean | python3 differential/differential.py || FAILED=1
    differential/gap.sh || FAILED=1
fi

exit "$FAILED"
