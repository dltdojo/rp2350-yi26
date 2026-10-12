#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp231 quick check — everything that needs no board.
#
#   1. the page's checking (fly.html, between `BEGIN fly-check` and `END
#      fly-check`), under node, fed in 64-byte packets: its Rule 30 is
#      rule30.py's and its fly fly.py's on 5007 pairs; two rounds as the board
#      sends them all agree; joining mid-round, a flipped bit, a wrong count, a
#      step crossed to look like down, a lost line, a FLY line whose totals do
#      not add up and a wrong minstret are each told apart. Wrong versions of
#      the page are caught;
#   2. the whole page in headless Chromium, against a stand-in for the board's
#      USB device: it claims the interfaces, raises DTR, draws, gives a verdict,
#      and Copy works; with no WebUSB, Demo plays and says it checks nothing.
#      findCdc is log.html's, byte for byte;
#   3. the shell builds for the chip, from exp225's and exp230's kernels and
#      tools/hazard3/shell/speak.h — exp226's USB port — into the first 16 KiB
#      of flash, and its UF2 reads back as built, byte for byte the committed
#      one when the toolchain is the recorded one;
#   4. on the RTL the same shell runs two rounds, each life rule30.py's and
#      each fly's counts fly.py's; wrong shells are caught by the check each
#      breaks;
#   5. every log a phone gave back (board/*.txt) is checked by the page's own
#      block, and each step against rule30.py and fly.py counted from SEED0.
#
# What none of it reaches: the board sending them, a phone drawing them, and
# a person seeing the LED and the page keep the same beat.
#
# Needs clang, lld, llvm-objcopy, Lean, the Hazard3 testbench, cargo, python3
# and node; Playwright's Chromium for step 2. Under two minutes.
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
    page_parses fly.html build
    page_findcdc fly.html
    node page_test.mjs fly.html build/fixtures || FAILED=1

    page_mutant "Rule 30 is left XOR (centre AND right)" 's/(left ^ (centre | right))/(left ^ (centre \& right))/' fly.html node page_test.mjs @ build/fixtures
    page_mutant "the fly looks the wrong way: up from the cell above" 's/const below = (before >>> ((i + 31) % 32)) \& 1/const below = (before >>> ((i + 1) % 32)) \& 1/' fly.html node page_test.mjs @ build/fixtures
    page_mutant "the counts are never compared" 's/if (saw.up !== e.up || saw.down !== e.down)/if (false)/' fly.html node page_test.mjs @ build/fixtures
    page_mutant "the FLY line's totals are not checked" 's/if (f.up !== sum.up || f.down !== sum.down) {/if (false) {/' fly.html node page_test.mjs @ build/fixtures
    page_mutant "the fly's minstret is not checked" 's/if (e.minstret !== FLY_MINSTRET)/if (false)/' fly.html node page_test.mjs @ build/fixtures

    if page_playwright; then
        node page_browser.mjs fly.html build/fixtures/good.txt "512 of 512 steps agree" || FAILED=1
        node page_browser.mjs fly.html build/fixtures/crossed.txt "1 wrong" || FAILED=1
    else
        echo "SKIP  the page in a browser: Playwright is not installed"
    fi
fi

S=../../tools/hazard3/shell
if [[ "$(../../tools/lean/lean.sh version 2>&1)" != Lean* ]] || ! ../../tools/hazard3/sim.sh ready; then
    echo "SKIP  the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi
source "$S/shell.sh"
if ./build.sh > /dev/null; then
    pass "the shell builds for the chip from exp225's and exp230's kernels over speak.h, in $(stat -c %s build/exp231.bin) of the 16384 bytes it may use, and for the RTL"
else
    fail "the shell builds"
    exit 1
