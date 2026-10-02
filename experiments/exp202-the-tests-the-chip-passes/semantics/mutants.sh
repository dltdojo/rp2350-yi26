#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp202 — every wrong model in mutants.txt beside this file must be refused
# by the comparison: some binary must end differently from the RTL, or leave
# the region different.
#
#   mutants.sh        PASS/FAIL per mutant, naming the binaries that refused it
#
# Lean builds every one of them: nothing in a type says what `sra` should do.
# What refuses them is the suite, and for the four the suite cannot see — the
# reason probes/ exists — a probe. Each mutant rebuilds the model in a copy of
# lean/, a few seconds apiece.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
LEAN=../../../tools/lean/lean.sh
status=0

while IFS='|' read -r label what expr; do
    [[ -z "$label" || "$label" == \#* ]] && continue
    claim="$label: the comparison refuses a model where $what"
    if [[ ! "$expr" =~ ^(.*)\|(lean/[A-Za-z0-9_/]+\.lean)$ ]]; then
        echo "FAIL  $claim — no target file named"; status=1; continue
    fi
    # Only the runner is built: a proof in lean/Rv32/Proof.lean that the wrong
    # model breaks is not what this comparison is asked to show.
    lib="$($LEAN mutant-lib "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" rv32run)"; built=$?
    if [[ $built -eq 3 ]]; then echo "FAIL  $claim — the sed no longer matches its file"; status=1
    elif [[ $built -ne 0 ]]; then echo "FAIL  $claim — it does not even build, so this says nothing"; status=1
    elif ! run="$($LEAN exe rv32run "$lib")"; then echo "FAIL  $claim — rv32run did not build"; status=1
    else
        out="$(../compare.sh "$run")"
        if [[ $? -eq 0 ]]; then
            echo "FAIL  $claim — every binary still agrees"; status=1
        else
            by="$(grep -E '<- (differs|region differs)' <<< "$out" | awk '{print $1}')"
            echo "PASS  $claim — refused by $(wc -l <<< "$by"): $(head -4 <<< "$by" | tr '\n' ' ' | sed 's/ $//')$([[ $(wc -l <<< "$by") -gt 4 ]] && echo ' ...')"
        fi
    fi
    $LEAN drop-lib "$lib"
done < mutants.txt
exit "$status"
