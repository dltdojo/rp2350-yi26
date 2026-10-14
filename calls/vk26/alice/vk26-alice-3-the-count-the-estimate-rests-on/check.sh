#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# vk26-alice-3 quick check — everything that needs no board.
#
#   1. proof/Count.lean checks, on Lean's own axioms: started at base with the
#      kernel's 116 bytes at the image's start, the kernel halts with 0 after
#      exactly COST = 6294284 instructions, whatever the samples, memory the
#      image with the 256 counts of its 4096 byte samples from 0x1400 and the
#      largest at 0x1800 (from_boot); the largest is the commonest value's
#      count (most_is_max) and the counts add up to 4096 (hist_sum); and the
#      kernel's trace — every pc, every address, the end — is the same for any
#      two images that differ only in their samples (count_constant_time),
#      where the plain histogram, counts[sample] += 1, is refused
#      (naive_refused). Wrong kernels and wrong claims are refused;
#      kernel.bin is what the proof writes;
#   2. the Lean model and the Hazard3 RTL agree with count.py on 12 streams,
#      the model after COST, and the RTL takes the same cycles on every one;
#   3. the shell builds for the chip, into the first 32 KiB of flash, and its
#      UF2 reads back as built — byte for byte the committed one when the
#      toolchain is the recorded one; and the layout revision 3's prediction
#      rests on: FIXED[0] and FIXED[2] share the XIP cache's sets with
#      `mret` and the trap entry, FIXED[1] does not;
#   4. on the RTL the shell runs all five streams, each twice back to back,
#      each count checked against the shell's own, minstret the RTL's, mcycle
#      one number for all ten runs; wrong shells are caught;
#   5. count.html, the page a phone shows the board on, built into one file:
#      its count and both estimates are count.py's on every stream, and
#      §6.3.1's own example; it tells right streams from wrong ones and says
#      when the cycles differ; wrong pages are caught; in headless Chromium;
#   6. every log a phone gave back (board/*.txt): each stream's 256 counts by
#      count.py and by the page; the mcycles printed as read, not judged —
#      one was predicted, and the first board run gave three.
#
# What none of it reaches: why the chip's mcycle moved, and
# whether the TRNG's estimate means anything — 4096 samples, not the
# million SP 800-90B §3.1.1 asks for.
#
# Needs Lean (tools/lean/setup.sh), the Hazard3 testbench
# (tools/hazard3/setup.sh), clang, lld, llvm-objcopy, cargo, python3 and node.
# Without Lean or the testbench it says SKIP. About seven minutes, most of it
# the model and the RTL running 6.3 million instructions a stream.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

TOOLS=../../../../tools
source ../../../../experiments/lib.sh
source "$TOOLS/pages/pagecheck.sh"
require_supported_platform

LEAN=$TOOLS/lean/lean.sh
$LEAN check proof/Count.lean || FAILED=1
$LEAN mutants proof/Count.lean || FAILED=1

SIM=$TOOLS/hazard3/sim.sh
source "$TOOLS/hazard3/shell/shell.sh"
if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! $SIM ready; then
    echo "SKIP  the differential and the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

work="$(mktemp -d)"
$LEAN exec proof/Count.lean "$work/kernel.bin" > /dev/null
if cmp -s "$work/kernel.bin" kernel.bin && [[ "$(sha256sum kernel.bin | cut -d' ' -f1)" == "$(cut -d' ' -f1 kernel.sha256)" ]]; then
    pass "kernel.bin is what proof/Count.lean writes, $(stat -c %s kernel.bin) bytes, and kernel.sha256 is its hash"
else
    fail "kernel.bin is what proof/Count.lean writes"
