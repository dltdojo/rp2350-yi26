#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# vk26-alice-2 quick check — everything that needs no board.
#
#   1. proof/Trust.lean checks, on Lean's own axioms: started at base with the
#      kernel's 448 bytes at the image's start, the kernel halts after exactly
#      `cost` instructions, with 2 if HASH's answer to the KAT is not the
#      expected digest — before it reads a sample — else 1 if the start-up
#      window fails, else 3 if the next window fails, the run carried across
#      the edge between them, else 0; and the region is the image with HASH's
#      answer at the KAT's scratch and, with 0 only, HASH of the second window
#      as the output (from_boot, trusts_after_kat). Wrong kernels and wrong
#      claims are refused; kernel.bin is what the proof writes;
#   2. the Lean model and the Hazard3 RTL halt with trust.py's code on all 14
#      of trust.py's streams and three wrong expected digests, the model after
#      the proof's count, its region the image with hashlib's bytes and
#      nothing else;
#   3. the shell builds for the chip, into the first 32 KiB of flash, and its
#      UF2 reads back as built — byte for byte the committed one when the
#      toolchain is the recorded one;
#   4. on the RTL the shell runs all five streams, the TRNG's stand-in and
#      gen.py's four, SHA-256 answering HASH — spoiled on purpose for one, so
#      that the kernel must stop at the KAT — each halting with trust.py's code
#      and the RTL's count for it; wrong shells are caught, two of them by the
#      KAT itself;
#   5. trust.html, the page a phone shows the board on, built into one file by
#      ../pages/build.py with ../pages/health.js's tests in it: they stop
#      where trust.py's do on every stream; it tells right streams from wrong
#      ones, in 64-byte packets, with WebCrypto's SHA-256; wrong pages are
#      caught; in headless Chromium against a stand-in board;
#   6. every log a phone gave back (board/*.txt): each stream's KAT answer,
#      code, minstret and output, by trust.py and hashlib, and by the page.
#
# What none of it reaches: the chip running it, and a phone reading it; a
# saved log is what one did, once.
#
# Needs Lean (tools/lean/setup.sh), the Hazard3 testbench
# (tools/hazard3/setup.sh), clang, lld, llvm-objcopy, cargo, python3 and node.
# Without Lean or the testbench it says SKIP. About three minutes, most of it
# the RTL running the shell.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

TOOLS=../../../../tools
source ../../../../experiments/lib.sh
source "$TOOLS/pages/pagecheck.sh"
require_supported_platform

LEAN=$TOOLS/lean/lean.sh
$LEAN check proof/Trust.lean || FAILED=1
$LEAN mutants proof/Trust.lean || FAILED=1

SIM=$TOOLS/hazard3/sim.sh
source "$TOOLS/hazard3/shell/shell.sh"
if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! $SIM ready; then
    echo "SKIP  the differential and the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

work="$(mktemp -d)"
$LEAN exec proof/Trust.lean "$work/kernel.bin" > /dev/null
if cmp -s "$work/kernel.bin" kernel.bin && [[ "$(sha256sum kernel.bin | cut -d' ' -f1)" == "$(cut -d' ' -f1 kernel.sha256)" ]]; then
    pass "kernel.bin is what proof/Trust.lean writes, $(stat -c %s kernel.bin) bytes, and kernel.sha256 is its hash"
else
    fail "kernel.bin is what proof/Trust.lean writes"
