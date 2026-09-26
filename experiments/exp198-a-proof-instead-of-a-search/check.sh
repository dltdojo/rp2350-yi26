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

LEAN=../../tools/lean/lean-4.34.0-linux/bin/lean
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# A wrong version must not check. The sed has to change something, or the
# mutant has drifted away from the file and is testing nothing.
lean_refuses() { # finding what sed-expression
    sed "$3" proof/ClientPin.lean > "$SCRATCH/Mutant.lean"
    if cmp -s proof/ClientPin.lean "$SCRATCH/Mutant.lean"; then
        fail "$1: the proof refuses a crate where $2" "the sed no longer matches proof/ClientPin.lean"
    elif "$LEAN" "$SCRATCH/Mutant.lean" > /dev/null 2>&1; then
        fail "$1: the proof refuses a crate where $2" "Lean accepted it"
    else
        pass "$1: the proof refuses a crate where $2"
    fi
}

if [[ -x "$LEAN" ]]; then
    out="$("$LEAN" proof/ClientPin.lean 2>&1)"; status=$?
    if [[ $status -eq 0 ]] && ! grep -qE 'error|warning' <<< "$out"; then
        pass "proof/ClientPin.lean checks, with no errors and no warnings"
    else
        fail "proof/ClientPin.lean checks" "$(head -3 <<< "$out")"
    fi
    printed="$(grep -c 'axioms' <<< "$out")"
    if [[ "$printed" -eq 5 ]] && ! grep -q 'sorryAx' <<< "$out"; then
        pass "all five theorems rest on Lean's own axioms only — no sorryAx"
    else
        fail "no theorem is assumed rather than proved" "$printed axiom lines; sorryAx: $(grep -c sorryAx <<< "$out")"
    fi
    while IFS='|' read -r finding what expr; do
        [[ -z "$finding" || "$finding" == \#* ]] && continue
        lean_refuses "$finding" "$what" "$expr"
    done < proof/mutants.txt
else
    echo "SKIP  the proof: needs tools/lean/setup.sh (the network, once — 580 MB)"
fi

../../tools/tlc/tlc.sh cited proof || FAILED=1

crate_test ../../crates/client-pin "crates/client-pin's tests pass — the code the proof is about still does what its tests say"

exit "$FAILED"
