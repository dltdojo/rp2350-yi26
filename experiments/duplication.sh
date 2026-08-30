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
# Top-level function definitions, grouped by name, in **three languages**:
#
#   rs   experiments/*/src/*.rs      the firmware
#   py   experiments/*/*.py          the drivers and the verifiers
#   sh   experiments/*/*.sh          the run, drop and check scripts
#
# For each name: how many experiments define it, and how many textually distinct
# versions exist between them. A name defined in twelve experiments with seven
# distinct bodies is seven things to fix when it turns out to be wrong, and
# nothing that will tell you the other six exist.
#
# **The host side was invisible until exp194.** This script read only Rust for
# its first day, and exp194 went looking for a CTAP-HID client and found seven
# copies of one -- 238 to 689 lines, six textually different -- that nothing
# here could see. Names are prefixed with their language, so a Rust `feed` and
# a Python `feed` are two rows rather than one.
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

# Bodies shorter than this are not worth extracting: `fn be_u32(b: &[u8]) -> u32`
# is four lines and moving it would cost more attention than it saves.
#
# It was 12 while this read only Rust. Shell functions are short by nature --
# `flash()` is eight lines and is copied into five experiments -- so a threshold
# tuned to Rust hid the whole of the shell side. The number is a judgement, and
# the report prints everything so it can be re-made against the data rather than
# remembered.
MIN_LINES=8

report() {
python3 - "$MIN_LINES" <<'PYEOF'
import re, sys, pathlib, hashlib, collections

min_lines = int(sys.argv[1])

# One entry per language: where to look, and what a definition looks like.
#
# `main` is excluded in Rust because every experiment is entitled to its own and
# it is the one function that should differ. Nothing is excluded in the other
# two: a `main` in a driver script is not that.
LANGS = [
    ("rs", "exp*/src/*.rs", re.compile(r'^(?:pub )?(?:async )?fn (\w+)\s*[(<]', re.M), {"main"}),
    ("py", "exp*/*.py", re.compile(r'^(?:async )?def (\w+)\s*\(', re.M), set()),
    ("sh", "exp*/*.sh", re.compile(r'^(?:function\s+)?(\w+)\s*\(\)\s*\{', re.M), set()),
]


def body_of(lang, src, start):
    """Where a definition ends.

    Python ends at the next line starting in column zero. Rust closes on a `}`
    in column zero. Shell needs brace counting, because a one-line helper --
    `say() { echo "$1"; }` -- has no `}` in column zero at all, and looking for
    one ran every such function to the next closing brace in the file. That
    made `sh:say` read as 56 lines when it is one, which is the kind of wrong
    number that discredits the whole table.
    """
    if lang == "py":
        m = re.compile(r'^(?=\S)', re.M).search(src, start + 1)
        return src[start:m.start() if m else len(src)]
    if lang == "rs":
        end = src.find("\n}\n", start)
        return src[start: end if end > 0 else start + 4000]

    # Shell: count braces from the opening one. `${VAR}` and `case` blocks
    # balance out, and a stray brace inside a comment or a string is rare
    # enough that the alternative -- a shell parser -- costs more than it
    # settles.
    depth, i = 0, start
    while i < len(src):
        c = src[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[start:i + 1]
        i += 1
    return src[start:]


fns = collections.defaultdict(list)
for lang, glob, pattern, skip in LANGS:
    for f in sorted(pathlib.Path(".").glob(glob)):
        exp = f.parts[0][:6]
        src = f.read_text(errors="replace")
        for m in pattern.finditer(src):
            name = m.group(1)
            if name in skip:
                continue
            body = body_of(lang, src, m.start())
            h = hashlib.sha1(re.sub(r'\s+', ' ', body).encode()).hexdigest()[:8]
            fns[f"{lang}:{name}"].append((exp, h, body.count("\n") + 1))

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
PYEOF
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
        echo "      rs: extract into crates/    py, sh: into tools/"
        echo "      or say why in the experiment's README"
        FAILED=1
    fi

    if [[ ${#new[@]} -eq 0 ]]; then
        echo "PASS  no newly duplicated function appeared"
    else
        echo "FAIL  newly duplicated — ${new[*]}"
        echo "      the second copy is the moment to extract, not the fifth"
        echo "      rs: extract into crates/    py, sh: into tools/"
        FAILED=1
    fi
    exit "$FAILED"
    ;;

*)
    printf '%-34s %9s %9s %9s\n' "lang:function" "in exps" "distinct" "avg lines"
    report | while IFS=$'\t' read -r name exps variants avg; do
        printf '%-34s %9s %9s %9s\n' "$name" "$exps" "$variants" "$avg"
    done
    echo
    echo "distinct > 1 means the copies have already diverged: that many"
    echo "places to fix, and nothing that will tell you the others exist."
    ;;
esac
