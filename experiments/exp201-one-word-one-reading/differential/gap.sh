#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp201 — the gap two theorems cannot close, shown: every wrong version in
# mutants.txt beside this file must be accepted by Lean (both theorems still
# hold, because the mistake is the same in both directions) and refused by
# the LLVM differential.
#
#   gap.sh            PASS/FAIL per mutant
#   gap.sh --show     the same, with what LLVM said about each
#
# Each mutant rebuilds lean/Rv32/Isa.lean in a copy: about forty seconds.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
LEAN=../../../tools/lean/lean.sh
show="${1-}"
status=0

while IFS='|' read -r label what expr; do
    [[ -z "$label" || "$label" == \#* ]] && continue
    claim="$label: a version where $what passes both theorems and fails against LLVM"
    if [[ ! "$expr" =~ ^(.*)\|(lean/[A-Za-z0-9_/]+\.lean)$ ]]; then
        echo "FAIL  $claim — no target file named"; status=1; continue
    fi
    lib="$($LEAN mutant-lib "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")"; built=$?
    if [[ $built -eq 3 ]]; then echo "FAIL  $claim — the sed no longer matches its file"; status=1
    elif [[ $built -ne 0 ]]; then echo "FAIL  $claim — Lean refused it, so it is not the gap this shows"; status=1
    else
        said="$($LEAN exec Gen.lean "$lib" | python3 differential.py)"
        if [[ $? -eq 0 ]]; then echo "FAIL  $claim — LLVM agreed with it"; status=1
        else echo "PASS  $claim"; fi
        [[ "$show" == --show ]] && grep '^FAIL' <<< "$said" | sed 's/^FAIL /      LLVM:/'
    fi
    $LEAN drop-lib "$lib"
done < mutants.txt
exit "$status"
