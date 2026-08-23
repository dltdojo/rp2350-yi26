#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# docs-check.sh — the guard for facts that belong to no single experiment.
#
# `presence_check` and `usb_check` in lib.sh already keep each experiment's own
# declarations honest, and they work: every experiment here declares its
# presence level and its four USB tokens, and none of those has drifted.
#
# What drifted instead was every number that is a **sum over experiments** —
# the count in the top-level README, the presence distribution table, the
# counts that used to sit in lib.sh's own comments. None of them belongs to an
# experiment, so no experiment's check.sh was ever going to notice.
#
# Two reasons those escaped, and this script closes both:
#
#   1. Nothing computed them. A per-row guard compares one row to one
#      declaration; an aggregate needs somebody to count.
#   2. Nothing ran repo-wide. `presence_check` fires only inside the experiment
#      being run, so adding exp154 does not make exp103's check.sh run, and the
#      distribution table could sit stale for six experiments without a single
#      failing check anywhere.
#
# So this runs over the whole tree at once, and needs **no board and no
# toolchain** — presence level 0, deliberately, so there is no excuse not to
# run it and CI can run it on every push.
#
#   ./docs-check.sh        exit 0 = the documents agree with the tree

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ./lib.sh

INDEX=README.md
ROOT_README=../README.md

# ---------------------------------------------------------------------------
# The tree is the truth. Everything below is compared against these.

