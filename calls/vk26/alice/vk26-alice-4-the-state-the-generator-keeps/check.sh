#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# vk26-alice-4 quick check — everything that needs no board.
#
#   1. proof/Drbg.lean checks, on Lean's own axioms: started at base with the
#      kernel's 280 bytes at the image's start and a state (V, C,
#      reseed_counter) whose counter is at most the interval, the kernel halts
#      with 0 after exactly COST m = 2030 + 566m instructions, the region
#      holding Hashgen's m blocks at 0x600 (after_out), V + H + C + counter,
#      the counter one more and nothing else changed (from_boot); a counter
#      past the interval halts with 1 after 7, memory untouched
#      (reseed_boot); started again on what the first left, the second
#      Generate's blocks are Hashgen of the next V (generate_twice). Wrong
#      kernels and wrong claims are refused; kernel.bin is what the proof
#      writes;
#   2. drbg.py, written from SP 800-90A's text, gives NIST's ReturnedBits for
#      all 120 SHA-256 cases without additional input; the Lean model and the
#      Hazard3 RTL generate all of them, twice each through the kernel's own
#      region, every region drbg.py's, and ten states chosen for their edges;
#   3. the shell builds for the chip, into the first 64 KiB of flash, and its
#      UF2 reads back as built — byte for byte the committed one when the
#      toolchain is the recorded one;
#   4. on the RTL the shell runs all 120 cases, three runs each: two
#      Generates, their minstret the RTL's and the second's bits NIST's, the
#      region drbg.py's; then the reseed check, HALT 1, nothing written;
#      wrong shells are caught.
#
# What none of it reaches: the chip's SHA-256 block on HASHB's lengths, 55
# and 56 bytes, which only a board runs — the board is what says whether
# board_chip.c's padding is right.
#
# Needs Lean (tools/lean/setup.sh), the Hazard3 testbench
# (tools/hazard3/setup.sh), clang, lld, llvm-objcopy, cargo and python3.
# Without Lean or the testbench it says SKIP. About six minutes, most of it
# the RTL.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

TOOLS=../../../../tools
source ../../../../experiments/lib.sh
require_supported_platform

LEAN=$TOOLS/lean/lean.sh
$LEAN check proof/Drbg.lean || FAILED=1
$LEAN mutants proof/Drbg.lean || FAILED=1

if python3 drbg.py > /dev/null; then
    pass "drbg.py gives NIST's ReturnedBits for all $(python3 -c 'import drbg; print(len(drbg.cavp_cases()))') cases"
else
    fail "drbg.py gives NIST's ReturnedBits" "$(python3 drbg.py)"
fi

SIM=$TOOLS/hazard3/sim.sh
source "$TOOLS/hazard3/shell/shell.sh"
if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! $SIM ready; then
    echo "SKIP  the differential and the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

work="$(mktemp -d)"
$LEAN exec proof/Drbg.lean "$work/kernel.bin" > /dev/null
if cmp -s "$work/kernel.bin" kernel.bin && [[ "$(sha256sum kernel.bin | cut -d' ' -f1)" == "$(cut -d' ' -f1 kernel.sha256)" ]]; then
    pass "kernel.bin is what proof/Drbg.lean writes, $(stat -c %s kernel.bin) bytes, and kernel.sha256 is its hash"
else
    fail "kernel.bin is what proof/Drbg.lean writes"
fi
rm -rf -- "$work"
python3 differential/differential.py "$($LEAN exe rv32run)" || FAILED=1

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/vk26-alice-4.bin) of the 65536 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi
python3 "$TOOLS/hazard3/shell/uf2check.py" build/vk26-alice-4.uf2 build/vk26-alice-4.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 65536 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/vk26-alice-4.uf2 | cut -d' ' -f1)" == "$(cat vk26-alice-4.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 vk26-alice-4.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# Every case on the RTL: CASE i, then minstret and mcycle of each of its three
# runs; then DONE 120.
got="$(shell_words build/sim.bin 400000000)"
if python3 - "$got" <<'PY'
import re, sys
words = sys.argv[1].split()
text = open("build/expect.h").read()
gen = int(re.search(r"#define INSTRET_GEN (\d+)u", text).group(1))
reseed = int(re.search(r"#define INSTRET_RESEED (\d+)u", text).group(1))
n = int(re.search(r"#define NCASES (\d+)", text).group(1))
rows, i = [], 0
while i < len(words) and words[i] == "43415345":
    rows.append([int(w, 16) for w in words[i + 1:i + 8]])
    i += 7 + 1
ok = len(rows) == n and words[i:] == ["444f4e45", f"{n:08x}", "exit=0"]
ok &= all(r[0] == k and r[1] == r[3] == gen and r[5] == reseed for k, r in enumerate(rows))
cycles = sorted({(r[2], r[4], r[6]) for r in rows})
ok &= len(cycles) == 1 and cycles[0][0] == cycles[0][1]
print(f"the RTL: {len(rows)} cases, minstret {gen} {gen} {reseed} each, mcycle (with HASHB in software) {cycles}")
sys.exit(0 if ok else 1)
PY
then
    pass "on the RTL the shell runs all 120 NIST cases: two Generates each, minstret the RTL's, the second's bits NIST's and the region drbg.py's; then HALT 1, reseed required, nothing written"
else
    fail "on the RTL the shell runs every case" "$got"
fi

# Wrong shells and wrong expectations: each is caught by the check it names.
side_by_side_begin
side_by_side shell_mutant "kernel.sha256 is not kernel.bin's hash — check 1" expect.h \
    's/KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/KERNEL_SHA[32] = {0x00/' "4641494c 00000001 00000000 "
side_by_side shell_mutant "HASHB is answered one byte short — check 4, NIST's bits" shell.c \
    's/board_hashb((const uint8_t \*)x\[10\], x\[11\], /board_hashb((const uint8_t *)x[10], x[11] - 1, /' \
    "4641494c 00000004 00000000 "
side_by_side shell_mutant "the counter starts at 2: the second Generate is refused — check 2" shell.c \
    's/put_word(r, PARAMS + 8, 1);/put_word(r, PARAMS + 8, 2);/' "4641494c 00000002 00000001 "
side_by_side shell_mutant "the interval is 3, not the one gen.py's region holds — check 4, after the second" expect.h \
    's/^#define INTERVAL 2$/#define INTERVAL 3/' "4641494c 00000004 00000002 "
side_by_side shell_mutant "the chip is asked to count one more instruction — check 3" expect.h \
    's/^#define INSTRET_GEN \([0-9]*\)u$/#define INSTRET_GEN 4319u/' "4641494c 00000003 000010de "
side_by_side shell_mutant "the number 1 is put in a byte early, as 256 — check 4" shell.c \
    's/r\[ONE + 54\] = 1;/r[ONE + 53] = 1;/' "4641494c 00000004 00000000 "
side_by_side shell_mutant "a byte past the window is left set — check 4, the region" shell.c \
    's/^    r\[ONE + 54\] = 1;$/    r[ONE + 54] = 1;\n    r[0x800] = 1;/' "4641494c 00000004 00000002 "
side_by_side shell_mutant "the shell itself traps in step 3 — a fault, not a check" shell.c \
    's/^    step = 3;$/    step = 3;\n    __asm__ volatile (".word 0");/' "4641554c 00000003 00000002 "
side_by_side_end

exit "$FAILED"
