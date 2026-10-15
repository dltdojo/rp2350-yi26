#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# calls/vk26/audit-proposal.sh — audit a proposal under spot-check mode.
#
#   audit-proposal.sh PROPOSER_DIR [OUTDIR] [AUDIT_EXP]
#
# Per ACCEPTANCE.md:
# - A proposal consists of five experiments in PROPOSER_DIR, one directory
#   each, vk26-<proposer>-1-<slug> to vk26-<proposer>-5-<slug>: the
#   experiment's id, vk26-<proposer>-<n>, then a slug (README.md section 3).
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
#   MODEL: judge model (default: tiered; J2 to the deep model, J1/J3/J4 to
#          the fast model, as models.env names them; or fast, or deep)
#   JOBS: max parallel judge runs (default: 3)
#   DRY_RUN: if set to 1, generates bundles and checks gates without calling LLM.
#   MACHINE: 1 (default) runs the machine layer first, gates.sh: S1–S4 for the
#            proposal (S2 against BASE, when set), then G1.5, G2, G6 and each
#            check.sh (G1, G3, G4, G5) for every experiment, about five minutes
#            each. Anything that fails stops the audit before a judge is asked:
#            the judge cannot overrule a gate, so it is not paid to try. Its
#            output is OUT/gates/, and a fresh check.sh run is the bundle's
#            GATES. A start with the same inputs (the trees of the proposal,
#            lean/, tools/, experiments/ and the call's two scripts) reuses what
#            passed. 0: G1.5 only.
#   BASE:    the PR's base for S2, e.g. origin/main

