#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# calls/vk26/calibration — run the judge on the calibration cases, in stages,
# never more than three sessions at a time (twenty at once is what hit the
# session limit in round 2; see README.md).
#
#   run.sh A OUTDIR     stage A: one run per case, 7 runs (tiered: Opus for J2
#                       on the J2 slice, Sonnet for J1/J3/J4; two sessions a run)
#   run.sh B OUTDIR     stage B: two more runs per case, 14 runs; start it only
#                       once stage A was all correct. Then tallies each case.
#   run.sh sonnet OUTDIR  one run per case with Sonnet only (fast self-check)
#   run.sh opus OUTDIR    full Opus for all questions (all-Opus baseline)
#
# OUTDIR is created; the bundles and prompts go to OUTDIR/bundles (made afresh
# on every start; a stage refuses to go on if they changed under verdicts it
# already has), the verdicts to
# OUTDIR/<case>-<n>.txt, and what each session used, as claude reports it, to
# OUTDIR/<case>-<n>.txt.usage. A run whose verdict already exists is skipped,
# so an interrupted stage can simply be started again.
#
# The first run that fails (HTTP 429, a crash) stops the stage: no further run
# is started, the ones already running finish, and what is complete is
# tallied. Starting again after the limit resets picks up the rest. Exit 0 when
# every run of the stage has a verdict, 2 when the stage stopped short.
#
#   VK26_JOBS=N              concurrent runs (default 3, at most 3); with 1, a
#                            failure wastes nothing beyond the run that failed
#   VK26_CASES="a b ..."     only these cases, in this order (default all seven):
#                            VK26_CASES=good-exp225 run.sh A OUTDIR measures one
#                            run before the stage spends the rest

set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$HERE/../judge-bundle.sh"
STAGE="${1:-}"; OUT="${2:-}"
[[ "$STAGE" =~ ^(A|B|sonnet|opus)$ && -n "$OUT" ]] || { sed -n '3,31p' "${BASH_SOURCE[0]}"; exit 2; }
JOBS="${VK26_JOBS:-3}"; (( JOBS > 3 )) && JOBS=3
ALL=(good-exp225 good-exp230 good-exp234 overclaim trivial narrowed injection)
read -r -a CASES <<< "${VK26_CASES:-${ALL[*]}}"
for c in "${CASES[@]}"; do
    [[ " ${ALL[*]} " == *" $c "* ]] || { echo "unknown case: $c (cases: ${ALL[*]})" >&2; exit 2; }
done

# The bundles and the prompts are made afresh on every start and compared with
# OUTDIR/bundles: a case judged half on one bundle and half on another tallies
# into nothing. Only the `commit:` line may differ — committing a stage's
# verdicts moves HEAD. A verdict rests on its own case's bundle and on the
# prompts: when either changed under a verdict, the stage refuses; when only
# bundles no verdict rests on changed, the new ones replace the old.
mkdir -p "$OUT/bundles"
fresh="$(mktemp -d)"
trap 'rm -rf -- "${fresh:?}"' EXIT
"$HERE/cases.sh" "$fresh" >/dev/null
for q in J1,J3,J4 J2 J1,J2,J3,J4; do "$BUNDLE" prompt "$q" > "$fresh/prompt-$q.txt"; done
same() { # a b — equal but for the commit line
    [[ -f "$2" ]] && cmp -s <(grep -v '^commit: ' "$1") <(grep -v '^commit: ' "$2")
}
changed=()
for f in "$fresh"/*; do same "$f" "$OUT/bundles/${f##*/}" || changed+=("${f##*/}"); done
if (( ${#changed[@]} )); then
    judged=()
    for c in "${ALL[@]}"; do
        [[ " ${changed[*]} " == *" $c.txt "* || " ${changed[*]} " == *" prompt-"* ]] || continue
        for n in 1 2 3 s1; do
            grep -qs '^VERDICT vk26' "$OUT/$c-$n.txt" && judged+=("$c-$n.txt")
        done
    done
    if (( ${#judged[@]} )); then
        echo "REFUSED: ${changed[*]} differ from what ${judged[*]} were judged on." >&2
        echo "Move those verdicts aside (as round2/*.v2.txt), or use a new OUTDIR." >&2
        exit 2
    fi
    rm -rf -- "${OUT:?}/bundles"
    cp -r "$fresh" "$OUT/bundles"
fi

case "$STAGE" in
    A) RUNS=(1); MODEL=tiered;;
    B) RUNS=(2 3); MODEL=tiered;;
    sonnet) RUNS=(s1); MODEL=sonnet;;
    opus) RUNS=(1 2 3); MODEL=opus;;
esac

jobs_list=()
for c in "${CASES[@]}"; do for n in "${RUNS[@]}"; do
    grep -qs '^VERDICT vk26' "$OUT/$c-$n.txt" || jobs_list+=("$c $n")
done; done

export BUNDLE OUT MODEL
one() { # case n — exit 255 on failure: xargs then starts nothing more
    "$BUNDLE" judge "$OUT/bundles/$1.txt" "$OUT/$1-$2.txt" "$MODEL" && return 0
    echo "FAILED: $1-$2 (see $OUT/$1-$2.txt.failed)" >&2
    return 255
}
export -f one
stopped=0
if (( ${#jobs_list[@]} )); then
    printf '%s\n' "${jobs_list[@]}" | xargs -P "$JOBS" -L1 bash -c 'one "$@"' _ 2>&1 || stopped=1
fi

# A verdict file that is not a VERDICT block (HTTP 429, a crash) is moved
# aside, so that starting the stage again retries it, and no run is counted twice.
for f in "$OUT"/*-[0-9s]*.txt; do
    [[ -f "$f" ]] && ! grep -q '^VERDICT vk26' "$f" && { echo "not a verdict, moved aside: $f.failed" >&2; mv -f "$f" "$f.failed"; }
done

missing=0
for item in "${jobs_list[@]}"; do
    read -r c n <<< "$item"
    grep -qs '^VERDICT vk26' "$OUT/$c-$n.txt" || missing=$((missing + 1))
done
(( missing )) && echo "STOPPED: $missing of ${#jobs_list[@]} run(s) have no verdict; start the stage again (after the limit resets) to continue." >&2

# Tally each case whose runs are all there; a case still missing one is named,
# not tallied, so a stopped stage reads as unfinished rather than as wrong.
case "$STAGE" in
    A) echo "== Stage A single confirmation tally =="; TALLY=(1);;
    B|opus) echo "== Stage B consensus tally =="; TALLY=(1 2 3);;
    sonnet) echo "== Sonnet self-check tally =="; TALLY=(s1);;
esac
for c in "${CASES[@]}"; do
    files=(); have=0
    for n in "${TALLY[@]}"; do
        files+=("$OUT/$c-$n.txt")
        grep -qs '^VERDICT vk26' "$OUT/$c-$n.txt" && have=$((have + 1))
    done
    if (( have == ${#TALLY[@]} )); then
        echo "== $c"; "$BUNDLE" tally "$OUT/bundles/$c.txt" "${files[@]}" || true
    else
        echo "== $c: $have of ${#TALLY[@]} run(s), not tallied"
    fi
done

usage=("$OUT"/*.usage)
if [[ -f "${usage[0]}" ]]; then
    echo "== Usage recorded in $OUT so far (every stage, failed sessions included)"
    "$BUNDLE" usage "${usage[@]}" | grep '^TOTAL'
fi
(( missing || stopped )) && exit 2
exit 0
