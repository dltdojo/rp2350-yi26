#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp179 quick check — non-interactive.
#
# The claim has two halves and only one of them can be reached without a person:
# a watchdog reset and a flash are both things software can cause, and pulling
# the USB cable out is not. So the cold-boot transcript is checked in, and
# `verify.py` rules on it in both directions — a cold transcript that still shows
# the marker is one where the power never actually went, and it fails here rather
# than being read as a result.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# One action by a person — the cable out and back in — and software does the
# rest. Everything else, including the two watchdog resets, the firmware does
# to itself.
PRESENCE=2
presence_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

command -v python3 > /dev/null && pass "python3 present" \
    || { fail "python3 present" "needed to rule on the transcripts"; exit 1; }

# --- it builds ------------------------------------------------------------
TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp179-what-survives-a-reset
UF2=target/exp179.uf2
if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
    if cargo build --release --quiet 2> /dev/null && [[ -f "$ELF" ]]; then
        pass "firmware compiles ($(stat -c%s "$ELF") byte ELF)"
    else
        fail "firmware compiles" "cargo build --release"
    fi
else
    echo "SKIP  no toolchain — see exp102"
fi

SRC=src/main.rs

# --- the three windows, and which of them is written ---------------------
grep -q 'const PRIOR: usize = 0x2007_C000' "$SRC" \
    && pass "it reads the earlier work's exact window, so the numbers are comparable" \
    || fail "PRIOR is 0x2007C000" "the point is to compare with the earlier measurement"
grep -q 'const BANK8: usize = 0x2008_0000' "$SRC" \
    && pass "and bank 8, which is outside everything the linker placed" \
    || fail "BANK8 is 0x20080000" "see exp159"
grep -q 'link_section = "\.uninit\.exp179_probe"' "$SRC" \
    && pass "and a probe in .uninit, the section cortex-m-rt does not initialise" \
    || fail "the probe is in .uninit" "in .bss it would be zeroed before it could be read"

# The one window that must never be written: it is the stack this code runs on.
grep -q 'PRIOR as \*mut' "$SRC" \
    && fail "0x2007c000 is never written" "writing there is writing over the live stack" \
    || pass "0x2007c000 is read and never written — it is the running stack's own region"

# A marker that could be mistaken for the result is not a marker.
grep -q 'const MARKER: \[u8; 4\] = \[0xDE, 0xAD, 0xBE, 0xEF\]' "$SRC" \
    && pass "the marker is 75% one-bits, so it cannot be misread as healthy SRAM noise" \
    || fail "the marker is DEADBEEF" "a 50% marker is indistinguishable from the finding"

# The whole-SRAM map, which is what turned a point into a boundary.
grep -q 'zero_map' "$SRC" && grep -q 'const BLOCKS' "$SRC" \
    && pass "it maps all of SRAM in 4 KB blocks, not only the three named windows" \
    || fail "the zero map is present" "three points cannot show where a cleared region ends"

# Why there is no pre_init here, recorded where somebody would look for one.
grep -q 'pre_init' "$SRC" \
    && pass "the source says what happened to the pre_init design" \
    || fail "pre_init is explained" "embassy-rp owns __pre_init; that is worth writing down"

# --- the two transcripts, which are the experiment -----------------------
for f in capture-after-flash.txt capture-cold-boot.txt; do
    [[ -f "$f" ]] && pass "$f is checked in" || fail "$f is checked in" "the record is incomplete"
done

python3 verify.py --after-flash capture-after-flash.txt
[[ $? -eq 0 ]] || FAILED=1
python3 verify.py --cold capture-cold-boot.txt
[[ $? -eq 0 ]] || FAILED=1

# --- the board, if it is here --------------------------------------------
if exp_running 179; then
    pass "a board is running exp179 — yi26 log reads it, and pulling the cable re-runs the cold half"
else
    echo "SKIP  the board is not running exp179; the checked-in transcripts stand"
fi

# --- the argument it makes -----------------------------------------------
grep -q 'identity road' README.md \
    && pass "the README says which road this opens" \
    || fail "the README names the identity road" "this is that road's first rung"
grep -q '50.5' README.md && grep -q '0.00' README.md \
    && pass "the README carries both numbers — the one measured here and the one it explains" \
    || fail "the README carries both numbers" "the finding is the pair, not either alone"

exit "$FAILED"
