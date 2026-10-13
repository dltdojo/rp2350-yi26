#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# vk26-alice-1 quick check — everything that needs no board.
#
#   1. proof/Seam.lean checks, on Lean's own axioms: started at base with the
#      kernel's 552 bytes at the image's start, the kernel halts after exactly
#      `cost (stop …)` instructions, with 0 if all four windows pass and else
#      the first failing window's number, and the region is the image with
#      one `HASH` digest for each window before the stop and nothing else
#      (from_boot). The repetition count is carried across every window's
#      edge (alice/lean/Alice/Window.lean). Wrong kernels and wrong claims are
#      refused; kernel.bin is what the proof writes;
#   2. the Lean model and the Hazard3 RTL halt with seam.py's code on all 14
#      of seam.py's streams, the model after the proof's count, its region the
#      image with hashlib's digests and nothing else;
#   3. the shell builds for the chip, into the first 32 KiB of flash, and its
#      UF2 reads back as built — byte for byte the committed one when the
#      toolchain is the recorded one;
#   4. on the RTL the shell runs all six streams, the TRNG's stand-in and
#      gen.py's five, answering HASH with SHA-256, each halting with
#      seam.py's code and the RTL's count for it, each digest SHA-256's;
#      wrong shells are caught;
#   5. seam.html, the page a phone shows the board on, built into one file by
#      ../pages/build.py: its tests stop where seam.py's do on every stream;
#      it tells right streams from wrong ones, in 64-byte packets, with
#      WebCrypto's SHA-256; wrong pages are caught; in headless Chromium
#      against a stand-in board;
#   6. every log a phone gave back (board/*.txt): each stream's code,
#      minstret and digests, by seam.py and hashlib, and by the page.
#
# What none of it reaches: the chip running it, and a phone reading it; a
# pasted log is what one did, once.
#
# Needs Lean (tools/lean/setup.sh), the Hazard3 testbench
# (tools/hazard3/setup.sh), clang, lld, llvm-objcopy, cargo, python3 and node.
# Without Lean or the testbench it says SKIP. About ten minutes, most of it
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
$LEAN check proof/Seam.lean || FAILED=1
$LEAN mutants proof/Seam.lean || FAILED=1

SIM=$TOOLS/hazard3/sim.sh
source "$TOOLS/hazard3/shell/shell.sh"
if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! $SIM ready; then
    echo "SKIP  the differential and the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

work="$(mktemp -d)"
$LEAN exec proof/Seam.lean "$work/kernel.bin" > /dev/null
if cmp -s "$work/kernel.bin" kernel.bin && [[ "$(sha256sum kernel.bin | cut -d' ' -f1)" == "$(cut -d' ' -f1 kernel.sha256)" ]]; then
    pass "kernel.bin is what proof/Seam.lean writes, $(stat -c %s kernel.bin) bytes, and kernel.sha256 is its hash"
else
    fail "kernel.bin is what proof/Seam.lean writes"
