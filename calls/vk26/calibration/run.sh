#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# calls/vk26/calibration — run the judge on the calibration cases, in stages,
# never more than three sessions at a time (twenty at once is what hit the
# session limit in round 2; see README.md).
#
#   run.sh A OUTDIR     stage A: one run per case, 7 runs (tiered: Opus for J2,
#                       Sonnet for J1/J3/J4; saves ~90% Opus tokens & quota)
#   run.sh B OUTDIR     stage B: two more runs per case, 14 runs; start it only
#                       once stage A was all correct. Then tallies each case.
#   run.sh sonnet OUTDIR  one run per case with Sonnet only (fast self-check)
#   run.sh opus OUTDIR    full Opus for all questions (all-Opus baseline)
#
# OUTDIR is created; the bundles go to OUTDIR/bundles, the verdicts to
# OUTDIR/<case>-<n>.txt. A run whose file already exists is skipped, so an
# interrupted stage can simply be started again.
#   VK26_JOBS=N   concurrent sessions (default 3, at most 3)

set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$HERE/../judge-bundle.sh"
STAGE="${1:-}"; OUT="${2:-}"
[[ "$STAGE" =~ ^(A|B|sonnet|opus)$ && -n "$OUT" ]] || { sed -n '3,19p' "${BASH_SOURCE[0]}"; exit 2; }
JOBS="${VK26_JOBS:-3}"; (( JOBS > 3 )) && JOBS=3

mkdir -p "$OUT/bundles"
[[ -f "$OUT/bundles/good-exp225.txt" ]] || "$HERE/cases.sh" "$OUT/bundles" >/dev/null
CASES=(good-exp225 good-exp230 good-exp234 overclaim trivial narrowed injection)

case "$STAGE" in
    A) RUNS=(1); MODEL=tiered;;
    B) RUNS=(2 3); MODEL=tiered;;
    sonnet) RUNS=(s1); MODEL=sonnet;;
    opus) RUNS=(1 2 3); MODEL=opus;;
esac

jobs_list=()
for c in "${CASES[@]}"; do for n in "${RUNS[@]}"; do
    [[ -s "$OUT/$c-$n.txt" ]] || jobs_list+=("$c $n")
done; done

export BUNDLE OUT MODEL
one() { # case n
    "$BUNDLE" judge "$OUT/bundles/$1.txt" "$OUT/$1-$2.txt" "$MODEL" || echo "FAILED: $1-$2 (see $OUT/$1-$2.txt)" >&2
}
export -f one
(( ${#jobs_list[@]} )) && printf '%s\n' "${jobs_list[@]}" | xargs -P "$JOBS" -L1 bash -c 'one "$@"' _

# A verdict file that is not a VERDICT block (HTTP 429, a crash) is removed, so
# that starting the stage again retries it, and no run is counted twice.
for f in "$OUT"/*-[0-9s]*.txt; do
    [[ -f "$f" ]] && ! grep -q '^VERDICT vk26' "$f" && { echo "not a verdict, removed: $f" >&2; mv "$f" "$f.failed"; }
done

if [[ "$STAGE" == B ]]; then
    for c in "${CASES[@]}"; do
        echo "== $c"; "$BUNDLE" tally "$OUT/bundles/$c.txt" "$OUT/$c"-[123].txt || true
    done
fi
