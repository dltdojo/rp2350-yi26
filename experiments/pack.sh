#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# pack.sh — put one experiment in a .zip somebody else can flash from.
#
#   ./pack.sh                     # pack every experiment
#   ./pack.sh exp152              # pack one, by prefix or full name
#   ./pack.sh exp151 exp152       # or several
#
# The recipient gets a firmware image, the pages that flash it, the
# experiment's own README, and the evidence that it built. They do NOT get a
# buildable source tree, and that is deliberate: an experiment directory has
# `path = "../../crates/..."` dependencies and sources `../lib.sh`, so a
# copied-out directory cannot build or check itself. Anybody who wants the
# source wants `git clone`, which is strictly better than any zip of it.
#
# NOTHING IS PACKED UNVERIFIED. Every zip is built by running the experiment's
# own `check.sh` and refusing on a non-zero exit, and that run's output goes
# into the zip as CHECK.txt. `check.sh` needs no board — the board half of one
# reports SKIP and still exits 0 — so this is a packaging machine, not a
# verification session.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ./lib.sh
require_supported_platform

REPO_ROOT="$(cd .. && pwd)"
OUT_DIR="$REPO_ROOT/dist"
PAGES_DIR="$REPO_ROOT/tools/pages"
PACKED=0
REFUSED=0

for tool in zip sha256sum; do
    command -v "$tool" > /dev/null || { echo "${RED}pack.sh needs $tool${RESET}"; exit 1; }
done

# ---------------------------------------------------------------------------
# Facts, each read from the one place that already cannot drift.

# The index row in README.md. `presence_check` in lib.sh fails the experiment's
# own check.sh if the Needs level here ever disagrees with the one declared
# beside the code, so this table is guarded rather than merely maintained.
#
# A row is `| [slug](./slug/) | 3 · a person | what it proves |`, so splitting
# on " | " puts the link in 1, Needs in 2 and Proves in 3 — and leaves the
# closing bar stuck to the last field, which has to come off.
index_row() { grep -m1 "^| \[$1\](" README.md; }
index_field() {
    index_row "$1" | awk -F' \\| ' -v n="$2" '{print $n}' | sed 's/ *|$//'
}

