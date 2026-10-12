#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp232 quick check — everything that needs no board.
#
#   1. the proof checks, on Lean's own axioms only: the kernel, from base,
#      halts with 0 after exactly 3081 instructions having written 64
#      generations of the model (M1); a dose reaches only the edges, spares a
#      healthy body and kills tissue beside a tumour (M2); untreated, any
#      tumour fills the ring by 31 (M3); the search's answer meets the
#      endpoint for every enrolled patient and the tumour is gone from 24 on
#      (M4); the first loophole meets it too, and a lump of six comes back
#      (M5) — and every wrong kernel and wrong claim in proof/mutants.txt is
#      refused;
#   2. kernel.bin is what the proof writes, its SHA-256 the committed one; on
#      the model and the RTL it leaves exactly cure.py's 64 generations, cure.py
#      being the rule written cell by cell;
#   3. the shell builds for the chip over speak.h and trng.h into the first 16
#      KiB of flash, and its UF2 reads back as built, byte for byte the
#      committed one when the toolchain is the recorded one;
#   4. on the RTL the shell runs the whole search and six patients exactly as
#      cure.py says, the protocol's SHA-256 included; wrong shells are caught by
#      the check each breaks;
#   5. every log a board gave back (board/*.txt) is cure.py's, line by line,
#      and a log with one thing changed is refused.
#
# What none of it reaches: the TRNG drawing the patients, the board sending
# them, and a person reading the trial off the LED and a phone.
#
# Needs clang, lld, llvm-objcopy, Lean, the Hazard3 testbench, cargo and
# python3. About five minutes, most of it the RTL searching.
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
$LEAN check proof/Cure.lean || FAILED=1
$LEAN mutants proof/Cure.lean || FAILED=1

if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! ../../tools/hazard3/sim.sh ready; then
    echo "SKIP  kernel.bin, the differential and the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi
work="$(mktemp -d)"
$LEAN exec proof/Cure.lean "$work/kernel.bin" > /dev/null
if cmp -s "$work/kernel.bin" kernel.bin && [[ "$(sha256sum kernel.bin | cut -d' ' -f1)" == "$(cat kernel.sha256)" ]]; then
    pass "kernel.bin is what proof/Cure.lean writes, $(stat -c %s kernel.bin) bytes, and kernel.sha256 is its hash"
else
    fail "kernel.bin is what proof/Cure.lean writes"
fi
rm -rf -- "$work"
python3 differential/differential.py "$($LEAN exe rv32run)" || FAILED=1

S=../../tools/hazard3/shell
source "$S/shell.sh"
if ./build.sh > /dev/null; then
    pass "the shell builds for the chip over speak.h and trng.h, in $(stat -c %s build/exp232.bin) of the 16384 bytes it may use, and for the RTL"
else
    fail "the shell builds"
    exit 1
fi
python3 "$S/uf2check.py" build/exp232.uf2 build/exp232.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 16384 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp232.uf2 | cut -d' ' -f1)" == "$(cat exp232.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp232.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# The search, then six patients from trng_sim.h's words — each as cure.py has it.
want="$(python3 - <<'PY'
from cure import CANDIDATES, lcg_words, patient_words, search
from gen import plan
import re
instret = int(re.search(r"#define INSTRET (\d+)u", open("build/cure.h").read()).group(1))
answer, accepted, relapsing, loophole = search()
w = [0x48435253, CANDIDATES, accepted, relapsing, answer, loophole, instret, 0x4e414c50]
p = plan(answer)
w += [int.from_bytes(p[i:i + 4], "big") for i in range(0, 32, 4)]
for n, r in enumerate(lcg_words(6), 1):
    w += [0x544e5450] + patient_words(n, r, answer)
print(" ".join(f"{v:08x}" for v in w) + " exit=0 ")
PY
)"
got="$(shell_words build/sim.bin 400000000)"
if [[ "$got" == "$want" ]]; then
    pass "on the RTL the shell's search finds cure.py's answer, $(sed -n 's/#define ANSWER 0x\([0-9a-f]*\)u/\1/p' build/cure.h), and its counts — $(sed -n 's/#define ACCEPTED \([0-9]*\)u/\1/p' build/cure.h) accepted, $(sed -n 's/#define RELAPSING \([0-9]*\)u/\1/p' build/cure.h) of them relapsing in the model — then hashes the protocol and treats six patients, model and world, exactly as cure.py does"