fi
rm -rf -- "$work"
python3 differential/differential.py "$($LEAN exe rv32run)" || FAILED=1

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/vk26-alice-3.bin) of the 32768 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi
python3 "$TOOLS/hazard3/shell/uf2check.py" build/vk26-alice-3.uf2 build/vk26-alice-3.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 32768 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/vk26-alice-3.uf2 | cut -d' ' -f1)" == "$(cat vk26-alice-3.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 vk26-alice-3.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# Revision 3's prediction rests on where the chip build put things: the
# words of FIXED[0] and FIXED[2] over the cache sets of `mret` and the trap
# entry (offsets modulo 8 KiB, the 16 KiB cache's two ways), FIXED[1]'s not.
if python3 - <(llvm-nm -S build/chip.elf) <<'PY'
import sys
syms = {f[3]: (int(f[0], 16), int(f[1], 16)) for f in (l.split() for l in open(sys.argv[1])) if len(f) == 4}
trap, (fixed, size) = syms["trap"][0], syms["FIXED"]
one = size // 3
want = {(trap - 4) % 0x2000, trap % 0x2000}
over = []
for k in range(3):
    lo = fixed + k * one + 8
    sets = {a % 0x2000 for a in range(lo, lo + 4096, 4)}
    over.append(want <= sets)
print(f"trap {trap:#x}, FIXED {fixed:#x}: the copy of FIXED[0], [1], [2] over the trap's sets: {over}")
sys.exit(0 if over == [True, False, True] else 1)
PY
then
    pass "the chip build's layout is revision 3's: FIXED[0] and FIXED[2] over the cache sets of mret and the trap entry, FIXED[1] not"
else
    fail "the chip build's layout is revision 3's"
fi

# Every stream on the RTL: STRM s most want minstret mcycle, and the second
# run's minstret mcycle, then DONE 5.
got="$(shell_words build/sim.bin 400000000)"
if python3 - "$got" <<'PY'
import re, sys
sys.path.insert(0, ".")
from count import from_words, histogram
from trng_sim import stand_in_words
words = sys.argv[1].split()
text = open("build/expect.h").read()
instret = int(re.search(r"#define INSTRET (\d+)u", text).group(1))
wants = [int(x) for x in re.findall(r'^    \{"[^"]+", (\d+), \{', text, re.M)]
# tools/hazard3/shell/trng_sim.h's stand-in, DEVICE 0, for both draws: 1024 words from its LCG.
trng = max(histogram(from_words(stand_in_words(1024))))
rows, i = [], 0
while i < len(words) and words[i] == "5354524d":
    rows.append([int(w, 16) for w in words[i + 1:i + 8]])
    i += 8
ok = len(rows) == 2 + len(wants) and words[i:] == ["444f4e45", f"{len(rows):08x}", "exit=0"]
for s, (k, most, want, n, cycles, n2, cycles2) in enumerate(rows):
    w = trng if s < 2 else wants[s - 2]
    ok &= k == s and most == w and want == (0xffffffff if s < 2 else w) and n == n2 == instret
ok &= len({r[4] for r in rows} | {r[6] for r in rows}) == 1
print(f"the TRNG's stand-in: count.py's largest {trng}; the RTL: {' '.join(str(r[1]) for r in rows)}, "
      f"mcycle {' '.join(f'{r[4]}+{r[6]}' for r in rows)}")
sys.exit(0 if ok else 1)
PY
then
    pass "on the RTL the shell runs all five streams twice, every count the shell's own, minstret the RTL's, and one mcycle for all ten runs"
else
    fail "on the RTL the shell runs every stream to count.py's largest" "$got"
fi

# The page: one file, as a phone gets it; its count against count.py's; its
# verdicts on logs right and wrong; in a browser.
if ! command -v node > /dev/null; then
    echo "SKIP  the page: node is not installed"
else
    python3 ../pages/build.py count.html build/count.html
    python3 fixtures.py build/page build/expect.h
    page_parses build/count.html build
    page_findcdc build/count.html
    if [[ "$(sed -n 's/^const COUNT_INSTRET = \([0-9]*\);$/\1/p' count.html)" == \
          "$(sed -n 's/^#define INSTRET \([0-9]*\)u$/\1/p' build/expect.h)" ]]; then
        pass "the page's minstret is expect.h's, the RTL's"
    else
        fail "the page's minstret is expect.h's, the RTL's"
    fi
    shopt -s nullglob
    node page_test.mjs build/count.html build/page board/*.txt || FAILED=1
    # On the built page, as a phone runs it.
    page_mutant "each word's low byte is read four times" 's/b\[i\] = (words\[i >>> 2\] >>> (8 \* (i \& 3))) \& 255;/b[i] = words[i >>> 2] \& 255;/' \
        build/count.html node page_test.mjs @ build/page
    page_mutant "the interval is 1.96 wide, not 2.576" 's/p + 2.576 \* Math.sqrt/p + 1.96 * Math.sqrt/' \
        build/count.html node page_test.mjs @ build/page
    page_mutant "the per-bit estimate counts only the ones" 's/return countMcv(Math.max(ones, n - ones), n);/return countMcv(ones, n);/' \
        build/count.html node page_test.mjs @ build/page
    page_mutant "the kernel's counts are not compared" 's/const off = mine.findIndex((c, v) => c !== theirs\[v\]);/const off = -1;/' \
        build/count.html node page_test.mjs @ build/page
    page_mutant "minstret is not compared" 's/if (e.minstret !== COUNT_INSTRET)/if (false)/' \
        build/count.html node page_test.mjs @ build/page
    page_mutant "the first run after boot is timed too" 's/if (!(e.round === 0 \&\& e.s === 0)) s.cycles.push(e.cycles);/s.cycles.push(e.cycles);/' \
        build/count.html node page_test.mjs @ build/page
    page_mutant "the second run's minstret is not compared" "s/if (again.minstret !== COUNT_INSTRET)/if (false)/" \
        build/count.html node page_test.mjs @ build/page
    page_mutant "the second runs' cycles are kept with the first runs'" 's/s.again.push(again.cycles);/s.cycles.push(again.cycles);/' \
        build/count.html node page_test.mjs @ build/page
    page_mutant "a stream with a HIST line missing is judged anyway" 's/if (!words || !hp || hp.some((x) => x === null)) {/if (!words || !hp) {/' \
        build/count.html node page_test.mjs @ build/page
    if page_playwright; then
        ID=(vk26-alice-3 "vk26-alice-3 the count the estimate rests on")
        node ../pages/browser.mjs build/count.html build/page/good.txt "10 of 10 streams counted right" 5 "${ID[@]}" || FAILED=1
        node ../pages/browser.mjs build/count.html build/page/cycles.txt "the cycles differ" 5 "${ID[@]}" || FAILED=1
        node ../pages/browser.mjs build/count.html build/page/again.txt "second runs: the cycles differ" 5 "${ID[@]}" || FAILED=1
    else
        echo "SKIP  the page in a browser: Playwright is not installed"
    fi
fi

# Every log a phone gave back, by count.py.
shopt -s nullglob
logs=(board/*.txt)
if (( ${#logs[@]} )); then
    python3 fixtures.py --board build/expect.h "${logs[@]}" || FAILED=1
else
    echo "SKIP  checking a phone's log: none recorded yet (board/*.txt)"
fi

# Wrong shells and wrong expectations: each is caught by the check it names.
T0="5354524d 00000000 0000001a ffffffff 00600b0f 00700e11 00600b0f 00700e11 "
T1="5354524d 00000001 0000001a ffffffff 00600b0f 00700e11 00600b0f 00700e11 "
side_by_side_begin
side_by_side shell_mutant "kernel.sha256 is not kernel.bin's hash — check 1" expect.h \
    's/KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/KERNEL_SHA[32] = {0x00/' "4641494c 00000001 00000000 "
side_by_side shell_mutant "the kernel calls HASH where it should halt — check 2" expect.h \
    's/0x93, 0x02, 0x10, 0x00/0x93, 0x02, 0x00, 0x00/' "4641494c 00000002 00000008 "
side_by_side shell_mutant "the chip is asked to count one more instruction — check 3" expect.h \
    's/^#define INSTRET \([0-9]*\)u$/#define INSTRET 6294288u/' "4641494c 00000003 00600b0f "
side_by_side shell_mutant "gen.py's largest for a fixed stream is off by one — check 4" expect.h \
    's/^    {"each value 16 times", 16, {/    {"each value 16 times", 17, {/' "${T0}${T1}4641494c 00000004 00000010 "
side_by_side shell_mutant "the samples go in a word late — check 4, at gen.py's largest" shell.c \
    's/w\[SAMPLES \/ 4 + k\] = words\[k\];/w[SAMPLES \/ 4 + 1 + k] = words[k];/' "*4641494c 00000004 *"
side_by_side shell_mutant "the largest count is left in the region — check 4" shell.c \
    's/for (uint32_t i = HIST \/ 4; i <= MOST \/ 4; i++) w\[i\] = 0;/for (uint32_t i = HIST \/ 4; i < MOST \/ 4; i++) w[i] = 0;/' \
    "4641494c 00000004 00000000 "
side_by_side shell_mutant "there is no second run: the first's halt is never recorded — check 2" shell.c \
    's/    if (run == 0) {/    if (0) {/' "4641494c 00000002 00000000 "
side_by_side shell_mutant "the shell itself traps in step 3 — a fault, not a check" shell.c \
    's/^    step = 3;$/    step = 3;\n    __asm__ volatile (".word 0");/' "4641554c 00000003 00000002 "
side_by_side_end

# A TRNG giving nothing: check 10, before any kernel runs.
work="$(mktemp -d)"
if ./build.sh sim shell build "$work/sim" 2 2> /dev/null && [[ "$(shell_words "$work/sim.bin")" == "4641494c 0000000a 00000000 "* ]]; then
    pass "the shell stops at check 10 when the TRNG gives nothing (trng_sim.h's DEVICE 2)"
else
    fail "the shell stops at check 10 when the TRNG gives nothing" "$(shell_words "$work/sim.bin" 2> /dev/null)"
fi
rm -rf -- "$work"

exit "$FAILED"
