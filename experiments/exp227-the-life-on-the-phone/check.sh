#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp227 quick check — everything that needs no board.
#
#   1. the page's checking (life.html, between `BEGIN life-check` and `END
#      life-check`), under node, fed in 64-byte packets: its Rule 30 is
#      rule30.py's on 5005 words; two lives as the board sends them are all
#      Rule 30's; joining mid-life, a flipped bit, a lost line, a wrong seam, a
#      wrong minstret and a LIFE line that disagrees are each told apart. Wrong
#      versions of the page are caught;
#   2. the whole page in headless Chromium, against a stand-in for the board's
#      USB device: it claims the interfaces, raises DTR, draws, gives a verdict,
#      and Copy works. findCdc is log.html's, byte for byte;
#   3. the shell builds for the chip, from exp225's shell.c and expect.h and
#      tools/hazard3/shell/speak.h — exp226's USB port — into the first 16 KiB of
#      flash, and its UF2 reads back as built, byte for byte the committed one
#      when the toolchain is the recorded one;
#   4. every log a phone gave back (board/*.txt) is checked by the page's own
#      block: generations, none of them wrong; and each generation is
#      rule30.py's at its round and generation, counted from SEED0.
#
# What none of it reaches: the board sending them, a phone drawing them, and
# a person seeing the LED and the page keep the same beat.
#
# Needs clang, lld, llvm-objcopy, Lean, the Hazard3 testbench, cargo, python3
# and node; Playwright's Chromium for step 2. Under a minute.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
source ../../tools/pages/pagecheck.sh
require_supported_platform

PRESENCE=2
LIFELINE="no: a C shell, not crates/lifeline — BOOTSEL by hand is the way back"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="webusb"
USB_RUNS_ON="own"
usb_check

mkdir -p build
python3 fixtures.py build/fixtures

if ! command -v node > /dev/null; then
    echo "SKIP  the page: node is not installed"
else
    page_parses life.html build
    page_findcdc life.html
    node page_test.mjs life.html build/fixtures || FAILED=1

    page_mutant "Rule 30 is left XOR (centre AND right)" 's/(left ^ (centre | right))/(left ^ (centre \& right))/' life.html node page_test.mjs @ build/fixtures
    page_mutant "a generation is taken as its own expectation" 's/want = rule30(last.word); against = `Rule 30 of generation/want = e.word; against = `Rule 30 of generation/' life.html node page_test.mjs @ build/fixtures
    page_mutant "the seam between lives is not checked" 's/if (e.seed !== last.word) {/if (false) {/' life.html node page_test.mjs @ build/fixtures
    page_mutant "the right neighbour is the cell itself" 's/right = (x >>> ((i + 31) % 32)) \& 1;/right = (x >>> i) \& 1;/' life.html node page_test.mjs @ build/fixtures

    if page_playwright; then
        node page_browser.mjs life.html build/fixtures/good.txt "512 of 512 generations are Rule 30's" || FAILED=1
        node page_browser.mjs life.html build/fixtures/flipped.txt "2 wrong" || FAILED=1
    else
        echo "SKIP  the page in a browser: Playwright is not installed"
    fi
fi

S=../../tools/hazard3/shell
if [[ "$(../../tools/lean/lean.sh version 2>&1)" != Lean* ]] || ! ../../tools/hazard3/sim.sh ready; then
    echo "SKIP  the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi
if ./build.sh > /dev/null; then
    pass "the shell builds for the chip from exp225's shell.c and expect.h over speak.h, in $(stat -c %s build/exp227.bin) of the 16384 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi
python3 "$S/uf2check.py" build/exp227.uf2 build/exp227.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 16384 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp227.uf2 | cut -d' ' -f1)" == "$(cat exp227.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp227.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

shopt -s nullglob
logs=(board/*.txt)
if (( ${#logs[@]} )) && command -v node > /dev/null; then
    node page_test.mjs life.html build/fixtures "${logs[@]}" | tail -n "${#logs[@]}" || FAILED=1
    python3 fixtures.py --board "${logs[@]}" || FAILED=1
else
    echo "SKIP  checking a phone's log: none recorded yet (board/*.txt)"
fi

exit "$FAILED"
