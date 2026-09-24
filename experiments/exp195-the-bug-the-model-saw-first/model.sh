#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp195 model half — run TLC on every configuration model/expected.txt names,
# and print one line each: what TLC said, how many states it saw, and, for a
# violation, the actions of the shortest counterexample.
#
# Deterministic on purpose: one worker, breadth first, and no timings in the
# output, so that two recordings of the same tree read the same.
#
#   ./model.sh          prints the table; exit 1 if TLC itself failed on any
#   ./model.sh --trace CONFIG     the full counterexample for one configuration

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/model"
JAR=../tools/tla2tools.jar

tlc() { # module config
    java -cp "$JAR" tlc2.TLC -deadlock -workers 1 -config "$2.cfg" \
        -metadir "../states/$2" "$1.tla" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS'
}

if [[ "${1-}" == "--trace" ]]; then
    module="$(awk -v c="$2" '$2 == c { print $1 }' expected.txt)"
    tlc "$module" "$2" | sed -n '/^Error: Invariant/,/^[0-9]* states generated/p'
    exit 0
fi

status=0
while read -r module config _; do
    [[ -z "$module" || "$module" == \#* ]] && continue
    out="$(tlc "$module" "$config")"
    if grep -q 'No error has been found' <<< "$out"; then
        said=holds
    elif grep -q 'is violated' <<< "$out"; then
        said=violated
    else
        said=ERROR; status=1
    fi
    states="$(grep -oE '[0-9]+ distinct states found' <<< "$out" | cut -d' ' -f1)"
    # A counterexample as the path it took. TLC 2.19 names an action but not its
    # arguments, and which firmware was flashed after which IS the finding, so
    # where the model has a `fw` the path is the sequence of what was running.
    trace=""
    if [[ "$said" == violated ]]; then
        if grep -q '^/\\ fw = ' <<< "$out"; then
            trace="$(grep -E '^/\\ fw = ' <<< "$out" | sed -E 's/.*= "?([^"]*)"?/\1/' | paste -sd' ' | sed 's/ / -> /g')"
        else
            trace="$(grep -cE '^State [0-9]+: <' <<< "$out") states long — ./model.sh --trace $config"
        fi
    fi
    printf '%-10s %-40s %-9s %5s states  %s\n' "$module" "$config" "$said" "${states:-?}" "$trace"
done < expected.txt
exit "$status"
