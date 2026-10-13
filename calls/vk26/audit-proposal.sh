#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# calls/vk26/audit-proposal.sh — audit a proposal under spot-check mode.
#
#   audit-proposal.sh PROPOSER_DIR [OUTDIR] [AUDIT_EXP]
#
# Per ACCEPTANCE.md:
# - A proposal consists of five experiments exp101..exp105 in PROPOSER_DIR.
# - Spot-check mode: 4 experiments receive 1 judge run (single confirmation),
#   1 sampled experiment receives 3 (consensus audit): 7 runs where every
#   experiment at three would be 15, 53% fewer. A tiered run is two sessions.
# - The sampled experiment is drawn at random, so a proposer cannot know which
#   one it will be; AUDIT_EXP names it instead (a self-check, a re-audit). The
#   choice is written to OUTDIR/audit-target.txt, and a second start in the same
#   OUTDIR keeps it.
# - If the sampled experiment does not PASS, single confirmation is withdrawn:
#   the other four get runs 2 and 3 and are tallied on three.
# - The first run that fails (HTTP 429, a crash) starts nothing more; a run
#   without a VERDICT block is moved to <name>.failed and the audit stops
#   before tallying. Start it again to retry only what is missing.
# - What each session used, as claude reports it, goes to OUTDIR/*.usage and
#   is summed at the end.
#
# Environment variables:
#   MODEL: judge model (default: tiered; J2 Opus, J1/J3/J4 Sonnet)
#   JOBS: max parallel judge runs (default: 3)
#   DRY_RUN: if set to 1, generates bundles and checks gates without calling LLM.

set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUNDLE="$HERE/judge-bundle.sh"

PROPOSER_DIR="${1:-}"
[[ -n "$PROPOSER_DIR" && -d "$PROPOSER_DIR" ]] || {
    echo "Usage: $0 PROPOSER_DIR [OUTDIR] [AUDIT_EXP]" >&2
    echo "  e.g. $0 calls/vk26/alice /tmp/alice_audit exp103-foo" >&2
    exit 2
}

PROPOSER="$(basename "$PROPOSER_DIR")"
OUT="${2:-/tmp/vk26-audit-$PROPOSER}"
MODEL="${MODEL:-tiered}"
JOBS="${JOBS:-3}"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$OUT/bundles"

