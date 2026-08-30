#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# duplication.sh — how much of this repository's firmware is a copy of another
# experiment's firmware, counted.
#
#   ./duplication.sh              the report, newest offenders first
#   ./duplication.sh --baseline   rewrite duplication-baseline.txt
#   ./duplication.sh --check      fail if any function got MORE copies
#
# # Why this exists
#
# Every experiment here owns its `src/main.rs`, and that was a decision, not an
# accident: one experiment, one self-contained source, readable and reproducible
# without reading anything else. It worked for about sixty experiments.
#
# What it cost is measurable, and three of its bills are written down in the
# tree already:
#
#   - exp174's USB serial said "173", carried over when its source was derived
#     from exp173. Nobody noticed until exp177 needed to tell two boards apart
#     and could not. `yi26 port` and `lib.sh`'s `exp_running` both key on that
#     string, so two firmwares were indistinguishable to every script here.
#   - exp160 lost the end of its report to `usb-log`'s sixteen-deep queue, and
#     **exp162 lost it a second time** — see exp163's `report()`.
#   - exp189 records hitting exp173's subject "for the second time in one
#     afternoon".
#
# None of those is a bug in an experiment's subject. Each is a bug in the part
# of the firmware that was never what the experiment was asking about, carried
# forward by copying, and paid for again.
#
# # What it measures
#
# Top-level function definitions in `experiments/*/src/*.rs`, grouped by name.
# For each name: how many experiments define it, and how many textually distinct
# versions exist between them. A name defined in twelve experiments with seven
# distinct bodies is seven things to fix when it turns out to be wrong, and
# nothing that will tell you the other six exist.
#
# `main` is excluded: every experiment is entitled to its own, and it is the one
# function that should differ.
#
# # What it is for
#
# A ratchet, not a rewrite. Ninety-two experiments cannot be retrofitted —
# each would cost a board run — so the existing copies are recorded in
# `duplication-baseline.txt` and grandfathered. `--check` fails only when a
# number goes UP, which is what `docs-check.sh` runs. Extract something and the
# baseline goes down; it may never go back up.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

MODE="${1:---report}"
BASELINE=duplication-baseline.txt

# Bodies shorter than this are not worth a crate: `fn be_u32(b: &[u8]) -> u32`
# is four lines and extracting it would cost more attention than it saves. The
# number is a judgement, and the report prints everything so the judgement can
# be re-made against the data rather than remembered.
MIN_LINES=12

report() {
python3 - "$MIN_LINES" <<'PY'
import re, sys, pathlib, hashlib, collections

min_lines = int(sys.argv[1])
fns = collections.defaultdict(list)
for f in sorted(pathlib.Path(".").glob("exp*/src/*.rs")):
    exp = f.parts[0][:6]
    src = f.read_text(errors="replace")
    for m in re.finditer(r'^(?:pub )?(?:async )?fn (\w+)\s*[(<]', src, re.M):
        name = m.group(1)
        if name == "main":
            continue
        end = src.find("\n}\n", m.start())
        body = src[m.start(): end if end > 0 else m.start() + 4000]
        h = hashlib.sha1(re.sub(r'\s+', ' ', body).encode()).hexdigest()[:8]
        fns[name].append((exp, h, body.count("\n") + 1))

rows = []
for name, lst in fns.items():
    exps = sorted({e for e, _, _ in lst})
    if len(exps) < 2:
        continue
    avg = sum(n for _, _, n in lst) // len(lst)
    if avg < min_lines:
        continue
    rows.append((len(exps), len({h for _, h, _ in lst}), avg, name))

# Copies first, then how badly they have diverged, then size.
rows.sort(key=lambda r: (-r[0], -r[1], -r[2]))
for exps, variants, avg, name in rows:
    print(f"{name}\t{exps}\t{variants}\t{avg}")
PY
}

case "$MODE" in
--baseline)
    report > "$BASELINE"
    echo "wrote $BASELINE ($(wc -l < "$BASELINE") duplicated functions)"
    ;;

--check)
    FAILED=0
    if [[ ! -f "$BASELINE" ]]; then
        echo "FAIL  duplication-baseline.txt exists — run ./duplication.sh --baseline"
        exit 1
    fi
    now="$(report)"
    worse=()
    new=()
    while IFS=$'\t' read -r name exps _ _; do
        [[ -n "$name" ]] || continue
        was="$(awk -F'\t' -v n="$name" '$1 == n { print $2 }' "$BASELINE")"
        if [[ -z "$was" ]]; then
            new+=("$name(x$exps)")
        elif (( exps > was )); then
            worse+=("$name($was->$exps)")
        fi
    done <<< "$now"

    if [[ ${#worse[@]} -eq 0 ]]; then
        echo "PASS  no function is copied into more experiments than the baseline records"
    else
        echo "FAIL  a function gained copies — ${worse[*]}"
        echo "      extract it into crates/ instead, or say why in the experiment's README"
        FAILED=1
    fi

    if [[ ${#new[@]} -eq 0 ]]; then
        echo "PASS  no newly duplicated function appeared"
    else
        echo "FAIL  newly duplicated — ${new[*]}"
        echo "      the second copy is the moment to extract, not the fifth"
        FAILED=1
    fi
    exit "$FAILED"
    ;;

*)
    printf '%-34s %9s %9s %9s\n' "function" "in exps" "distinct" "avg lines"
    report | while IFS=$'\t' read -r name exps variants avg; do
        printf '%-34s %9s %9s %9s\n' "$name" "$exps" "$variants" "$avg"
    done
    echo
    echo "distinct > 1 means the copies have already diverged: that many"
    echo "places to fix, and nothing that will tell you the others exist."
    ;;
esac
