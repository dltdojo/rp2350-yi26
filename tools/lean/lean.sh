#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tools/lean — check an experiment's Lean proof the same way for every
# experiment that has one.
#
# A proof directory holds one `.lean` file and two files that make its claim
# checkable, the way a tools/tlc model directory does:
#
#   cited.txt      <path>:<line>|<text>   — every line of Rust the proof
#                  transcribes; `tools/tlc/tlc.sh cited DIR` re-reads them
#   mutants.txt    <label>|<what>|<sed>   — wrong versions of the code, each
#                  written into the proof with sed; Lean must refuse every one
#
#   lean.sh check FILE      PASS/FAIL: it checks, with no errors or warnings, and
#                           every `#print axioms` lists Lean's own axioms only
#   lean.sh mutants FILE    PASS/FAIL per line of mutants.txt beside FILE
#   lean.sh run FILE        what Lean prints, and its exit status
#   lean.sh table FILE      one line per mutant: refused in which theorem
#   lean.sh version         the pinned Lean's own version line
#
# Without tools/lean/setup.sh having run, `check` and `mutants` say SKIP and
# succeed: the proof needs the network once, and the rest of a check.sh does
# not. exp198 wrote these steps inline; exp199 needed them second, which is the
# moment to extract.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEAN_VERSION="$(sed -n 's/^LEAN_VERSION="\(.*\)"$/\1/p' "$HERE/setup.sh")"
LEAN="$HERE/lean-$LEAN_VERSION-linux/bin/lean"

mode="${1-}"; file="${2-}"
[[ "$mode" == version || -f "$file" ]] || { sed -n '3,25p' "${BASH_SOURCE[0]}"; exit 2; }
mutants="$(dirname "$file")/mutants.txt"

if [[ ! -x "$LEAN" ]]; then
    case "$mode" in
        check|mutants) echo "SKIP  $(basename "$file"): needs tools/lean/setup.sh (the network, once — 580 MB)"; exit 0;;
        *) echo "Lean $LEAN_VERSION is not here — run tools/lean/setup.sh"; exit 1;;
    esac
fi

each_mutant() { # callback: label what mutant-file changed
    local label what expr scratch
    scratch="$(mktemp -d)"
    while IFS='|' read -r label what expr; do
        [[ -z "$label" || "$label" == \#* ]] && continue
        sed "$expr" "$file" > "$scratch/Mutant.lean"
        if cmp -s "$file" "$scratch/Mutant.lean"; then "$1" "$label" "$what" "$scratch/Mutant.lean" no
        else "$1" "$label" "$what" "$scratch/Mutant.lean" yes; fi
    done < "$mutants"
    rm -rf "$scratch"
}

status=0

# A wrong version must not check. The sed has to change something, or the
# mutant has drifted away from the file and is testing nothing.
judge_mutant() {
    local claim="$1: the proof refuses a crate where $2"
    if [[ "$4" == no ]]; then echo "FAIL  $claim — the sed no longer matches $(basename "$file")"; status=1
    elif "$LEAN" "$3" > /dev/null 2>&1; then echo "FAIL  $claim — Lean accepted it"; status=1
    else echo "PASS  $claim"; fi
}

# Where the checker stopped, as the theorem it stopped in: the first step that
# no longer holds, which is rarely the headline theorem.
where_refused() {
    local line where
    line="$("$LEAN" "$3" 2>&1 | grep -m1 -oE 'Mutant\.lean:[0-9]+:[0-9]+: error' | cut -d: -f2)"
    if [[ -n "$line" ]]; then
        where="$(head -n "$line" "$3" | grep -oE '^theorem [A-Za-z0-9_]+' | tail -1 | cut -d' ' -f2)"
        printf "%-${lw}s  %-${width}s refused in %s\n" "$1" "$2" "$where"
    else
        printf "%-${lw}s  %-${width}s ACCEPTED\n" "$1" "$2"
    fi
}

case "$mode" in
    version)
        "$LEAN" --version;;
    run)
        "$LEAN" "$file" 2>&1
        echo "exit $?";;
    check)
        out="$("$LEAN" "$file" 2>&1)"; code=$?
        if [[ $code -eq 0 ]] && ! grep -qE 'error|warning' <<< "$out"; then
            echo "PASS  $(basename "$file") checks, with no errors and no warnings"
        else
            echo "FAIL  $(basename "$file") checks — $(head -3 <<< "$out")"; status=1
        fi
        asked="$(grep -c '^#print axioms' "$file")"
        printed="$(grep -c "depends on axioms\|does not depend on any axioms" <<< "$out")"
        if [[ "$asked" -gt 0 && "$printed" -eq "$asked" ]] && ! grep -q 'sorryAx' <<< "$out"; then
            echo "PASS  all $asked theorems it prints rest on Lean's own axioms only — no sorryAx"
        else
            echo "FAIL  no theorem is assumed rather than proved — $printed of $asked printed; sorryAx: $(grep -c sorryAx <<< "$out")"
            status=1
        fi;;
    mutants)
        each_mutant judge_mutant;;
    table)
        width="$(awk -F'|' '!/^#/ && NF >= 3 { if (length($2) > w) w = length($2) } END { print (w + 2 > 54 ? w + 2 : 54) }' "$mutants")"
        lw="$(awk -F'|' '!/^#/ && NF >= 3 { if (length($1) > w) w = length($1) } END { print w }' "$mutants")"
        each_mutant where_refused;;
    *)
        sed -n '3,25p' "${BASH_SOURCE[0]}"; exit 2;;
esac
exit "$status"
