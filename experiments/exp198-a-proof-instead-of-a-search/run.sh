#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp198 run — the whole experiment, recorded to capture.txt. No board.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

LEAN=../../tools/lean/lean-4.34.0-linux/bin/lean

{
capture_header "exp198 — a proof instead of a search"

echo ">>> the proof: every theorem, and what it rests on"
echo "    $("$LEAN" --version)"
echo
"$LEAN" proof/ClientPin.lean 2>&1
echo "exit $?"
echo

echo ">>> the wrong versions: each must be refused"
while IFS='|' read -r finding what expr; do
    [[ -z "$finding" || "$finding" == \#* ]] && continue
    sed "$expr" proof/ClientPin.lean > "${TMPDIR:-/tmp}/exp198-Mutant.lean"
    # Where the checker stopped, as the theorem it stopped in: the first step
    # that no longer holds, which is rarely the headline theorem.
    line="$("$LEAN" "${TMPDIR:-/tmp}/exp198-Mutant.lean" 2>&1 | grep -m1 -oE 'Mutant\.lean:[0-9]+:[0-9]+: error' | cut -d: -f2)"
    if [[ -n "$line" ]]; then
        where="$(head -n "$line" "${TMPDIR:-/tmp}/exp198-Mutant.lean" | grep -oE '^theorem [A-Za-z_]+' | tail -1 | cut -d' ' -f2)"
        printf '%s  %-54s refused in %s\n' "$finding" "$what" "$where"
    else
        printf '%s  %-54s ACCEPTED\n' "$finding" "$what"
    fi
done < proof/mutants.txt
rm -f "${TMPDIR:-/tmp}/exp198-Mutant.lean"
} 2>&1 | tee capture.txt
