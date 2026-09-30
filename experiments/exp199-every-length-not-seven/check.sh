#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp199 quick check — non-interactive, and no board anywhere in it.
#
# The same four things as exp198, through the same tools: the proof checks and
# rests on nothing but Lean's own axioms; every wrong version in
# proof/mutants.txt is refused; every Rust line the Lean transcribes is still
# what it was; and the crate's own tests still pass.
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

# The subject is a USB transport, and still no USB is used: the proof is about
# the crate's arithmetic over bytes, and it never runs on the board.
USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

../../tools/lean/lean.sh check proof/CtapHid.lean || FAILED=1
../../tools/lean/lean.sh mutants proof/CtapHid.lean || FAILED=1

../../tools/tlc/tlc.sh cited proof || FAILED=1

crate_test ../../crates/ctap-hid "crates/ctap-hid's tests pass — the seven lengths among them"

exit "$FAILED"
