#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tools/tlc — run TLC over an experiment's model directory, the same way for
# every experiment that has one.
#
# A model directory holds `*.tla`, one `.cfg` per question, and two files that
# make the experiment's claim checkable:
#
#   expected.txt   <module> <config> <holds|violated>   — what TLC must say
#   cited.txt      <path>:<line>|<text>                  — every line of code the
#                  model translates, and a piece of that line, so a crate that
#                  changes under the model turns a check red instead of leaving
#                  a model of code that no longer exists
#
# Deterministic on purpose: one worker, breadth first, and no timings in what
# it prints, so two recordings of the same tree read the same.
#
#   tlc.sh table DIR            one line per configuration: verdict, states, path
#   tlc.sh check DIR            PASS/FAIL per configuration against expected.txt
#   tlc.sh cited DIR            PASS/FAIL per citation in cited.txt
#   tlc.sh parse DIR            PASS/FAIL: every module is well-formed (SANY)
#   tlc.sh trace DIR CONFIG     one counterexample in full
#
# exp195 wrote this first as its own model.sh; exp196 needed it second, which
# is the moment to extract.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
JAR="$HERE/tla2tools.jar"

mode="${1-}"; dir="${2-}"
[[ -n "$mode" && -d "$dir" ]] || { sed -n '3,24p' "${BASH_SOURCE[0]}"; exit 2; }
dir="$(cd "$dir" && pwd)"
# `cited` only reads text, so it runs without the jar — exp198 re-reads its
# citations this way and has no TLA+ model at all.
[[ "$mode" == cited || -f "$JAR" ]] || { echo "FAIL  tla2tools.jar is fetched — run tools/tlc/setup.sh (it needs the network once)"; exit 1; }

run_tlc() { # module config
    ( cd "$dir" && java -cp "$JAR" tlc2.TLC -deadlock -workers 1 -config "$2.cfg" \
        -metadir "$dir/../states/$2" "$1.tla" 2>&1 ) | grep -v '^Picked up JAVA_TOOL_OPTIONS'
}

configs() { grep -vE '^\s*(#|$)' "$dir/expected.txt"; }

verdict_of() { # tlc-output
    if grep -q 'No error has been found' <<< "$1"; then echo holds
    elif grep -q 'is violated' <<< "$1"; then echo violated
    else echo ERROR; fi
}

# A counterexample as the path it took: the actions, in order. TLC 2.19 names an
# action but not its arguments, and which firmware ran after which can BE the
# finding, so a model with a `fw` variable is shown as the sequence of what was
# running instead. `tlc.sh trace` has the whole of any one.
path_of() { # tlc-output config
    if grep -q '^/\\ fw = ' <<< "$1"; then
        grep -E '^/\\ fw = ' <<< "$1" | sed -E 's/.*= "?([^"]*)"?/\1/' | paste -sd' ' | sed 's/ / -> /g'
    else
        grep -E '^State [0-9]+: <' <<< "$1" | sed -E 's/^State [0-9]+: <//; s/ line [0-9].*//; s/>$//' \
            | grep -v '^Initial predicate' | paste -sd' ' | sed 's/ / -> /g'
    fi
}

case "$mode" in
    table)
        status=0
        while read -r module config _; do
            out="$(run_tlc "$module" "$config")"
            said="$(verdict_of "$out")"; [[ "$said" == ERROR ]] && status=1
            states="$(grep -oE '[0-9]+ distinct states found' <<< "$out" | cut -d' ' -f1)"
            trace=""; [[ "$said" == violated ]] && trace="$(path_of "$out" "$config")"
            printf '%-10s %-40s %-9s %5s states  %s\n' "$module" "$config" "$said" "${states:-?}" "$trace"
        done < <(configs)
        exit "$status";;
    check)
        status=0
        while read -r module config want; do
            got="$(verdict_of "$(run_tlc "$module" "$config")")"
            if [[ "$got" == "$want" ]]; then echo "PASS  $config: $want"
            else echo "FAIL  $config: $want — TLC says $got"; status=1; fi
        done < <(configs)
        exit "$status";;
    cited)
        status=0
        while IFS='|' read -r where want; do
            [[ -z "$where" || "$where" == \#* ]] && continue
            file="${where%:*}"; line="${where##*:}"
            got="$(sed -n "${line}p" "$ROOT/$file" 2>/dev/null)"
            if [[ "$got" == *"$want"* ]]; then echo "PASS  the citation $where is still: $want"
            else echo "FAIL  the citation $where still holds — line $line of $file is now: ${got:-missing}"; status=1; fi
        done < "$dir/cited.txt"
        exit "$status";;
    parse)
        status=0
        for m in "$dir"/*.tla; do
            if ( cd "$dir" && java -cp "$JAR" tla2sany.SANY "$(basename "$m")" 2>&1 ) | grep -q 'Semantic processing of module'; then
                echo "PASS  $(basename "$m") parses"
            else echo "FAIL  $(basename "$m") parses"; status=1; fi
        done
        exit "$status";;
    trace)
        module="$(configs | awk -v c="$3" '$2 == c { print $1 }')"
        run_tlc "$module" "$3" | sed -n '/^Error: Invariant/,/^[0-9]* states generated/p';;
    *)
        sed -n '3,24p' "${BASH_SOURCE[0]}"; exit 2;;
esac