# Check S1: exactly five experiments exp101..exp105
EXPS=($(find "$PROPOSER_DIR" -mindepth 1 -maxdepth 1 -type d -name "exp10[1-5]-*" | sort))
if (( ${#EXPS[@]} != 5 )); then
    echo "FAIL S1: expected exactly 5 experiments exp101..exp105 in $PROPOSER_DIR, found ${#EXPS[@]}" >&2
    for e in "${EXPS[@]}"; do echo "  - $(basename "$e")" >&2; done
    exit 1
fi

# Which experiment is sampled for 3 runs: AUDIT_EXP, else the one an earlier
# start in OUTDIR drew, else one drawn now.
NAMES=("${EXPS[@]##*/}")
if [[ -n "${3:-}" ]]; then
    AUDIT_TARGET="$3"
elif [[ -s "$OUT/audit-target.txt" ]]; then
    AUDIT_TARGET="$(<"$OUT/audit-target.txt")"
else
    AUDIT_TARGET="$(printf '%s\n' "${NAMES[@]}" | shuf -n1 --random-source=/dev/urandom)"
fi
printf '%s\n' "${NAMES[@]}" | grep -qxF -- "$AUDIT_TARGET" || {
    echo "FAIL: $AUDIT_TARGET is not one of: ${NAMES[*]}" >&2; exit 2; }
echo "$AUDIT_TARGET" > "$OUT/audit-target.txt"

echo "=== vk26 Proposal Spot-Check Audit: $PROPOSER ==="
echo "Model: $MODEL"
echo "Sampled audit experiment (3 runs): $AUDIT_TARGET"
echo "Single confirmation experiments (1 run):"
for e in "${EXPS[@]}"; do
    ename="$(basename "$e")"
    [[ "$ename" == "$AUDIT_TARGET" ]] || echo "  - $ename"
done
echo ""

# Step 1: Check G1.5 gates on all 5 experiments
echo "--- Step 1: Machine Gates G1.5 ---"
gates_failed=0
for e in "${EXPS[@]}"; do
    ename="$(basename "$e")"
    echo -n "G1.5 $ename: "
    if "$BUNDLE" gates "$e"; then
        true
    else
        gates_failed=1
    fi
done
if (( gates_failed )); then
    echo "FAIL: Machine gate G1.5 failed on at least one experiment." >&2
    exit 1
fi
echo "All 5 experiments passed G1.5."
echo ""

# Step 2: Generate Slice Bundles
echo "--- Step 2: Generating Slice Bundles ---"
for e in "${EXPS[@]}"; do
    ename="$(basename "$e")"
    "$BUNDLE" bundle "$e" > "$OUT/bundles/$ename.txt"
    echo "Bundle generated: $OUT/bundles/$ename.txt ($(wc -c < "$OUT/bundles/$ename.txt") bytes)"
done
echo ""

if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN=1 set; skipping LLM judge calls."
    exit 0
fi

# Step 3: Run LLM Judge
echo "--- Step 3: Running Judge Sessions ---"
is_verdict() { [[ -f "$1" ]] && grep -q '^VERDICT vk26' "$1"; }
run_judge() {
    local exp="$1" run_num="$2"
    local vpath="$OUT/$exp-$run_num.txt"
    if is_verdict "$vpath"; then
        echo "Skipping existing verdict: $vpath"
        return 0
    fi
    echo "Judging $exp (run $run_num, model $MODEL)..."
    # 255 on failure: xargs then starts no further run, so a 429 costs one run,
    # not every run still queued behind it.
    "$BUNDLE" judge "$OUT/bundles/$exp.txt" "$vpath" "$MODEL" || return 255
}
report_usage() {
    local usage=("$OUT"/*.usage)
    [[ -f "${usage[0]}" ]] || return 0
    echo "--- Usage recorded in $OUT so far (failed sessions included) ---"
    "$BUNDLE" usage "${usage[@]}" | grep '^TOTAL'
}
export -f is_verdict run_judge
export BUNDLE OUT MODEL

# Run "exp n" items, at most JOBS at a time; the first failure starts nothing
# more. Anything that is not a verdict afterwards is moved aside, and the audit
# stops: tallying a missing run would count it as an invalid answer.
run_all() {
    (( $# )) || return 0
    printf '%s\n' "$@" | xargs -P "$JOBS" -L1 bash -c 'run_judge "$@"' _ 2>&1 || true
    local item exp n f missing=0
    for item in "$@"; do
        read -r exp n <<< "$item"
        f="$OUT/$exp-$n.txt"
        is_verdict "$f" && continue
        if [[ -f "$f" ]]; then
            mv -f "$f" "$f.failed"
            echo "not a verdict: $exp run $n (see $f.failed)" >&2
        else
            echo "no verdict written: $exp run $n" >&2
        fi
        missing=$((missing + 1))
    done
    if (( missing )); then
        echo "STOPPED: $missing run(s) gave no verdict; start the audit again to retry them." >&2
        report_usage
        exit 2
    fi
}

others=()
for e in "${NAMES[@]}"; do [[ "$e" == "$AUDIT_TARGET" ]] || others+=("$e"); done
first=("$AUDIT_TARGET 1" "$AUDIT_TARGET 2" "$AUDIT_TARGET 3")
for e in "${others[@]}"; do first+=("$e 1"); done
run_all "${first[@]}"
echo "Judge runs complete."
echo ""

# Step 4: Tally and Report
echo "--- Step 4: Tallying Results ---"
audit_failed=0
tally() { # exp run...
    local exp="$1"; shift
    local files=() n
    for n in "$@"; do files+=("$OUT/$exp-$n.txt"); done
    echo "=================================================="
    echo "Experiment: $exp"
    echo "Mode: $( (( $# == 1 )) && echo "Single Confirmation" || echo "$#-run Consensus Audit")"
    "$BUNDLE" tally "$OUT/bundles/$exp.txt" "${files[@]}" || { audit_failed=1; return 1; }
}

if tally "$AUDIT_TARGET" 1 2 3; then
    for e in "${others[@]}"; do tally "$e" 1 || true; done
else
    echo "=================================================="
    echo "ESCALATED: the sampled experiment $AUDIT_TARGET did not PASS, so single"
    echo "confirmation is withdrawn; the other four get runs 2 and 3."
    more=()
    for e in "${others[@]}"; do more+=("$e 2" "$e 3"); done
    run_all "${more[@]}"
    for e in "${others[@]}"; do tally "$e" 1 2 3 || true; done
fi

echo "=================================================="
report_usage
if (( audit_failed )); then
    echo "PROPOSAL AUDIT RESULT: FAIL or HUMAN INTERVENTION NEEDED" >&2
    exit 1
else
    echo "PROPOSAL AUDIT RESULT: ALL 5 EXPERIMENTS PASSED"
    exit 0
fi
