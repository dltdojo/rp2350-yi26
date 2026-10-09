#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp225 quick check — the half that needs no board.
#
#   1. proof/Life.lean checks, on Lean's own axioms: the kernel halts with 0
#      after exactly 3079 instructions, having written 256 generations of Rule
#      30 from the seed and nothing else, and not before; `life` is Rule 30
#      cell by cell; wrong kernels and wrong claims are refused; kernel.bin is
#      the bytes it writes;
#   2. the differential: on twenty seeds the Lean model and the Hazard3 RTL
#      leave exactly rule30.py's generations, Rule 30 written cell by cell;
#   3. the shell builds for the chip, into the first 8 KiB of flash, and its
#      UF2 reads back as built — byte for byte the committed one when the
#      toolchain is the recorded one;
#   4. on the RTL the shell lives two lives, each exactly rule30.py's, the
#      second seeded by the first's last generation; wrong shells are caught.
#
# Whether the chip agrees is the board's: a person watches the LED.
#
# Needs Lean (tools/lean/setup.sh), the Hazard3 testbench
# (tools/hazard3/setup.sh), clang, lld, llvm-objcopy, cargo and python3.
# Without them it says SKIP. Under a minute.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=3
LIFELINE="no: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back"
presence_check
lifeline_check

USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

LEAN=../../tools/lean/lean.sh

$LEAN check proof/Life.lean || FAILED=1
$LEAN mutants proof/Life.lean || FAILED=1

SIM=../../tools/hazard3/sim.sh
source ../../tools/hazard3/shell/shell.sh
if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! $SIM ready; then
    echo "SKIP  the differential and the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

work="$(mktemp -d)"
$LEAN exec proof/Life.lean "$work/kernel.bin" > /dev/null
if cmp -s "$work/kernel.bin" kernel.bin && [[ "$(sha256sum kernel.bin | cut -d' ' -f1)" == "$(cat kernel.sha256)" ]]; then
    pass "kernel.bin is what proof/Life.lean writes, $(stat -c %s kernel.bin) bytes, and kernel.sha256 is its hash"
else
    fail "kernel.bin is what proof/Life.lean writes"
fi
rm -rf -- "$work"
python3 differential/differential.py "$($LEAN exe rv32run)" || FAILED=1

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/exp225.bin) of the 8192 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi
python3 ../../tools/hazard3/shell/uf2check.py build/exp225.uf2 build/exp225.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 8192 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp225.uf2 | cut -d' ' -f1)" == "$(cat exp225.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp225.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# Two lives on the RTL: LIFE round minstret gen1 gen256 centre-column — each
# from rule30.py, the second from the first's last generation.
want="$(python3 - <<'PY'
import re
from rule30 import SEED0, history
instret = int(re.search(r"#define INSTRET (\d+)u", open("build/expect.h").read()).group(1))
out, seed = [], SEED0
for r in range(2):
    h = history(seed)
    col = sum(((h[g] >> 16) & 1) << g for g in range(32))
    out += ["4c494645", f"{r:08x}", f"{instret:08x}", f"{h[0]:08x}", f"{h[-1]:08x}", f"{col:08x}"]
    seed = h[-1]
print(" ".join(out) + " exit=0 ")
PY
)"
got="$(shell_words build/sim.bin)"
if [[ "$got" == "$want" ]]; then
    pass "on the RTL the shell lives two lives, each exactly rule30.py's, the second seeded by the first's last generation"
else
    fail "on the RTL the shell lives two lives as rule30.py does" "$got"
fi

# Wrong shells and wrong expectations: each is caught by the check it names.
side_by_side_begin
side_by_side shell_mutant "kernel.sha256 is not kernel.bin's hash — check 1" expect.h \
    's/KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/KERNEL_SHA[32] = {0x00/' "4641494c 00000001 "
side_by_side shell_mutant "the halt is held to 1 instead of 0 — check 2" shell.c \
    's/x\[10\] != 0) board_fail/x[10] != 1) board_fail/' "4641494c 00000002 "
side_by_side shell_mutant "the chip is asked to count one more — check 3" expect.h \
    's/#define INSTRET \([0-9]*\)u/#define INSTRET 1\1u/' "4641494c 00000003 "
side_by_side shell_mutant "the first life is held against a hash that is not rule30.py's — check 4" expect.h \
    's/HIST_SHA\[32\] = {0x[0-9a-f][0-9a-f]/HIST_SHA[32] = {0x00/' "4641494c 00000004 "
side_by_side shell_mutant "the first life starts from two live cells, not one — check 4" expect.h \
    's/#define SEED0 0x10000u/#define SEED0 0x10001u/' "4641494c 00000004 "
side_by_side shell_mutant "the shell itself traps in step 3 — a fault, not a check" shell.c \
    's/^    step = 3;$/    step = 3;\n    __asm__ volatile (".word 0");/' "4641554c 00000003 00000002 "
side_by_side_end

exit "$FAILED"