# The USB declarations and the presence level live as literal assignments at
# the top of every check.sh, and `usb_check` holds them against the table in
# README.md. Read them there: it is the copy nearest the code.
declared() { sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$1/check.sh" | head -1; }

# The standalone walkthrough. It lives in the experiment's README under an
# exact heading and is lifted from there rather than written twice: a second
# copy of a procedure is a copy that goes stale the first time somebody fixes
# only the one they were looking at. Fences come off, indentation stays — what
# is left is meant to be pasted into a terminal.
#
# An experiment without the heading gets told so, in the zip, in as many words.
# A missing walkthrough is a gap somebody can close; a silently absent one is a
# recipient staring at a firmware image wondering what to do with it.
STEPS_HEADING='## Do this, in order'
steps_section() {
    [[ -f "$1/README.md" ]] || return 1
    awk -v h="$STEPS_HEADING" '
        $0 == h { on = 1; next }
        on && /^## / { exit }
        on && !/^```/ { print }
    ' "$1/README.md" \
        | sed -e 's/\[\([^][]*\)\](\([^()]*\))/\1/g' -e 's/[[:space:]]*$//' \
        | cat -s
}

# ---------------------------------------------------------------------------
# Pack verification, and why it is a hash and not a date.
#
# A walkthrough is verified by somebody unzipping it and doing what it says,
# which is expensive and which an experiment only earns once: these are frozen
# after they are made. So the record is bound to the CONTENT rather than to a
# promise — everything that decides the procedure or the firmware goes into one
# hash, and the moment any of it moves the record says so instead of aging
# quietly into a lie.
#
# `target/` is excluded: a rebuilt .uf2 differs across checkout paths (measured)
# and is not a change to the experiment. PACKED.md excludes itself, or writing
# the record would invalidate it.
content_hash() {
    find "$1" -type f \
        \( -name '*.rs' -o -name '*.toml' -o -name '*.lock' -o -name '*.html' \
           -o -name '*.sh' -o -name 'README.md' \) \
        -not -path '*/target/*' -print0 2>/dev/null \
        | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -c1-16
}

# One of: unverified | ok | stale
pack_status() {
    local dir="$1" rec="$1/PACKED.md" recorded
    [[ -f "$rec" ]] || { echo "unverified"; return; }
    recorded="$(sed -n 's/^hash: *//p' "$rec" | head -1)"
    [[ "$recorded" == "$(content_hash "$dir")" ]] && echo ok || echo stale
}

pack_status_line() {
    local dir="$1" rec="$1/PACKED.md" when
    when="$(sed -n 's/^verified: *//p' "$rec" 2>/dev/null | head -1)"
    case "$(pack_status "$dir")" in
        ok)         echo "${GREEN}pack-verified $when${RESET} — content unchanged, nothing to redo" ;;
        stale)      echo "${YELLOW}pack-verified $when, but the experiment has CHANGED since${RESET}" ;;
        unverified) echo "${DIM}not pack-verified — nobody has followed this zip's own steps${RESET}" ;;
    esac
}

presence_words() {
    case "$1" in
        0) echo "no board at all — a machine and nothing else" ;;
        1) echo "a board attached, and nothing but software after that" ;;
        2) echo "a person for one action, then software does the rest" ;;
        3) echo "a person IS the instrument — somebody has to look" ;;
        *) echo "undeclared" ;;
    esac
}

# ---------------------------------------------------------------------------

pack_experiment() {
    local dir="${1%/}"
    local num="${dir%%-*}"
    local stage="$OUT_DIR/.stage/$dir"

    echo
    echo "${BOLD}=== $dir ===${RESET}"

    if [[ ! -d "$dir" ]]; then
        echo "  ${RED}no such experiment${RESET}"; REFUSED=$((REFUSED + 1)); return
    fi

    # -- the gate ----------------------------------------------------------
    #
    # A zip is a claim that this built. Make the claim true first, and put the
    # proof of it in the box.
    say "running ./check.sh — nothing is packed unverified"
    local check_out check_rc
    check_out="$(cd "$dir" && ./check.sh 2>&1)"; check_rc=$?
    if [[ $check_rc -ne 0 ]]; then
        echo "  ${RED}check.sh exited $check_rc — refusing to pack${RESET}"
        echo "$check_out" | grep '^FAIL' | sed 's/^/    /'
        REFUSED=$((REFUSED + 1)); return
    fi
    say "check.sh exit 0"

    rm -rf "$stage"; mkdir -p "$stage"

    # -- the firmware ------------------------------------------------------
    #
    # Matched on the experiment's own number, not on `*.uf2`: several of these
    # directories also hold scratch images from their walkthrough — exp142 has
    # `imageA.uf2`, exp147 has `fastA.uf2` — and shipping those would be
    # shipping something nobody named.
    # Byte-identical images under two names are dropped to one. exp103's
    # target held `exp103.uf2` beside the `exp103-embassy-blink.uf2` its
    # check.sh builds — same bytes, a day older, left over from a hand-run.
    # Asking a stranger which of two identical files to flash is a question
    # with no answer. Newest wins, so what this run built is what survives.
    local uf2s=()
    while IFS= read -r f; do uf2s+=("$f"); done < <(
        find "$dir/target" -maxdepth 1 -name "$num*.uf2" -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | cut -d' ' -f2- \
            | while IFS= read -r f; do echo "$(sha256sum "$f" | cut -c1-64) $f"; done \
            | awk '!seen[$1]++ {sub(/^[^ ]* /, ""); print}' \
            | sort
    )

    if [[ ${#uf2s[@]} -gt 0 ]]; then
        mkdir -p "$stage/firmware"
        cp "${uf2s[@]}" "$stage/firmware/"
        (cd "$stage/firmware" && sha256sum ./*.uf2 > SHA256SUMS)
        say "${#uf2s[@]} firmware image(s)"
    else
        say "no firmware of its own — the zip says so"
    fi

    # -- the pages ---------------------------------------------------------
    #
    # The experiment's own pages, because for five experiments the page IS the
    # product. Plus the two that put firmware on a board from a browser, so a
    # recipient holding only a phone can finish without a checkout and without
    # reaching the BOOTSEL button.
    mkdir -p "$stage/pages"
    local own=0
    for p in "$dir"/*.html; do [[ -e "$p" ]] && { cp "$p" "$stage/pages/"; own=$((own + 1)); }; done
    cp "$PAGES_DIR/bootsel.html" "$PAGES_DIR/pflash.html" "$stage/pages/"
    say "$own page(s) of its own, plus bootsel.html and pflash.html"

    # -- the words ---------------------------------------------------------
    if [[ -f "$dir/README.md" ]]; then
        cp "$dir/README.md" "$stage/README.md"
    else
        printf '%s\n' \
            "This experiment has no README.md in the repository it came from." \
            "" \
            "That is a gap, not a decision. FLASH.txt and CHECK.txt are what" \
            "there is; the source and the index entry are at" \
            "https://github.com/dltdojo/rp2350-yi26" > "$stage/README-MISSING.txt"
    fi
    printf '%s\n' "$check_out" > "$stage/CHECK.txt"
    [[ -f "$dir/PACKED.md" ]] && cp "$dir/PACKED.md" "$stage/"
    say "$(pack_status_line "$dir")"

    write_flash_txt "$dir" "$num" "$stage" "${uf2s[@]:-}"

    # -- the box -----------------------------------------------------------
    mkdir -p "$OUT_DIR"
    rm -f "$OUT_DIR/$dir.zip"
    (cd "$OUT_DIR/.stage" && zip -q -r "$OUT_DIR/$dir.zip" "$dir")
    rm -rf "$stage"
    say "${GREEN}$OUT_DIR/$dir.zip${RESET} ($(stat -c%s "$OUT_DIR/$dir.zip") bytes)"
    PACKED=$((PACKED + 1))
}

# ---------------------------------------------------------------------------
# FLASH.txt — everything a person needs before they plug anything in, and
# nothing this script cannot actually know. Where the answer is specific to the
# experiment, it is copied from the declaration that guards it; where the
# answer is in the README, it says so rather than paraphrasing.

write_flash_txt() {
    local dir="$1" num="$2" stage="$3"; shift 3
    local uf2s=("$@")
    local commit dirty proves needs presence

    local steps; steps="$(steps_section "$dir")"
    commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]] \
        && dirty=" (with uncommitted changes in the checkout it was packed from)" || dirty=""
    proves="$(index_field "$dir" 3)"
    needs="$(index_field "$dir" 2)"
    presence="$(declared "$dir" PRESENCE)"

    {
        echo "$dir"
        [[ -n "$proves" ]] && { echo; echo "$proves"; }
        echo
        echo "From https://github.com/dltdojo/rp2350-yi26 — a teaching repository for"
        echo "the RP2350, one experiment at a time. Apache-2.0."

        echo
        echo "WHAT IS IN THIS ZIP"
        if [[ ${#uf2s[@]} -gt 0 && -n "${uf2s[0]}" ]]; then
            local f
            for f in "${uf2s[@]}"; do
                # Padded to one column short of the labels below, with the
                # space printed rather than padded: exp136's longer name filled
                # the field exactly and ran into its own byte count.
                printf '  %-32s %s bytes\n' "firmware/$(basename "$f")" "$(stat -c%s "$f")"
            done
            if [[ ${#uf2s[@]} -gt 1 ]]; then
                echo "  ...more than one image, and they are not interchangeable."
                echo "  README.md is where it says which is which."
            fi
            echo "  firmware/SHA256SUMS              so you can tell you got these bytes"
        else
            echo "  NO FIRMWARE. This experiment has none of its own — it runs against"
            echo "  another experiment's, or against no board at all. See 'WHAT IT RUNS"
            echo "  ON' below, and README.md."
        fi
        echo "  pages/                           open these in a browser, from the file"
        echo "                                   manager. bootsel.html and pflash.html"
        echo "                                   are how a phone flashes a board."
        echo "  README.md                        the experiment itself"
        echo "  CHECK.txt                        the output of its own check.sh, from"
        echo "                                   the run that produced this zip"

        echo
        if [[ -n "$steps" ]]; then
            echo "DO THIS, IN ORDER"
            echo "  Every step, every command, and what each one should print. You do"
            echo "  not need the source, a compiler, or anything else in the repository."
            echo
            printf '%s\n' "$steps" | sed 's/^/  /;s/^  $//'
            echo
            echo "  ---------------------------------------------------------------"
        else
            echo "THERE IS NO STANDALONE WALKTHROUGH FOR THIS EXPERIMENT YET"
            echo "  Its README.md, in this zip, is the procedure — but it was written"
            echo "  for somebody with the whole repository, so some of it refers to"
            echo "  files this zip does not carry. That is a gap in the repository,"
            echo "  not a step you have missed."
            echo
        fi

        echo
        echo "OTHER WAYS TO PUT IT ON THE BOARD"
        echo "  Three routes. The first needs nothing installed; the second needs only"
        echo "  a phone; the third needs a checkout of the repository."
        echo
        echo "  1. THE BOOT DRIVE. Hold BOOTSEL while plugging the board in. A drive"
        echo "     called RP2350 appears. Copy the .uf2 onto it. The board reboots"
        echo "     into the firmware by itself."
        echo
        echo "  2. FROM A BROWSER, INCLUDING A PHONE'S. Needs Chromium, Chrome or Edge"
        echo "     — WebUSB. Open pages/bootsel.html, put the board into BOOTSEL with"
        echo "     it, then open pages/pflash.html and give it the .uf2. Do those two"
        echo "     without a pause: a board left waiting in BOOTSEL while somebody"
        echo "     reads the next step may not still be in BOOTSEL when they get there."
        echo
        echo "  3. yi26 flash <file>.uf2 — from a checkout. Hands-free on any board"
        echo "     already running exp105 or later, because the firmware reboots itself"
        echo "     when the port is opened at 1200 baud. No button."

        echo
        echo "BEFORE YOU DO — three ways this goes wrong on somebody else's board"
        echo "  * IF THIS BOARD HAS EVER RUN exp147, its flash carries a partition"
        echo "    table, and a board with one takes NOTHING from the BOOTSEL drive."
        echo "    That is measured, in exp144. Route 2 is how such a board is"
        echo "    reflashed; recover.html in the repository erases the table."
        echo "  * THE LED IS ASSUMED TO BE ON GPIO 25, which is where the official"
        echo "    Pico 2 puts it. A board that wires it elsewhere runs this firmware"
        echo "    correctly and looks dead."
        echo "  * THE PACKAGE IS ASSUMED TO BE RP2350A (30 GPIO). An RP2350B board"
        echo "    needs the firmware rebuilt with a different feature. Everything"
        echo "    else here — BOOTSEL, the boot drive, the USB controller — is ROM"
        echo "    and silicon, and is the same on any RP2350."
        echo
        echo "  This repository has been verified on official Raspberry Pi Pico 2"
        echo "  (non-W) boards on Ubuntu, and nowhere else. On any other board or"
        echo "  host, you are the first person to run it, and a report either way is"
        echo "  welcome."

        echo
        echo "WHAT THIS EXPERIMENT ASKS OF YOU"
        [[ -n "$needs" ]] && echo "  Needs $needs — $(presence_words "$presence")"
        echo
        echo "  That number is about verifying the experiment's claim, and it"
        echo "  deliberately EXCLUDES the cost of flashing into it: whether the board"
        echo "  needs a hand on BOOTSEL depends on what is on it right now, not on"
        echo "  what you are putting there."

        echo
        echo "WHAT IT RUNS ON, AT THE USB LAYER"
        printf '  interface:    %s\n' "$(declared "$dir" USB_IFACE)"
        printf '  carries:      %s\n' "$(declared "$dir" USB_CARRIES)"
        printf '  host driver:  %s\n' "$(declared "$dir" USB_HOST)"
        printf '  runs on:      %s\n' "$(declared "$dir" USB_RUNS_ON)"
        echo "  ('runs on: own' means this firmware. Anything else names the"
        echo "  experiment whose firmware this one measures — flash that one.)"

        echo
        echo "FLASHING IT IS NOT THE SAME AS SEEING IT WORK"
        echo "  Most experiments here need something arranged on the HOST as well —"
        echo "  a udev rule for raw USB access, a kernel driver detached, a shared"
        echo "  network connection, a mounted drive. Skipping those is the usual"
        [[ -n "$steps" ]] \
            && echo "  reason a correctly flashed board appears to do nothing, which is" \
            && echo "  why they are steps above rather than a note here." \
            || echo "  reason a correctly flashed board appears to do nothing."
        echo
        echo "  README.md was written for somebody with the whole repository, so its"
        echo "  links and its ../../crates/... paths point into"
        echo "  https://github.com/dltdojo/rp2350-yi26 rather than into this zip."

        echo
        echo "PROVENANCE"
        echo "  packed from commit $commit$dirty"
        echo "  packed on         $(date -u '+%Y-%m-%d %H:%M UTC')"
        echo "  built by          this experiment's own check.sh, exit 0 (CHECK.txt)"
        echo
        echo "  SHA256SUMS tells you the file arrived intact. It does NOT let you"
        echo "  reproduce this image: a build of the same source from a checkout at"
        echo "  a different path produces a DIFFERENT, equally correct .uf2 —"
        echo "  measured, same size, 8 bytes more .text, and byte-identical only"
        echo "  when rebuilt in the same directory. A hash of your own build that"
        echo "  disagrees with this one is not evidence of anything wrong."
        echo
        echo "  Nothing in this zip talks to a board. It is what one checkout built"
        echo "  and what that checkout's own checks said about it — not a promise"
        echo "  about your board."
    } > "$stage/FLASH.txt"
}

# ---------------------------------------------------------------------------

# Stamp a PACKED.md with the hash of what it was written against. Separate from
# writing the record on purpose: the prose is a person's account of doing the
# thing, and only the binding is mechanical.
if [[ "${1-}" == --stamp ]]; then
    [[ -n "${2-}" ]] || { echo "usage: ./pack.sh --stamp expNNN"; exit 1; }
    for d in "${2%/}"*/; do
        [[ -f "$d/PACKED.md" ]] || { echo "${RED}${d%/} has no PACKED.md to stamp${RESET}"; exit 1; }
        h="$(content_hash "${d%/}")"
        sed -i "s/^hash:.*/hash: $h/" "$d/PACKED.md"
        echo "  ${d%/}  hash: $h"
    done
    exit 0
fi

if [[ "${1-}" == --status ]]; then
    echo "${BOLD}Which experiments have had their own zip followed, step by step${RESET}"
    echo "${DIM}A hash over every .rs .toml .lock .html .sh and README.md decides${RESET}"
    echo "${DIM}whether a recorded verification still describes what is there now.${RESET}"
    echo
    n_ok=0; n_stale=0; n_none=0
    for d in exp*/; do
        case "$(pack_status "${d%/}")" in
            ok)         n_ok=$((n_ok + 1));    mark="${GREEN}verified${RESET}" ;;
            stale)      n_stale=$((n_stale + 1)); mark="${YELLOW}STALE   ${RESET}" ;;
            unverified) n_none=$((n_none + 1)); mark="${DIM}—       ${RESET}" ;;
        esac
        printf '  %s  %-42s %s\n' "$mark" "${d%/}" \
            "$(sed -n 's/^steps: *//p' "${d%/}/PACKED.md" 2>/dev/null | head -1)"
    done
    echo
    echo "  $n_ok verified, $n_stale stale, $n_none never done."
    exit 0
fi

if [[ "${1-}" == -h || "${1-}" == --help ]]; then
    sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
fi

echo "${BOLD}pack.sh${RESET} — one zip per experiment, for somebody without a checkout"
echo "${DIM}Each is built by running that experiment's check.sh. A failure refuses.${RESET}"

if [[ $# -gt 0 ]]; then
    for arg in "$@"; do
        matches=(); for d in "${arg%/}"*/; do [[ -d "$d" ]] && matches+=("$d"); done
        if [[ ${#matches[@]} -eq 0 ]]; then
            echo; echo "${RED}no experiment matches '$arg'${RESET}"; REFUSED=$((REFUSED + 1))
        else
            for d in "${matches[@]}"; do pack_experiment "$d"; done
        fi
    done
else
    for d in exp*/; do pack_experiment "$d"; done
fi

rm -rf "$OUT_DIR/.stage"

echo
echo "${BOLD}=== Summary ===${RESET}"
echo "  $PACKED packed, $REFUSED refused. In $OUT_DIR/"
echo
echo "  A zip is a binary drop. It carries no buildable source, because an"
echo "  experiment directory on its own has neither the shared crates it"
echo "  depends on nor the lib.sh its scripts source. Send somebody the"
echo "  repository URL if what they want is the code."

[[ $REFUSED -eq 0 ]] || exit 1
exit 0
