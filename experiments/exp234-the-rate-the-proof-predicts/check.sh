#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp234 quick check — everything that needs no board.
#
#   1. the proof checks, on Lean's own axioms only: the world's kernel, from
#      base, halts with 0 after exactly 4043 instructions having written 64
#      generations of the world, for every input and every mask (W1); with
#      every mask zero the world is exp232's proved model (W0); one resistant
#      cell and the tumour never goes (M6); cured at 64 exactly when the model
#      is and no mask hit a cell the model's tumour divided into (M7), and
#      under exp232's answer the enrolled lumps leave 0, 0, 1, 2, 3 and 8 such
#      cells; no tumour at all stays none (M8) — and every wrong kernel and
#      wrong claim in proof/mutants.txt is refused;
#   2. the D the proof states is cure.py's, lump by lump, and the rate it
#      predicts is exactly 3276629119 / 25769803776, 12.715%;
#   3. kernel.bin is what the proof writes, its SHA-256 the committed one; on
#      the model and the RTL it leaves exactly cure.py's world, written cell by
#      cell, for fifteen bodies and mask sets;
#   4. the shell builds for the chip over trial_chip.h into the first 16 KiB of
#      flash, and its UF2 reads back as built, byte for byte the committed one
#      when the toolchain is the recorded one;
#   5. on the RTL the shell runs the whole search and six patients, each as
#      two runs of the one kernel, exactly as cure.py says — exp232's lines,
#      number for number; wrong shells are caught by the check each breaks;
#   6. every log a board gave back (board/*.txt) is cure.py's, line by line.
#
# What none of it reaches: the TRNG's bits being independent ones that come up
# 1 time in 16 after the AND of four — the step from M7 to 12.715% — the board
# sending them, and anything about a body.
#
# Needs clang, lld, llvm-objcopy, Lean, the Hazard3 testbench, cargo and
# python3. About three minutes, most of it the RTL searching.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
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

LEAN=../../tools/lean/lean.sh
$LEAN check proof/World.lean || FAILED=1
$LEAN mutants proof/World.lean || FAILED=1
python3 world.py --check || FAILED=1

if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! ../../tools/hazard3/sim.sh ready; then
    echo "SKIP  kernel.bin, the differential and the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi
work="$(mktemp -d)"
$LEAN exec proof/World.lean "$work/kernel.bin" > /dev/null
if cmp -s "$work/kernel.bin" kernel.bin && [[ "$(sha256sum kernel.bin | cut -d' ' -f1)" == "$(cat kernel.sha256)" ]]; then
    pass "kernel.bin is what proof/World.lean writes, $(stat -c %s kernel.bin) bytes, and kernel.sha256 is its hash"
else
    fail "kernel.bin is what proof/World.lean writes"
fi
rm -rf -- "$work"
python3 differential/differential.py "$($LEAN exe rv32run)" || FAILED=1

S=../../tools/hazard3/shell
source "$S/shell.sh"
if ./build.sh > /dev/null; then
    pass "the shell builds for the chip over trial_chip.h, in $(stat -c %s build/exp234.bin) of the 16384 bytes it may use, and for the RTL"
else
    fail "the shell builds"
    exit 1
fi
python3 "$S/uf2check.py" build/exp234.uf2 build/exp234.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 16384 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp234.uf2 | cut -d' ' -f1)" == "$(cat exp234.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp234.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# The search, then six patients from trng_sim.h's words — each as cure.py has
# it, which is what exp232's shell printed for the same words.
want="$(python3 - <<'PY'
import re, sys
sys.path.insert(0, "../exp232-the-cure-the-proof-predicts")
from cure import CANDIDATES, lcg_words, patient_words, search
from gen import plan
instret = int(re.search(r"#define INSTRET (\d+)u", open("build/world.h").read()).group(1))
answer, accepted, relapsing, loophole = search()
w = [0x48435253, CANDIDATES, accepted, relapsing, answer, loophole, instret, 0x4e414c50]
p = plan(answer)
w += [int.from_bytes(p[i:i + 4], "big") for i in range(0, 32, 4)]
for n, r in enumerate(lcg_words(6), 1):
    w += [0x544e5450] + patient_words(n, r, answer)
print(" ".join(f"{v:08x}" for v in w) + " exit=0 ")
PY
)"
got="$(shell_words build/sim.bin 600000000)"
if [[ "$got" == "$want" ]]; then
    pass "on the RTL the shell's search, every run the world's kernel with every mask zero, finds cure.py's answer, $(sed -n 's/#define ANSWER 0x\([0-9a-f]*\)u/\1/p' build/world.h), and its counts; then it treats six patients, the model and the world each a run of the same kernel, exactly as cure.py does — minstret $(sed -n 's/#define INSTRET \([0-9]*\)u.*/\1/p' build/world.h) on every run"
else
    fail "on the RTL the shell searches and treats as cure.py does" "$got"
fi

# Wrong shells and wrong expectations: each is caught by the check it names.
export MUTANT_EXPECT=build/world.h
side_by_side_begin
side_by_side shell_mutant "the kernel is held to a hash that is not its own — check 1" world.h \
    's/KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/KERNEL_SHA[32] = {0x00/' "4641494c 00000001 "
side_by_side shell_mutant "a run's halt is held to 1 instead of 0 — check 2" shell.c \
    's/xr\[10\] != 0) board_fail(2/xr[10] != 1) board_fail(2/' "4641494c 00000002 "
side_by_side shell_mutant "the chip is asked to count one more — check 3" world.h \
    's/#define INSTRET \([0-9]*\)u/#define INSTRET 1\1u/' "4641494c 00000003 "
side_by_side shell_mutant "the search keeps the most doses, not the fewest — check 4" shell.c \
    's/pc(cand) < pc(sr.answer)/pc(cand) > pc(sr.answer)/' "4641494c 00000004 "
side_by_side shell_mutant "a patient's model run keeps the last patient's masks — check 10, W0" shell.c \
    's/world ? masks\[g\] : 0;/masks[g];/' "*4641494c 0000000a "
side_by_side shell_mutant "the shell reads resistance from the tissue's word — check 12, M6" shell.c \
    's/ever |= hist\[3 \* g + 2\];/ever |= hist[3 * g + 1];/' "*4641494c 0000000c "
side_by_side shell_mutant "the TRNG gives nothing — check 11" board_sim.c \
    's/^#include "trng_sim.h"$/#define DEVICE 2\n#include "trng_sim.h"/' "*4641494c 0000000b "
side_by_side shell_mutant "the shell itself traps entering the kernel — a fault, not a check" shell.c \
    's/^    step = phase ? 7 : 3;$/    step = phase ? 7 : 3;\n    __asm__ volatile (".word 0");/' "4641554c 00000003 00000002 "
side_by_side_end

# What a board sent, against cure.py: exp232's lines, so exp232's checker.
shopt -s nullglob
logs=(board/*.txt)
if (( ${#logs[@]} )); then
    python3 world.py --board "${logs[@]}" || FAILED=1
else
    echo "SKIP  checking a board's log: none recorded yet (board/*.txt)"
fi

exit "$FAILED"
