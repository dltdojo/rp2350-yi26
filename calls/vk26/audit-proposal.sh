#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# calls/vk26/audit-proposal.sh — audit a proposal under spot-check mode.
#
#   audit-proposal.sh PROPOSER_DIR [OUTDIR] [AUDIT_EXP]
#
# Per ACCEPTANCE.md:
# - A proposal consists of five experiments exp101..exp105 in PROPOSER_DIR.
# - Spot-check mode: 4 experiments receive 1 judge session (single confirmation).
#   1 sampled experiment receives 3 judge sessions (consensus audit).
# - Reduces judge sessions from 15 to 7 (~60% reduction).
#
# Environment variables:
#   MODEL: judge model (default: tiered; J2 Opus, J1/J3/J4 Sonnet)
#   JOBS: max parallel sessions (default: 3)
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

# Determine which experiment is sampled for 3 runs (default: exp103 or 3rd experiment)
AUDIT_TARGET="${3:-$(basename "${EXPS[2]}")}"
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
run_judge() {
    local exp="$1"
    local run_num="$2"
    local bpath="$OUT/bundles/$exp.txt"
    local vpath="$OUT/$exp-$run_num.txt"
    if [[ -f "$vpath" && -s "$vpath" ]]; then
        echo "Skipping existing verdict: $vpath"
        return 0
    fi
    echo "Judging $exp (run $run_num, model $MODEL)..."
    "$BUNDLE" judge "$bpath" "$vpath" "$MODEL"
}

# Queue runs: 3 for sampled experiment, 1 for the other 4 experiments
runs_list=()
for e in "${EXPS[@]}"; do
    ename="$(basename "$e")"
    if [[ "$ename" == "$AUDIT_TARGET" ]]; then
        runs_list+=("$ename 1" "$ename 2" "$ename 3")
    else
        runs_list+=("$ename 1")
    fi
done

export -f run_judge
export BUNDLE OUT MODEL
printf '%s\n' "${runs_list[@]}" | xargs -P "$JOBS" -L1 bash -c 'run_judge "$@"' _
echo "Judge runs complete."
echo ""

# Step 4: Tally and Report
echo "--- Step 4: Tallying Results ---"
audit_failed=0
for e in "${EXPS[@]}"; do
    ename="$(basename "$e")"
    echo "=================================================="
    echo "Experiment: $ename"
    bpath="$OUT/bundles/$ename.txt"
    if [[ "$ename" == "$AUDIT_TARGET" ]]; then
        echo "Mode: 3-run Consensus Audit"
        if ! "$BUNDLE" tally "$bpath" "$OUT/$ename-1.txt" "$OUT/$ename-2.txt" "$OUT/$ename-3.txt"; then
            audit_failed=1
        fi
    else
        echo "Mode: Single Confirmation"
        if ! "$BUNDLE" tally "$bpath" "$OUT/$ename-1.txt"; then
            audit_failed=1
        fi
    fi
done

echo "=================================================="
if (( audit_failed )); then
    echo "PROPOSAL AUDIT RESULT: FAIL or HUMAN INTERVENTION NEEDED" >&2
    exit 1
else
    echo "PROPOSAL AUDIT RESULT: ALL 5 EXPERIMENTS PASSED"
    exit 0
fi