fi
rm -rf -- "$work"
python3 differential/differential.py "$($LEAN exe rv32run)" || FAILED=1

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/vk26-alice-1.bin) of the 32768 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi
python3 "$TOOLS/hazard3/shell/uf2check.py" build/vk26-alice-1.uf2 build/vk26-alice-1.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 32768 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/vk26-alice-1.uf2 | cut -d' ' -f1)" == "$(cat vk26-alice-1.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 vk26-alice-1.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# Every stream on the RTL: STRM s code want minstret digests, then DONE 6.
got="$(shell_words build/sim.bin 400000000)"
if python3 - "$got" <<'PY'
import re, sys
sys.path.insert(0, ".")
from seam import outcome
words = sys.argv[1].split()
text = open("build/expect.h").read()
instret = [int(x) for x in re.search(r"INSTRET\[5\] = \{([^}]*)\}", text).group(1).split(",")]
wants = [int(x) for x in re.findall(r'^    \{"[^"]+", (\d+), \{', text, re.M)]
# tools/hazard3/shell/trng_sim.h's stand-in, DEVICE 0: 128 words from its LCG.
x, lcg = 222, []
for _ in range(128):
    x = (x * 1664525 + 1013904223) & 0xffffffff
    lcg.append(x)
trng = outcome([(lcg[i // 32] >> (i % 32)) & 1 for i in range(4096)])[0]
rows, i = [], 0
while i < len(words) and words[i] == "5354524d":
    rows.append([int(w, 16) for w in words[i + 1:i + 6]])
    i += 6
ok = len(rows) == 1 + len(wants) and words[i:] == ["444f4e45", f"{len(rows):08x}", "exit=0"]
for s, (k, code, want, n, digests) in enumerate(rows):
    w = trng if s == 0 else wants[s - 1]
    ok &= k == s and code == w and want == (0xffffffff if s == 0 else w) and n == instret[code]
    ok &= digests == (4 if code == 0 else code - 1)
print(f"the TRNG's stand-in: seam.py says {trng}; the RTL: {' '.join(str(r[1]) for r in rows)}")
sys.exit(0 if ok else 1)
PY
then
    pass "on the RTL the shell runs all six streams, SHA-256 answering HASH, each halting with seam.py's code and the RTL's count for it, each digest SHA-256's"
else
    fail "on the RTL the shell runs every stream to seam.py's code" "$got"
fi

# The page: one file, as a phone gets it; its own tests against seam.py's;
# its verdicts on streams right and wrong; in a browser.
if ! command -v node > /dev/null; then
    echo "SKIP  the page: node is not installed"
else
    python3 ../pages/build.py seam.html build/seam.html
    python3 fixtures.py build/page build/expect.h
    page_parses build/seam.html build
    page_findcdc build/seam.html
    if [[ "$(sed -n 's/^const SEAM_INSTRET = \[\(.*\)\];$/\1/p' seam.html | tr -d ' ')" == \
          "$(sed -n 's/^static const uint32_t INSTRET\[5\] = {\(.*\)};$/\1/p' build/expect.h | tr -d ' ')" ]]; then
        pass "the page's minstret for each code is expect.h's, the RTL's"
    else
        fail "the page's minstret for each code is expect.h's, the RTL's"
    fi
    shopt -s nullglob
    node page_test.mjs build/seam.html build/page board/*.txt || FAILED=1
    page_mutant "the run is reset at each window's edge" 's/      run = bits\[i\] === last ? run + 1 : 1;/      run = bits[i] === last \&\& i !== start ? run + 1 : 1;/' \
        seam.html node page_test.mjs @ build/page
    page_mutant "the adaptive proportion cutoff is 590" 's/SEAM_APT = 589/SEAM_APT = 590/' \
        seam.html node page_test.mjs @ build/page
    page_mutant "each window's reference is the stream's first sample" 's/const start = w \* SEAM_N, ref = bits\[start\];/const start = w * SEAM_N, ref = bits[0];/' \
        seam.html node page_test.mjs @ build/page
    page_mutant "a digest is never compared" "s/if (d\[w\] !== want) why.push/if (false) why.push/" \
        seam.html node page_test.mjs @ build/page
    page_mutant "minstret is not compared" 's/if (e.code <= SEAM_WINDOWS \&\& e.minstret !== SEAM_INSTRET\[e.code\])/if (false)/' \
        seam.html node page_test.mjs @ build/page
    page_mutant "a stream with a BITS line missing is judged anyway" 's/if (!p || p.some((x) => x === null)) {/if (!p) {/' \
        seam.html node page_test.mjs @ build/page
    if page_playwright; then
        node page_browser.mjs build/seam.html build/page/good.txt "12 of 12 streams judged right" 6 || FAILED=1
        node page_browser.mjs build/seam.html build/page/reset.txt "1 wrong" 6 || FAILED=1
    else
        echo "SKIP  the page in a browser: Playwright is not installed"
    fi
fi

# Every log a phone gave back, by seam.py and hashlib.
shopt -s nullglob
logs=(board/*.txt)
if (( ${#logs[@]} )); then
    python3 fixtures.py --board build/expect.h "${logs[@]}" || FAILED=1
else
    echo "SKIP  checking a phone's log: none recorded yet (board/*.txt)"
fi

# Wrong shells and wrong expectations: each is caught by the check it names.
TRNG_OK="5354524d 00000000 00000000 ffffffff 00011057 00000004 "
side_by_side_begin
side_by_side shell_mutant "kernel.sha256 is not kernel.bin's hash — check 1" expect.h \
    's/KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/KERNEL_SHA[32] = {0x00/' "4641494c 00000001 00000000 "
side_by_side shell_mutant "the seam stream is said to pass — check 2" expect.h \
    's/^    {"seam 11+10", 2, {/    {"seam 11+10", 0, {/' "${TRNG_OK}4641494c 00000002 00000002 "
side_by_side shell_mutant "the chip is asked to count one more for code 2 — check 3" expect.h \
    's/^\(static const uint32_t INSTRET\[5\] = {[0-9]*, [0-9]*, \)34859,/\134860,/' "${TRNG_OK}4641494c 00000003 0000882b "
side_by_side shell_mutant "HASH writes its digest a word late — check 4" shell.c \
    's/(uint8_t \*)x\[12\]);/(uint8_t *)x[12] + 4);/' "4641494c 00000004 00000000 "
side_by_side shell_mutant "HASH hashes 64 bytes too few — check 4" shell.c \
    's/hash_ok \&= board_hash((const uint8_t \*)x\[10\], x\[11\],/hash_ok \&= board_hash((const uint8_t *)x[10], x[11] - 64,/' \
    "4641494c 00000004 00000000 "
side_by_side shell_mutant "the samples go in a word late — check 4, at gen.py's digest" shell.c \
    's/w\[SAMPLES \/ 4 + i\] = /w[SAMPLES \/ 4 + 1 + i] = /' "*4641494c 00000004 *"
side_by_side shell_mutant "the shell itself traps in step 3 — a fault, not a check" shell.c \
    's/^    step = 3;$/    step = 3;\n    __asm__ volatile (".word 0");/' "4641554c 00000003 00000002 "
side_by_side_end

exit "$FAILED"
