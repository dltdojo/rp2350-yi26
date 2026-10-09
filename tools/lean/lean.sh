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
#   mutants.txt    <label>|<what>|<sed>[|lean/<file>.lean]  — wrong versions
#                  of the code, each written with sed; Lean must refuse every
#                  one. Without the last field the sed edits the proof itself;
#                  with it, it edits that file of the shared library in lean/,
#                  and the proof is checked against the edited library
#
#   lean.sh check FILE      PASS/FAIL: it checks, with no errors or warnings, and
#                           every `#print axioms` lists Lean's own axioms only
#   lean.sh mutants FILE    PASS/FAIL per line of mutants.txt beside FILE
#   lean.sh run FILE        what Lean prints, and its exit status
#   lean.sh table FILE      one line per mutant: refused in which theorem
#
#   LEAN_VERDICTS=DIR       `table` also keeps, in DIR, the PASS/FAIL lines
#                           `mutants` would print, and `mutants` prints those
#                           instead of running Lean again on the same inputs:
#                           FILE, its mutants.txt and every .lean in lean/,
#                           by their bytes. A run.sh sets it, so its check.sh
#                           does not refuse every mutant a second time.
#   lean.sh exec FILE [LIB] [ARGS...]
#                           `lean --run FILE ARGS...`: run its `main`, against
#                           the library copy LIB if given (a directory with a
#                           lakefile.toml); ARGS go to the program
#   lean.sh mutant-lib SED FILE [TARGET]
#                           a copy of lean/ with SED applied to FILE, built —
#                           all of it, or only TARGET (e.g. rv32run, for a
#                           mutant the model's runs must refuse rather than a
#                           proof); prints the copy's path, which the caller
#                           removes
#   lean.sh exe NAME [LIB]  build the library's executable NAME, in LIB if
#                           given, and print its path
#   lean.sh drop-lib LIB    remove a copy mutant-lib made, and nothing else
#   lean.sh holds FILE LIB  exit 0 if FILE checks against the library copy LIB,
#                           with no errors and no warnings
#   lean.sh version         the pinned Lean's own version line
#
# A FILE that imports `Rv32` or `Pio` is about the shared library in lean/ (from exp201
# on): the library is built with `lake` first, and FILE is checked against it.
# The library's own theorems are checked by that build, so a mutant of the
# library can be refused by the build before FILE is ever read.
#
# Without tools/lean/setup.sh having run, `check` and `mutants` say SKIP and
# succeed: the proof needs the network once, and the rest of a check.sh does
# not. exp198 wrote these steps inline; exp199 needed them second, which is the
# moment to extract.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LEAN_VERSION="$(sed -n 's/^LEAN_VERSION="\(.*\)"$/\1/p' "$HERE/setup.sh")"
BIN="$HERE/lean-$LEAN_VERSION-linux/bin"
LEAN="$BIN/lean"

mode="${1-}"; file="${2-}"
case "$mode" in
    version|drop-lib|exe) ;;
    mutant-lib) [[ -f "$REPO/${3-}" ]] || { sed -n '3,41p' "${BASH_SOURCE[0]}"; exit 2; };;
    *) [[ -f "$file" ]] || { sed -n '3,41p' "${BASH_SOURCE[0]}"; exit 2; };;
esac
[[ "$mode" == mutant-lib ]] || mutants="$(dirname "$file")/mutants.txt"

if [[ ! -x "$LEAN" ]]; then
    case "$mode" in
        check|mutants) echo "SKIP  $(basename "$file"): needs tools/lean/setup.sh (the network, once — 580 MB)"; exit 0;;
        *) echo "Lean $LEAN_VERSION is not here — run tools/lean/setup.sh"; exit 1;;
    esac
fi

uses_lib() { grep -qE '^import (Rv32|Pio)' "$1"; }

