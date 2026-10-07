#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tools/lean — the gap a round-trip proof cannot close, shown. An encoder and a
# decoder proved to agree with each other can both be wrong the same way; an
# assembler written by somebody else is what sees it. Every wrong version in
# MUTANTS must be accepted by Lean (the library builds, both theorems hold)
# and refused by JUDGE.
#
#   gap.sh MUTANTS GEN JUDGE NAME [--show]
#
#   MUTANTS   <label>|<what is wrong>|<sed>|<lean/file.lean>, one per line
#   GEN       a .lean file whose `main` prints what JUDGE reads; it is run
#             against each mutant's copy of the library
#   JUDGE     a command reading GEN's output on stdin, exit 0 = it agrees
#   NAME      who JUDGE is, for the messages: LLVM, pioasm
#   --show    also print the FAIL lines JUDGE gave for each mutant
#
#   GAP_INPUT   a file GEN reads on stdin (otherwise it reads nothing)
#   GAP_PROOF   a proof outside the library that must still check against
#               each mutant: what "passes" names, in place of both theorems
#
# Run from the directory MUTANTS and GEN are in. Each mutant rebuilds the
# library in a copy (tools/lean/lean.sh mutant-lib). exp201 wrote this for
# LLVM; exp215 needed it second, for pioasm; exp217 added a proof outside the
# library, and cases for GEN to run.

set -u
LEAN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lean.sh"
mutants="$1" gen="$2" judge="$3" name="$4" show="${5-}"
status=0
passes="both theorems"
[[ -n "${GAP_PROOF-}" ]] && passes="$(basename "$GAP_PROOF")"

while IFS='|' read -r label what expr; do
    [[ -z "$label" || "$label" == \#* ]] && continue
    claim="$label: a version where $what passes $passes and fails against $name"
    if [[ ! "$expr" =~ ^(.*)\|(lean/[A-Za-z0-9_/]+\.lean)$ ]]; then
        echo "FAIL  $claim — no target file named"; status=1; continue
    fi
    lib="$($LEAN mutant-lib "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")"; built=$?
    if [[ $built -eq 3 ]]; then echo "FAIL  $claim — the sed no longer matches its file"; status=1
    elif [[ $built -ne 0 ]]; then echo "FAIL  $claim — Lean refused it, so it is not the gap this shows"; status=1
    elif [[ -n "${GAP_PROOF-}" ]] && ! $LEAN holds "$GAP_PROOF" "$lib"; then
        echo "FAIL  $claim — $passes refused it, so it is not the gap this shows"; status=1
    else
        said="$($LEAN exec "$gen" "$lib" < "${GAP_INPUT:-/dev/null}" | $judge)"
        if [[ $? -eq 0 ]]; then echo "FAIL  $claim — $name agreed with it"; status=1
        else echo "PASS  $claim"; fi
        [[ "$show" == --show ]] && grep '^FAIL' <<< "$said" | sed "s/^FAIL /      $name:/"
    fi
    $LEAN drop-lib "$lib"
done < "$mutants"
exit "$status"
