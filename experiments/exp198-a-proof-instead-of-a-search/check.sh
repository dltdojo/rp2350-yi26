#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp198 quick check — non-interactive, and no board anywhere in it.
#
# Four things, and each is a way the proof could be worth less than it looks:
# the proof checks and rests on nothing but Lean's own axioms; every wrong
# version of the crate in proof/mutants.txt is refused; every Rust line the
# Lean transcribes is still what it was; and the crate's own tests still pass.
#
# It needs the network once, for tools/lean/setup.sh. After that it is offline.
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

# No USB anywhere in it: the subject is a crate's arithmetic, and the proof
# never runs on the board.
USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

# The proof checks, rests on nothing but Lean's own axioms, and refuses every
# wrong version of the crate in proof/mutants.txt.
../../tools/lean/lean.sh check proof/ClientPin.lean || FAILED=1
../../tools/lean/lean.sh mutants proof/ClientPin.lean || FAILED=1

../../tools/tlc/tlc.sh cited proof || FAILED=1

crate_test ../../crates/client-pin "crates/client-pin's tests pass — the code the proof is about still does what its tests say"

exit "$FAILED"