fi
rm -rf -- "$work"
python3 differential/differential.py "$($LEAN exe rv32run)" || FAILED=1

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/vk26-alice-2.bin) of the 32768 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi
python3 "$TOOLS/hazard3/shell/uf2check.py" build/vk26-alice-2.uf2 build/vk26-alice-2.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 32768 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/vk26-alice-2.uf2 | cut -d' ' -f1)" == "$(cat vk26-alice-2.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 vk26-alice-2.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# Every stream on the RTL: STRM s code want minstret spoil, then DONE 5.
got="$(shell_words build/sim.bin 400000000)"
if python3 - "$got" <<'PY'
import re, sys
sys.path.insert(0, ".")
from trust import trust_outcome
from health import unpack
from lines import expect_instret
from trng_sim import stand_in_words
words = sys.argv[1].split()
instret = expect_instret("build/expect.h")
fixed = [(int(sp), int(w)) for sp, w in re.findall(r'^    \{"[^"]+", (\d+), (\d+), \{', open("build/expect.h").read(), re.M)]
# tools/hazard3/shell/trng_sim.h's stand-in, DEVICE 0: 64 words from its LCG.
trng = trust_outcome(unpack(stand_in_words(64)))[0]
rows, i = [], 0
while i < len(words) and words[i] == "5354524d":
    rows.append([int(w, 16) for w in words[i + 1:i + 6]])
    i += 6
ok = len(rows) == 1 + len(fixed) and words[i:] == ["444f4e45", f"{len(rows):08x}", "exit=0"]
for s, (k, code, want, n, spoil) in enumerate(rows):
    sp, w = (0, trng) if s == 0 else fixed[s - 1]
    ok &= k == s and code == w and want == (0xffffffff if s == 0 else w) and n == instret[code] and spoil == sp
    ok &= (code == 2) == (spoil == 1)
print(f"the TRNG's stand-in: trust.py says {trng}; the RTL: {' '.join(str(r[1]) for r in rows)}")
sys.exit(0 if ok else 1)
PY
then
    pass "on the RTL the shell runs all five streams, SHA-256 answering HASH, each halting with trust.py's code and the RTL's count for it, the spoiled one at the KAT"
else
    fail "on the RTL the shell runs every stream to trust.py's code" "$got"
fi

# The page: one file, as a phone gets it; its own tests against trust.py's;
# its verdicts on streams right and wrong; in a browser.
if ! command -v node > /dev/null; then
    echo "SKIP  the page: node is not installed"
else
    python3 ../pages/build.py trust.html build/trust.html
    python3 fixtures.py build/page build/expect.h
    page_parses build/trust.html build
    page_findcdc build/trust.html
    if [[ "$(sed -n 's/^const TRUST_INSTRET = \[\(.*\)\];$/\1/p' trust.html | tr -d ' ')" == \
          "$(sed -n 's/^static const uint32_t INSTRET\[4\] = {\(.*\)};$/\1/p' build/expect.h | tr -d ' ')" ]]; then
        pass "the page's minstret for each code is expect.h's, the RTL's"
    else
        fail "the page's minstret for each code is expect.h's, the RTL's"
    fi
    if python3 - <<'PY'
import re, sys
page = re.search(r"^const TRUST_KAT = '([^']*)';$", open("trust.html").read(), re.M).group(1).encode()
shell = bytes(int(x, 16) for x in re.search(r"KAT_MSG\[64\] = \{([^}]*)\}", open("build/expect.h").read()).group(1).split(","))
sys.exit(0 if page == shell and len(page) == 64 else 1)
PY
    then
        pass "the page's KAT message is expect.h's, the 64 bytes the kernel asks HASH about"
    else
        fail "the page's KAT message is expect.h's"
    fi
    shopt -s nullglob
    node page_test.mjs build/trust.html build/page board/*.txt || FAILED=1
    # On the built page: health.js's tests and the page's own block, as a phone runs them.
    page_mutant "the KAT's answer is never compared" 's/const j = trustJudge(bits, kat.hex === right);/const j = trustJudge(bits, true);/' \
        build/trust.html node page_test.mjs @ build/page
    page_mutant "a spoiled answer is taken as it comes" 's/if (kat.hex !== (kat.spoil ? spoiled : right))/if (false)/' \
        build/trust.html node page_test.mjs @ build/page
    page_mutant "the start-up window is not tested" 's/return { ...j, code: \[1, 3, 0\]\[j.passed\] };/return { ...j, code: [0, 3, 0][j.passed] };/' \
        build/trust.html node page_test.mjs @ build/page
    page_mutant "the run is reset at each window's edge" 's/      run = bits\[i\] === last ? run + 1 : 1;/      run = bits[i] === last \&\& i !== start ? run + 1 : 1;/' \
        build/trust.html node page_test.mjs @ build/page
    page_mutant "the output is taken to be SHA-256 of the start-up window" 's/healthWindowBytes(bits, 1)/healthWindowBytes(bits, 0)/' \
        build/trust.html node page_test.mjs @ build/page
    page_mutant "minstret is not compared" 's/if (e.code <= 3 \&\& e.minstret !== TRUST_INSTRET\[e.code\])/if (false)/' \
        build/trust.html node page_test.mjs @ build/page
    page_mutant "a stream whose KAT line is lost is judged as if HASH were honest" 's/kat = kats.get(key(e)), out/kat = kats.get(key(e)) || { spoil: 0, hex: right }, out/' \
        build/trust.html node page_test.mjs @ build/page
    if page_playwright; then
        ID=(vk26-alice-2 "vk26-alice-2 the hash tested first")
        node ../pages/browser.mjs build/trust.html build/page/good.txt "10 of 10 streams judged right" 5 "${ID[@]}" || FAILED=1
        node ../pages/browser.mjs build/trust.html build/page/unchecked.txt "1 wrong" 5 "${ID[@]}" || FAILED=1
    else
        echo "SKIP  the page in a browser: Playwright is not installed"
    fi
fi

# Every log a phone gave back, by trust.py and hashlib.
shopt -s nullglob
logs=(board/*.txt)
if (( ${#logs[@]} )); then
    python3 fixtures.py --board build/expect.h "${logs[@]}" || FAILED=1
else
    echo "SKIP  checking a phone's log: none recorded yet (board/*.txt)"
fi

# Wrong shells and wrong expectations: each is caught by the check it names.
TRNG_OK="5354524d 00000000 00000000 ffffffff 00008851 00000000 "
side_by_side_begin
side_by_side shell_mutant "kernel.sha256 is not kernel.bin's hash — check 1" expect.h \
    's/KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/KERNEL_SHA[32] = {0x00/' "4641494c 00000001 00000000 "
side_by_side shell_mutant "the shell forgets to spoil HASH's answer for the fair stream — check 2, code 0 where 2 is due" expect.h \
    's/^    {"fair", 1, 2, {/    {"fair", 0, 2, {/' "${TRNG_OK}4641494c 00000002 00000000 "
side_by_side shell_mutant "the spoiled stream is said to pass — check 2" expect.h \
    's/^    {"fair", 1, 2, {/    {"fair", 1, 0, {/' "${TRNG_OK}4641494c 00000002 00000002 "
side_by_side shell_mutant "the chip is asked to count one more for code 2 — check 3" expect.h \
    's/^\(static const uint32_t INSTRET\[4\] = {[0-9]*, [0-9]*, \)51,/\152,/' "${TRNG_OK}4641494c 00000003 00000033 "
side_by_side shell_mutant "HASH writes its digest a word late — the KAT refuses it: check 2, code 2 unspoiled" shell.c \
    's/uint8_t \*dst = (uint8_t \*)x\[12\];/uint8_t *dst = (uint8_t *)x[12] + 4;/' "4641494c 00000002 00000002 "
side_by_side shell_mutant "HASH hashes 64 bytes too few — the KAT refuses it: check 2, code 2 unspoiled" shell.c \
    's/hash_ok \&= board_hash((const uint8_t \*)x\[10\], x\[11\],/hash_ok \&= board_hash((const uint8_t *)x[10], x[11] - 64,/' \
    "4641494c 00000002 00000002 "
side_by_side shell_mutant "a byte of the KAT's answer is left in the region — check 4" shell.c \
    's/for (uint32_t i = 0; i < 32; i++) r\[GOT_AT + i\] = 0;/for (uint32_t i = 0; i < 31; i++) r[GOT_AT + i] = 0;/' \
    "4641494c 00000004 00000000 "
side_by_side shell_mutant "the shell itself traps in step 3 — a fault, not a check" shell.c \
    's/^    step = 3;$/    step = 3;\n    __asm__ volatile (".word 0");/' "4641554c 00000003 00000002 "
side_by_side_end

# The TRNG giving nothing: check 10, before any kernel runs.
work="$(mktemp -d)"
if ./build.sh sim shell build "$work/sim" 2 2> /dev/null && [[ "$(shell_words "$work/sim.bin")" == "4641494c 0000000a 00000000 "* ]]; then
    pass "the shell stops at check 10 when the TRNG gives nothing (trng_sim.h's DEVICE 2)"
else
    fail "the shell stops at check 10 when the TRNG gives nothing" "$(shell_words "$work/sim.bin" 2> /dev/null)"
fi
rm -rf -- "$work"

exit "$FAILED"