set -eu
# All of it is read before any of it runs: bash reads a script as it goes, and
# vk26-alice's audit died (exit 127) when this file was edited mid-run.
{
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUNDLE="$HERE/judge-bundle.sh"

PROPOSER_DIR="${1:-}"
[[ -n "$PROPOSER_DIR" && -d "$PROPOSER_DIR" ]] || {
    echo "Usage: $0 PROPOSER_DIR [OUTDIR] [AUDIT_EXP]" >&2
    echo "  e.g. $0 calls/vk26/alice /tmp/alice_audit vk26-alice-3-foo" >&2
    exit 2
}

PROPOSER="$(basename "$PROPOSER_DIR")"
OUT="${2:-/tmp/vk26-audit-$PROPOSER}"
MODEL="${MODEL:-tiered}"
JOBS="${JOBS:-3}"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$OUT/bundles"

# Check S1: exactly five experiments, vk26-<proposer>-1-<slug> to -5-<slug>,
# one of each number, every id short enough to be the USB serial (34
# characters, tools/hazard3/shell/usbdev.c's STRING_MAX).
ID="vk26-$PROPOSER"
EXPS=($(find "$PROPOSER_DIR" -mindepth 1 -maxdepth 1 -type d -name "$ID-[1-5]-*" | sort))
nums="$(for e in "${EXPS[@]}"; do b="${e##*/}"; echo "${b:${#ID}+1:1}"; done | sort -u | tr -d '\n')"
if (( ${#EXPS[@]} != 5 )) || [[ "$nums" != 12345 ]]; then
    echo "FAIL S1: expected exactly 5 experiments $ID-1-<slug> to $ID-5-<slug> in $PROPOSER_DIR, one of each, found ${#EXPS[@]}" >&2
    for e in "${EXPS[@]}"; do echo "  - $(basename "$e")" >&2; done
    exit 1
fi
if (( ${#ID} + 2 > 34 )); then
    echo "FAIL S1: the id $ID-<n> is $(( ${#ID} + 2 )) characters, and a USB serial holds 34; the call assigns a shorter name" >&2
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

# Step 1: the machine layer. With MACHINE=0, G1.5 alone.
gates_failed=0
if [[ "${MACHINE:-1}" == 0 ]]; then
    echo "--- Step 1: Machine Gates G1.5 (MACHINE=0: the rest of the machine layer not run) ---"
    for e in "${EXPS[@]}"; do
        ename="$(basename "$e")"
        echo -n "G1.5 $ename: "
        "$BUNDLE" gates "$e" || gates_failed=1
    done
else
    echo "--- Step 1: Machine Gates (gates.sh) ---"
    mkdir -p "$OUT/gates"
    # What the gates read, as git's tree hashes: the proposal, lean/, tools/,
    # experiments/ (lib.sh, duplication.sh), and the call's own two scripts.
    # A commit elsewhere — a fix to this script — leaves them, and the five
    # check.sh runs, as they were; a change to any of them, or an uncommitted
    # one, does not.
    head="never-$(date +%s)"   # outside a repository, nothing is reused
    if top="$(git -C "$PROPOSER_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
        rel="$(realpath --relative-to="$top" "$PROPOSER_DIR")"
        trees="$(git -C "$top" rev-parse "HEAD:$rel" HEAD:lean HEAD:tools HEAD:experiments \
            HEAD:calls/vk26/gates.sh HEAD:calls/vk26/judge-bundle.sh 2>/dev/null)" \
            && [[ -z "$(git -C "$top" status --porcelain -- "$rel" lean tools experiments calls/vk26/gates.sh calls/vk26/judge-bundle.sh)" ]] \
            && head="$(sha256sum <<< "$trees" | cut -c1-16)"
    fi
    "$HERE/gates.sh" proposal "$PROPOSER_DIR" "${BASE-}" | tee "$OUT/gates/proposal.txt"
    (( PIPESTATUS[0] )) && gates_failed=1
    for e in "${EXPS[@]}"; do
        ename="$(basename "$e")"
        g="$OUT/gates/$ename.txt"
        if [[ -f "$g" ]] && grep -qxF "head $head" "$g" && grep -qx "gates exit 0" "$g"; then
            echo "$ename: passed already on these inputs ($g)"
            continue
        fi
        echo "$ename:"
        { echo "head $head"; "$HERE/gates.sh" experiment "$e" "$OUT/gates/$ename.check.txt"; echo "gates exit $?"; } > "$g" 2>&1
        grep -E '^(PASS|FAIL|SKIP) ' "$g" | sed 's/^/  /'
        grep -qx "gates exit 0" "$g" || gates_failed=1
    done
fi
if (( gates_failed )); then
    echo "FAIL: a machine gate failed; no judge is asked (ACCEPTANCE.md: a layer that fails ends the audit)." >&2
    exit 1
fi
echo "Every machine gate passed."
echo ""

# Step 2: Generate Slice Bundles
echo "--- Step 2: Generating Slice Bundles ---"
# A verdict answers the bundle it was given. A bundle that changed since (a
# README fixed, judge-bundle.sh changed) sets its experiment's verdicts aside
# as .stale-<time>, and those runs are judged again; the commit line alone is
# not a change. calibration/run.sh refuses in the same case; an audit started
# again after a fix is the ordinary case here, so it goes on.
same_bundle() { cmp -s <(grep -v '^commit: ' "$1") <(grep -v '^commit: ' "$2"); }
for e in "${EXPS[@]}"; do
    ename="$(basename "$e")"
    fresh="$OUT/gates/$ename.check.txt"
    b="$OUT/bundles/$ename.txt"
    if [[ -f "$fresh" ]]; then
        "$BUNDLE" bundle "$e" "$fresh" > "$b.new"
    else
        "$BUNDLE" bundle "$e" > "$b.new"
    fi
    if [[ -f "$b" ]] && ! same_bundle "$b" "$b.new"; then
        stamp="$(date +%s)"
        for v in "$OUT/$ename"-[0-9].txt; do
            [[ -f "$v" ]] && mv -f "$v" "$v.stale-$stamp" && echo "bundle changed: $(basename "$v") set aside as .stale-$stamp"
        done
    fi
    mv -f "$b.new" "$b"
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
    # After a failure no run starts, so a 429 costs one run, not every run
    # still queued behind it. A flag, not xargs's 255: on 255 xargs exits at
    # once, and a run already started went on, wrote its file after the check
    # below and was named "no verdict written" (vk26-alice's audit, a session
    # limit on its first sessions).
    [[ -e "$OUT/.stop" ]] && return 0
    echo "Judging $exp (run $run_num, model $MODEL)..."
    "$BUNDLE" judge "$OUT/bundles/$exp.txt" "$vpath" "$MODEL" || { touch "$OUT/.stop"; return 1; }
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
    rm -f -- "$OUT/.stop"
    printf '%s\n' "$@" | xargs -P "$JOBS" -L1 bash -c 'run_judge "$@"' _ 2>&1 || true
    rm -f -- "$OUT/.stop"
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
exit
}
