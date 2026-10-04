#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp201 quick check — non-interactive, and no board anywhere in it.
#
# Four things, the first three through tools/lean like exp198 and exp199:
#
#   1. the two theorems in lean/Rv32/Isa.lean check, and rest on Lean's own
#      axioms only;
#   2. every wrong version in proof/mutants.txt is refused;
#   3. LLVM agrees with every encoding Lean makes and every reading it gives —
#      the only check here that compares against somebody else's reading of
#      the specification;
#   4. every wrong version in differential/mutants.txt — one the theorems
#      cannot see, because the mistake is the same in both directions — is
#      accepted by Lean and refused by LLVM. A pass here is the reason (3)
#      exists.
#
# It needs the network once, for tools/lean/setup.sh, and `llvm-mc` and
# `llvm-objdump` with the RISC-V target (Ubuntu's `llvm` package has it).
# Each library mutant rebuilds lean/Rv32/Isa.lean, about forty seconds apiece;
# the whole check takes four or five minutes.
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

# The subject is the RISC-V instruction encoding; nothing here touches USB.
USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

LEAN=../../tools/lean/lean.sh

$LEAN check proof/Roundtrip.lean || FAILED=1
$LEAN mutants proof/Roundtrip.lean || FAILED=1

if ! command -v llvm-mc > /dev/null || ! llvm-mc --version | grep -q riscv32; then
    echo "SKIP  the LLVM differential: needs llvm-mc with the riscv32 target"
elif [[ "$($LEAN version 2>&1)" != Lean* ]]; then
    echo "SKIP  the LLVM differential: needs tools/lean/setup.sh"
else
    $LEAN exec differential/Gen.lean | python3 differential/differential.py || FAILED=1

    differential/gap.sh || FAILED=1
fi

exit "$FAILED"