else
    fail "on the RTL the shell searches and treats as cure.py does" "$got"
fi

# Wrong shells and wrong expectations: each is caught by the check it names.
export MUTANT_EXPECT=build/cure.h
side_by_side_begin
side_by_side shell_mutant "the kernel is held to a hash that is not its own — check 1" cure.h \
    's/KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/KERNEL_SHA[32] = {0x00/' "4641494c 00000001 "
side_by_side shell_mutant "a run's halt is held to 1 instead of 0 — check 2" shell.c \
    's/xr\[10\] != 0) board_fail(2/xr[10] != 1) board_fail(2/' "4641494c 00000002 "
side_by_side shell_mutant "the chip is asked to count one more — check 3" cure.h \
    's/#define INSTRET \([0-9]*\)u/#define INSTRET 1\1u/' "4641494c 00000003 "
side_by_side shell_mutant "the search keeps the most doses, not the fewest — check 4" shell.c \
    's/pc(cand) < pc(sr.answer)/pc(cand) > pc(sr.answer)/' "4641494c 00000004 "
side_by_side shell_mutant "the world's tumour grows down while the proved model's grows up — check 10" shell.c \
    's/uint32_t t2 = t1 | up1(t1);/uint32_t t2 = t1 | dn1(t1);/' "*4641494c 0000000a "
side_by_side shell_mutant "the TRNG gives nothing — check 11" board_sim.c \
    's/^#include "trng_sim.h"$/#define DEVICE 2\n#include "trng_sim.h"/' "*4641494c 0000000b "
side_by_side shell_mutant "the shell itself traps entering the kernel — a fault, not a check" shell.c \
    's/^    step = phase ? 7 : 3;$/    step = phase ? 7 : 3;\n    __asm__ volatile (".word 0");/' "4641554c 00000003 00000002 "
side_by_side_end

# What a board sent, against cure.py: SEARCH and PLAN, every patient's model,
# its world replayed from its word (or, before the second build put the word
# in the line, the model's wherever the world cannot differ from it), every
# TRIAL count. And a log with one thing changed must be refused.
shopt -s nullglob
logs=(board/*.txt)
if (( ${#logs[@]} )); then
    python3 cure.py --board "${logs[@]}" || FAILED=1
    work="$(mktemp -d)"
    for fe in 'round1:s/ tissue=26 t64=0$/ tissue=25 t64=0/' 'round1:s/sha256=4cccf5ca/sha256=4cccf5cb/' \
              'round1:s/control=8 control_missed=8/control=8 control_missed=7/' \
              'round1:s/n=8 arm=treated width=1 at=23 model=cured/n=8 arm=treated width=1 at=23 model=missed/' \
              'round2:s/resistant=1 t24=19 tissue=13/resistant=1 t24=18 tissue=13/' \
              'round2:s/word=2e8b3fbd/word=2e8b3fbc/'; do
        f="board/${fe%%:*}.txt" e="${fe#*:}"
        sed "$e" "$f" > "$work/changed.txt"
        if cmp -s "$work/changed.txt" "$f"; then
            fail "a board log with one thing changed is refused" "the sed changed nothing: $e"
        elif python3 cure.py --board "$work/changed.txt" > /dev/null; then
            fail "a board log with one thing changed is refused" "accepted: $e"
        else
            pass "a board log with one thing changed is refused: $e"
        fi
    done
    rm -rf -- "$work"
else
    echo "SKIP  checking a board's log: none recorded yet (board/*.txt)"
fi

exit "$FAILED"