mapfile -t DIRS < <(find . -maxdepth 1 -type d -name 'exp[0-9][0-9][0-9]-*' -printf '%f\n' | sort)
COUNT=${#DIRS[@]}

# `expNNN` prefixes, for the tables that key on the number alone.
mapfile -t SHORTS < <(printf '%s\n' "${DIRS[@]}" | cut -c1-6)

# ---------------------------------------------------------------------------
# 1. Every experiment directory has a row in the index, and every row has a
#    directory. The second direction is the one a rename or a deletion breaks:
#    a row pointing at a directory nobody has, which reads as a working link
#    until somebody clicks it.

missing_row=()
for d in "${DIRS[@]}"; do
    grep -qF "[$d](./$d/)" "$INDEX" || missing_row+=("$d")
done
if [[ ${#missing_row[@]} -eq 0 ]]; then
    pass "every experiment directory has an index row ($COUNT)"
else
    fail "every experiment directory has an index row" "missing: ${missing_row[*]}"
fi

orphan_row=()
while read -r linked; do
    [[ -d "$linked" ]] || orphan_row+=("$linked")
done < <(grep -oP '^\| \[\Kexp[0-9]{3}-[^\]]+' "$INDEX" | sort -u)
if [[ ${#orphan_row[@]} -eq 0 ]]; then
    pass "every index row has a directory"
else
    fail "every index row has a directory" "no such directory: ${orphan_row[*]}"
fi

# ---------------------------------------------------------------------------
# 2. Every experiment has the two scripts the conventions promise. A README
#    that says "every experiment directory contains the same two scripts" is a
#    claim, and this is the only thing that checks it.

no_check=(); no_run=(); no_readme=()
for d in "${DIRS[@]}"; do
    [[ -f "$d/check.sh"  ]] || no_check+=("$d")
    [[ -f "$d/run.sh"    ]] || no_run+=("${d:0:6}")
    [[ -f "$d/README.md" ]] || no_readme+=("$d")
done

if [[ ${#no_check[@]} -eq 0 ]]; then
    pass "every experiment has check.sh ($COUNT)"
else
    fail "every experiment has check.sh" "missing: ${no_check[*]}"
fi

if [[ ${#no_readme[@]} -eq 0 ]]; then
    pass "every experiment has a README ($COUNT)"
else
    fail "every experiment has a README" "missing: ${no_readme[*]}"
fi

# run.sh is reported, not required. The Conventions section used to promise
# both scripts in every directory; the newest experiments ship the verdict
# first and the walkthrough later, so the promise was the thing that was
# wrong. Printing the list keeps that visible without turning a known,
# deliberate gap into a failure everybody learns to ignore — which is how a
# red check stops meaning anything.
if [[ ${#no_run[@]} -gt 0 ]]; then
    say "no run.sh yet (${#no_run[@]}): ${no_run[*]}"
fi

# ---------------------------------------------------------------------------
# 3. Every check.sh's declared PRESENCE agrees with its index row — the same
#    comparison `presence_check` makes, but for all of them at once and without
#    running a single experiment. That is the whole point: the per-experiment
#    guard is correct and almost never fires, because almost nobody runs
#    fifty-odd check.sh files after editing a table.

declare -A LEVEL_OF
presence_bad=()
for d in "${DIRS[@]}"; do
    declared="$(grep -m1 -oP '^PRESENCE=\K[0-3]' "$d/check.sh" 2>/dev/null || true)"
    if [[ -z "$declared" ]]; then
        presence_bad+=("$d: declares no PRESENCE")
        continue
    fi
    LEVEL_OF["${d:0:6}"]="$declared"
    row="$(grep -m1 -F "[$d](./$d/)" "$INDEX")"
    [[ "$row" == *"| $declared · "* ]] || presence_bad+=("$d: check.sh says $declared, index says otherwise")
done
if [[ ${#presence_bad[@]} -eq 0 ]]; then
    pass "every check.sh's PRESENCE matches its index row ($COUNT)"
else
    fail "every check.sh's PRESENCE matches its index row" "${presence_bad[*]}"
fi

# ---------------------------------------------------------------------------
# 4. The presence distribution table. This is the one that was wrong: it
#    stopped at exp147 while six later experiments sat in the index at level 3.
#
#    The cells are written for a reader — `exp107–exp114` rather than eight
#    entries — so the ranges are expanded before the sets are compared. The
#    dash is an en-dash (U+2013), which is what the table actually uses; a
#    hyphen is accepted too, so fixing the typography does not break the guard.

expand_cell() {
    # stdin: a table cell such as "exp102, exp140" or "exp107–exp114, exp118"
    # stdout: one expNNN per line
    local item lo hi n
    # `read` returns non-zero on a final line with no newline, and a table
    # cell has no trailing newline — without the `|| [[ -n ]]` the loop drops
    # the last experiment out of every cell, which reads as a real drift.
    # The dash is matched by alternation rather than a bracket: the table uses
    # an en-dash (U+2013), and a multibyte character inside a bracket
    # expression is not something bash's regex can be trusted with.
    tr ',' '\n' | tr -d ' ' | while read -r item || [[ -n "$item" ]]; do
        [[ -n "$item" ]] || continue
        if [[ "$item" =~ ^exp([0-9]{3})(–|-)exp([0-9]{3})$ ]]; then
            lo=${BASH_REMATCH[1]}; hi=${BASH_REMATCH[3]}
            for ((n = 10#$lo; n <= 10#$hi; n++)); do printf 'exp%03d\n' "$n"; done
        elif [[ "$item" =~ ^exp[0-9]{3}$ ]]; then
            echo "$item"
        else
            echo "UNPARSEABLE:$item"
        fi
    done
}

dist_bad=()
for level in 0 1 2 3; do
    # The distribution row starts `| **N · `; the index rows never do.
    cell="$(grep -m1 -oP "^\| \*\*$level · [^|]*\| [^|]*\| \K[^|]*" "$INDEX" | sed 's/ *$//')"
    if [[ -z "$cell" ]]; then
        dist_bad+=("level $level: no row in the distribution table")
        continue
    fi

    claimed="$(printf '%s' "$cell" | expand_cell | sort -u)"
    actual="$(for s in "${SHORTS[@]}"; do
                  [[ "${LEVEL_OF[$s]-}" == "$level" ]] && echo "$s"
              done | sort -u)"

    if [[ "$claimed" != "$actual" ]]; then
        # Name the difference in both directions — "these disagree" sends the
        # reader back to diffing two lists by eye, which is the job.
        only_claimed="$(comm -23 <(echo "$claimed") <(echo "$actual") | tr '\n' ' ')"
        only_actual="$(comm -13 <(echo "$claimed") <(echo "$actual") | tr '\n' ' ')"
        [[ -n "${only_claimed// /}" ]] && dist_bad+=("level $level: table lists but tree disagrees: $only_claimed")
        [[ -n "${only_actual// /}" ]] && dist_bad+=("level $level: tree has but table omits: $only_actual")
    fi
done
if [[ ${#dist_bad[@]} -eq 0 ]]; then
    pass "the presence distribution table matches the index"
else
    fail "the presence distribution table matches the index" "${dist_bad[*]}"
fi

# ---------------------------------------------------------------------------
# 5. Every check.sh's four USB tokens agree with the USB channel table — the
#    comparison `usb_check` makes, again for all of them at once. Same gap as
#    check 3: the per-experiment guard is correct and only fires for the one
#    experiment somebody happens to be running.
#
#    `usb_check` also compares USB_IFACE against src/main.rs, which is the half
#    that cannot rot. That part is deliberately left where it is: it needs the
#    firmware source, and this script's whole value is that it needs nothing.

usb_bad=()
for d in "${DIRS[@]}"; do
    short="${d:0:6}"
    row="$(grep -m1 "^| $short | \`" "$INDEX")"
    if [[ -z "$row" ]]; then
        usb_bad+=("$short: no row in the USB channel table")
        continue
    fi
    for f in USB_IFACE USB_CARRIES USB_HOST USB_RUNS_ON; do
        declared="$(grep -m1 -oP "^$f=\"?\K[^\"]*" "$d/check.sh" 2>/dev/null || true)"
        if [[ -z "$declared" ]]; then
            usb_bad+=("$short: declares no $f")
        elif [[ "$row" != *"\`$declared\`"* ]]; then
            usb_bad+=("$short: check.sh says $f=$declared, the table says otherwise")
        fi
    done
done
if [[ ${#usb_bad[@]} -eq 0 ]]; then
    pass "every check.sh's USB tokens match the USB channel table ($COUNT)"
else
    fail "every check.sh's USB tokens match the USB channel table" "${usb_bad[*]}"
fi

# ---------------------------------------------------------------------------
# 6. pack.sh's content hash must not depend on the machine it runs on.
#
#    This one is here because it already happened. `content_hash` piped its
#    file list through a bare `sort`, which orders by the locale's collation
#    rules — so twenty-four verification records written on a machine with a
#    locale read as STALE on a machine without one, with not a byte of their
#    content changed. A record whose whole purpose is to say "this has moved"
#    said it about everything, which is the same as saying nothing.
#
#    The invariant is small enough to check by reading: the sort that decides
#    the order of the hashed list runs under a pinned collation. Anything that
#    reintroduces a locale-sensitive sort there fails here rather than a month
#    later on somebody else's machine.

if grep -q 'LC_ALL=C sort -z' pack.sh; then
    pass "pack.sh's content hash sorts under a pinned collation"
else
    fail "pack.sh's content hash sorts under a pinned collation" \
         "a bare sort orders by locale, and every verification record written elsewhere goes stale"
fi

# ---------------------------------------------------------------------------
# 7. No document is mostly copies of itself.
#
#    platforms.md was committed at 52 MB and 1,063,326 lines, of which 110 were
#    distinct: one 29-line section repeated 35,425 times, each copy with a
#    different character stuck to the front of its heading. It did not append —
#    it replaced, so the 470 lines of document that had been there were gone,
#    and stayed gone for a fortnight in a repository that reads its own prose
#    carefully. Nothing noticed, because nothing was looking at whole files.
#
#    A runaway writer is not a subtle failure and does not need a subtle test.
#    The most-repeated line in every hand-written document here is a table rule
#    at thirteen, so a line appearing fifty times is not prose. Checking the
#    ratio rather than the size is what catches the version of this that is
#    only a few hundred kilobytes and looks perfectly ordinary in a listing.

REPEAT_LIMIT=50
repeated=()
while IFS= read -r doc; do
    worst="$(grep -v '^[[:space:]]*$' "$doc" 2>/dev/null | sort | uniq -c | sort -rn | head -1)"
    count="$(awk '{print $1}' <<< "$worst")"
    [[ -n "$count" ]] || continue
    if (( count > REPEAT_LIMIT )); then
        repeated+=("${doc#../}: a line appears $count times")
    fi
done < <(find .. -name '*.md' -not -path '*/target/*' -not -path '*/.git/*' 2>/dev/null | sort)

if [[ ${#repeated[@]} -eq 0 ]]; then
    pass "no document is mostly copies of itself"
else
    fail "no document is mostly copies of itself" "${repeated[*]}"
fi

# ---------------------------------------------------------------------------
# 8. Every firmware's USB serial number is its own experiment number, and no
#    two firmwares share one.
#
#    This is how the board answers "which experiment are you". `yi26 port
#    --json` reports it and `lib.sh`'s `exp_running` compares against it, so
#    forty-six check.sh scripts decide whether to run or to SKIP on this one
#    string — and it is typed by hand, once, in each firmware's `src/main.rs`.
#
#    It had already drifted. exp174 was derived from exp173's source and
#    carried its serial with it, so both reported "173" and no script here
#    could tell the two apart; exp174's own check.sh does not use `exp_running`
#    at all, which is how that survived. Found while asking a different
#    question in exp177, not by anything that was looking.
#
#    exp103 has no USB at all and therefore no serial, which is why the check
#    is over the firmwares that declare one rather than over every directory.

serial_wrong=()
declare -A serial_seen=()
serial_count=0
for d in "${DIRS[@]}"; do
    src="$d/src/main.rs"
    [[ -f "$src" ]] || continue
    line="$(grep -m1 'config.serial_number' "$src" 2>/dev/null)" || continue
    [[ -n "$line" ]] || continue
    serial="$(sed -n 's/.*Some("\([^"]*\)").*/\1/p' <<< "$line")"
    want="${d:3:3}"
    serial_count=$((serial_count + 1))
    if [[ "$serial" != "$want" ]]; then
        serial_wrong+=("$d says \"$serial\", not \"$want\"")
    fi
    if [[ -n "${serial_seen[$serial]-}" ]]; then
        serial_wrong+=("$d and ${serial_seen[$serial]} both say \"$serial\"")
    fi
    serial_seen[$serial]="$d"
done

if [[ ${#serial_wrong[@]} -eq 0 ]]; then
    pass "every firmware's USB serial is its own experiment number ($serial_count)"
else
    fail "every firmware's USB serial is its own experiment number" "${serial_wrong[*]}"
fi

# ---------------------------------------------------------------------------
# What this deliberately does not do: rewrite anything. A generator that
# silently fixes a table means nobody ever learns the document was wrong, and
# the prose *around* a generated block can still contradict it. `pack.sh`
# refuses on a non-zero exit for the same reason — the output is evidence, not
# a hope.

exit "$FAILED"