fi
python3 "$S/uf2check.py" build/exp231.uf2 build/exp231.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 16384 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp231.uf2 | cut -d' ' -f1)" == "$(cat exp231.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp231.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# Two rounds on the RTL: LIFE round minstret gen1 gen256 centre-column, then
# FLY round minstret up down steps-up steps-still — each from rule30.py and
# fly.py, the second round seeded by the first's last generation.
want="$(python3 - <<'PY'
import re, sys
sys.path.insert(0, "../exp230-the-motion-the-fly-sees")
from fly import chain, fly_ref
from rule30 import SEED0, rule30
life = int(re.search(r"#define INSTRET (\d+)u", open("build/expect.h").read()).group(1))
fly = int(re.search(r"#define FLY_INSTRET (\d+)u", open("build/fly.h").read()).group(1))
out, seed = [], SEED0
for r in range(2):
    f = chain(seed, rule30)
    h = f[1:]
    steps, up, down = fly_ref(f)
    col = sum(((h[g] >> 16) & 1) << g for g in range(32))
    ups, stills = sum(u > d for u, d in steps), sum(u == d for u, d in steps)
    out += ["4c494645", f"{r:08x}", f"{life:08x}", f"{h[0]:08x}", f"{h[-1]:08x}", f"{col:08x}",
            "464c5920", f"{r:08x}", f"{fly:08x}", f"{up:08x}", f"{down:08x}", f"{ups:08x}", f"{stills:08x}"]
    seed = h[-1]
print(" ".join(out) + " exit=0 ")
PY
)"
got="$(shell_words build/sim.bin)"
if [[ "$got" == "$want" ]]; then
    pass "on the RTL the shell runs two rounds: each life rule30.py's, each fly's totals and steps fly.py's — 255 steps seen moving up and 1 not, then 256 and 0"
else
    fail "on the RTL the shell runs two rounds as rule30.py and fly.py do" "$got"
fi

# Wrong shells and wrong expectations: each is caught by the check it names.
side_by_side_begin
side_by_side shell_mutant "the fly's kernel is held to a hash that is not its own — check 10" fly.h \
    's/FLY_SHA\[32\] = {0x[0-9a-f][0-9a-f]/FLY_SHA[32] = {0x00/' "4641494c 0000000a "
side_by_side shell_mutant "the fly's halt is held to 1 instead of 0 — check 11" shell.c \
    's/x\[10\] != 0) board_fail(11/x[10] != 1) board_fail(11/' "4641494c 0000000b "
side_by_side shell_mutant "the chip is asked to count one more for the fly — check 12" fly.h \
    's/#define FLY_INSTRET \([0-9]*\)u/#define FLY_INSTRET 1\1u/' "4641494c 0000000c "
side_by_side shell_mutant "the first round's steps are held against a hash that is not fly.py's — check 13" fly.h \
    's/FLY_STEPS_SHA\[32\] = {0x[0-9a-f][0-9a-f]/FLY_STEPS_SHA[32] = {0x00/' "4641494c 0000000d "
side_by_side shell_mutant "the fly is shown the generations without the seed before them — check 13" shell.c \
    's/w\[FRAMES_OFF \/ 4\] = r.seed;/w[FRAMES_OFF \/ 4] = r.life[0];/' "4641494c 0000000d "
side_by_side shell_mutant "the shell calls a step moving down when it moved up — check 14" shell.c \
    's/if (r.steps\[2 \* g + 1\] > r.steps\[2 \* g\])/if (r.steps[2 * g + 1] < r.steps[2 * g])/' "4641494c 0000000e 00000001 "
side_by_side shell_mutant "the shell itself traps setting the fly up — a fault, not a check" shell.c \
    's/^    step = 7;$/    step = 7;\n    __asm__ volatile (".word 0");/' "4641554c 00000007 00000002 "
side_by_side_end

shopt -s nullglob
logs=(board/*.txt)
if (( ${#logs[@]} )) && command -v node > /dev/null; then
    node page_test.mjs fly.html build/fixtures "${logs[@]}" | tail -n "${#logs[@]}" || FAILED=1
    python3 fixtures.py --board "${logs[@]}" || FAILED=1
else
    echo "SKIP  checking a phone's log: none recorded yet (board/*.txt)"
fi

exit "$FAILED"