# Lean on FILE, against the library in LIB when FILE imports it. A library that
# does not build is reported the way a proof that does not check is: Lean's
# own errors, and a non-zero status.
lean_on() { # file [lib]
    local f lib="${2:-$REPO/lean}"
    f="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    if uses_lib "$f"; then
        (cd "$lib" && PATH="$BIN:$PATH" lake build -q 2>&1 | grep -E 'error|warning' | head -20
         [[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
         PATH="$BIN:$PATH" lake env lean "$f")
    else
        "$LEAN" "$f"
    fi
}

# A copy of lean/ with one sed applied to one of its files, and built. The
# build output already in lean/.lake comes along, so only what the edit
# touches is rebuilt.
mutant_lib() { # sed target -> prints the copy's directory; status 3 = sed matched nothing
    local expr="$1" target="$2" scratch rel
    scratch="$(mktemp -d)"
    cp -r "$REPO/lean" "$scratch/lean"
    rel="${target#lean/}"
    sed -i "$expr" "$scratch/lean/$rel"
    echo "$scratch/lean"
    cmp -s "$REPO/$target" "$scratch/lean/$rel" && return 3
    return 0
}

# Removes a copy mutant_lib made, and nothing else: the path must be exactly
# what mktemp gave it, with the library in it. An empty or unexpected path is
# refused rather than resolved — `dirname ""` is `.`.
drop_lib() { # lib
    local lib="$1" tmp="${TMPDIR:-/tmp}"
    if [[ "$lib" =~ ^${tmp%/}/tmp\.[A-Za-z0-9]+/lean$ && -f "$lib/lakefile.toml" ]]; then
        rm -rf -- "${lib%/lean}"
    else
        echo "refusing to remove '$lib': not a library copy this script made" >&2
        return 1
    fi
}

# Each mutant is judged on its own copy, so they run side by side: LEAN_JOBS
# at a time (the cores, at most four — each is a Lean build), their lines
# printed in mutants.txt's order once all are done.
JOBS="${LEAN_JOBS:-$(n="$(nproc 2>/dev/null || echo 1)"; echo $(( n < 4 ? n : 4 )))}"

one_mutant() { # callback label what expr dir
    local cb="$1" label="$2" what="$3" expr="$4" dir="$5" target="" lib
    [[ "$mode" == table && -n "${LEAN_VERDICTS-}" ]] && VERDICT_OUT="$dir/verdict"
    # A sed may itself contain `|`, so the target is recognised by its
    # shape, last on the line, and only that.
    if [[ "$expr" =~ ^(.*)\|(lean/[A-Za-z0-9_/]+\.lean)$ ]]; then
        expr="${BASH_REMATCH[1]}"; target="${BASH_REMATCH[2]}"
    fi
    if [[ -n "$target" ]]; then
        lib="$(mutant_lib "$expr" "$target")"
        if [[ $? -eq 3 ]]; then "$cb" "$label" "$what" "$file" no "$lib"
        else "$cb" "$label" "$what" "$file" yes "$lib"; fi
        drop_lib "$lib"
    else
        sed "$expr" "$file" > "$dir/Mutant.lean"
        if cmp -s "$file" "$dir/Mutant.lean"; then "$cb" "$label" "$what" "$dir/Mutant.lean" no ""
        else "$cb" "$label" "$what" "$dir/Mutant.lean" yes ""; fi
    fi
}

each_mutant() { # callback: label what mutant-file changed lib
    local label what expr scratch n=0 running=0 i
    scratch="$(mktemp -d)"
    while IFS='|' read -r label what expr; do
        [[ -z "$label" || "$label" == \#* ]] && continue
        n=$((n + 1)); mkdir "$scratch/$n"
        one_mutant "$1" "$label" "$what" "$expr" "$scratch/$n" > "$scratch/$n/out" 2>&1 &
        running=$((running + 1))
        if [[ $running -ge $JOBS ]]; then wait -n; running=$((running - 1)); fi
    done < "$mutants"
    wait
    for ((i = 1; i <= n; i++)); do cat "$scratch/$i/out"; done
    if [[ "$mode" == table && -n "${LEAN_VERDICTS-}" ]]; then
        mkdir -p "$LEAN_VERDICTS"
        for ((i = 1; i <= n; i++)); do cat "$scratch/$i/verdict"; done > "$LEAN_VERDICTS/$(verdicts_key)"
    fi
    grep -q '^FAIL' "$scratch"/*/out 2>/dev/null && status=1
    rm -rf "$scratch"
}

status=0

# A wrong version must not check. The sed has to change something, or the
# mutant has drifted away from the file and is testing nothing.
#
# Lean running out of memory is not a refusal: it says nothing about the
# mutant. exp223 found it, four mutants side by side each loading SHA-256's
# proof, and a crash counted as a PASS. So a crash is a FAIL, inconclusive.
starved() { # output status
    [[ "$2" -eq 137 || "$2" -eq 134 ]] || grep -qE 'out of memory|INTERNAL PANIC' <<< "$1"
}

verdict() { # label what changed code out — the line `mutants` prints
    local claim="$1: the proof refuses a version where $2"
    if [[ "$3" == no ]]; then echo "FAIL  $claim — the sed no longer matches its file"
    elif [[ $4 -eq 0 ]]; then echo "FAIL  $claim — Lean accepted it"
    elif starved "$5" "$4"; then echo "FAIL  $claim — inconclusive: Lean ran out of memory (try LEAN_JOBS=1)"
    else echo "PASS  $claim"; fi
}

judge_mutant() {
    local out="" code=1
    [[ "$4" == no ]] || { out="$(lean_on "$3" "$5" 2>&1)"; code=$?; }
    verdict "$1" "$2" "$4" "$code" "$out"
}

# What LEAN_VERDICTS keeps verdicts under: FILE, its mutants and the library,
# by their bytes, so that a verdict is reused only for the inputs it judged.
verdicts_key() {
    { realpath "$file"; cat "$file" "$mutants"
      find "$REPO/lean" -name '*.lean' -not -path '*/.lake/*' | sort | xargs cat; } | sha256sum | cut -c1-32
}

# Where the checker stopped, as the theorem it stopped in: the first step that
# no longer holds, which is rarely the headline theorem.
where_refused() {
    local out loc path line where src code
    out="$(lean_on "$3" "$5" 2>&1)"; code=$?
    [[ -z "${VERDICT_OUT-}" ]] || verdict "$1" "$2" "$4" "$code" "$out" > "$VERDICT_OUT"
    if starved "$out" "$code"; then
        printf "%-${lw}s  %-${width}s INCONCLUSIVE: Lean ran out of memory\n" "$1" "$2"; return
    fi
    # Lean says `F.lean:L:C: error`; lake, building the library, `error: F.lean:L:C:`.
    loc="$(grep -m1 -oE '^error: [A-Za-z0-9_./-]+\.lean:[0-9]+:[0-9]+|[A-Za-z0-9_./-]+\.lean:[0-9]+:[0-9]+: error' <<< "$out" | sed 's/^error: //')"
    if [[ -n "$loc" ]]; then
        path="$(cut -d: -f1 <<< "$loc")"; line="$(cut -d: -f2 <<< "$loc")"
        if [[ -n "$5" && -f "$5/$path" ]]; then src="$5/$path"
        elif [[ -f "$path" ]]; then src="$path"
        else src="$3"; fi
        where="$(head -n "$line" "$src" | grep -oE '^(private )?theorem [A-Za-z0-9_.]+' | tail -1 | awk '{print $NF}')"
        printf "%-${lw}s  %-${width}s refused in %s\n" "$1" "$2" "${where:-$(basename "$src"):$line}"
    else
        printf "%-${lw}s  %-${width}s ACCEPTED\n" "$1" "$2"
    fi
}

case "$mode" in
    version)
        "$LEAN" --version;;
    run)
        lean_on "$file" 2>&1
        echo "exit $?";;
    exec)
        f="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
        shift 2
        lib="$REPO/lean"
        if [[ $# -gt 0 && -f "${1}/lakefile.toml" ]]; then lib="$1"; shift; fi
        if uses_lib "$f"; then
            # Built in the library's directory, run in the caller's, so that
            # a relative path among ARGS means what the caller meant by it.
            (cd "$lib" && PATH="$BIN:$PATH" lake build -q > /dev/null) || exit 1
            LEAN_PATH="$(cd "$lib" && PATH="$BIN:$PATH" lake env printenv LEAN_PATH)" \
                "$LEAN" --run "$f" "$@"
        else
            "$LEAN" --run "$f" "$@"
        fi
        status=$?;;
    drop-lib)
        drop_lib "$file"; status=$?;;
    holds)
        out="$(lean_on "$file" "$3" 2>&1)" && ! grep -qE 'error|warning' <<< "$out"; status=$?;;
    exe)
        lib="${3:-$REPO/lean}"
        if (cd "$lib" && PATH="$BIN:$PATH" lake build -q "$file" > /dev/null 2>&1); then
            echo "$lib/.lake/build/bin/$file"
        else
            echo "$file did not build in $lib" >&2; status=1
        fi;;
    mutant-lib)
        # Prints the copy's path whatever happens; the status says what did:
        # 0 it built, 1 the build refused it, 3 the sed matched nothing.
        lib="$(mutant_lib "$2" "$3")"; status=$?
        if [[ $status -eq 0 ]]; then
            (cd "$lib" && PATH="$BIN:$PATH" lake build -q ${4:+"$4"} > /dev/null 2>&1) || status=1
        fi
        echo "$lib";;
    check)
        out="$(lean_on "$file" 2>&1)"; code=$?
        if [[ $code -eq 0 ]] && ! grep -qE 'error|warning' <<< "$out"; then
            echo "PASS  $(basename "$file") checks, with no errors and no warnings"
        else
            echo "FAIL  $(basename "$file") checks — $(head -3 <<< "$out")"; status=1
        fi
        asked="$(grep -c '^#print axioms' "$file")"
        printed="$(grep -c "depends on axioms\|does not depend on any axioms" <<< "$out")"
        # `native_decide` and `bv_decide` prove by running compiled code, and
        # say so with an axiom of their own: the compiler is then part of what
        # is trusted. Neither is used here, and this keeps it that way.
        if [[ "$asked" -gt 0 && "$printed" -eq "$asked" ]] \
                && ! grep -qE 'sorryAx|Lean\.ofReduceBool|Lean\.trustCompiler' <<< "$out"; then
            echo "PASS  all $asked theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide"
        else
            echo "FAIL  no theorem is assumed rather than proved — $printed of $asked printed; sorryAx: $(grep -c sorryAx <<< "$out"); compiler: $(grep -cE 'ofReduceBool|trustCompiler' <<< "$out")"
            status=1
        fi;;
    mutants)
        kept="${LEAN_VERDICTS:+$LEAN_VERDICTS/$(verdicts_key)}"
        if [[ -n "$kept" && -s "$kept" ]]; then
            cat "$kept"; ! grep -q '^FAIL' "$kept" || status=1
        else
            each_mutant judge_mutant
        fi;;
    table)
        width="$(awk -F'|' '!/^#/ && NF >= 3 { if (length($2) > w) w = length($2) } END { print (w + 2 > 54 ? w + 2 : 54) }' "$mutants")"
        lw="$(awk -F'|' '!/^#/ && NF >= 3 { if (length($1) > w) w = length($1) } END { print w }' "$mutants")"
        each_mutant where_refused;;
    *)
        sed -n '3,41p' "${BASH_SOURCE[0]}"; exit 2;;
esac
exit "$status"
