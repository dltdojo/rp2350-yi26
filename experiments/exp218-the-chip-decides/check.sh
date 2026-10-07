#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp218 quick check — the half that needs no board.
#
#   1. shell/cases.h is what model/Cases.lean writes: each case's words
#      through lean/Pio's proved encode, and what lean/Pio/Machine.lean says
#      the chip holds when the case has stopped;
#   2. expected.txt is what expected.py makes of those cases: every register
#      write the protocol asks for, in order;
#   3. the shell builds for the chip, into the first 16 KiB of flash, and its
#      UF2 reads back as built — byte for byte the committed one when the
#      toolchain is the recorded one;
#   4. on the Hazard3 RTL, which has no PIO, the shell writes exactly
#      expected.txt, and against six stand-ins — one that holds what the
#      model says, five that do not — names the cases each differs on;
#      wrong shells are caught.
#
# Whether the chip holds what the model says is the board's: a person reads
# the LED.
#
# Needs Lean (tools/lean/setup.sh), the Hazard3 testbench
# (tools/hazard3/setup.sh), clang, lld, llvm-objcopy, cargo and python3.
# Without them it says SKIP. About a minute.
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

if [[ "$($LEAN version 2>&1)" != Lean* ]]; then
    echo "SKIP  shell/cases.h against Lean: needs tools/lean/setup.sh"
else
    work="$(mktemp -d)"
    if $LEAN exec model/Cases.lean header "$work/cases.h" > /dev/null && cmp -s "$work/cases.h" shell/cases.h; then
        pass "shell/cases.h is what model/Cases.lean writes: $(grep -c '^    { ' shell/cases.h) cases, each stopping in the model"
    else
        fail "shell/cases.h is what model/Cases.lean writes" "Lean wrote something else, or no case stopped"
    fi
    rm -rf -- "$work"
fi
if python3 expected.py shell/cases.h | cmp -s - expected.txt; then
    pass "expected.txt is what expected.py makes of shell/cases.h: $(grep -vc '^#' expected.txt) writes"
else
    fail "expected.txt is what expected.py makes of shell/cases.h"
fi

SIM=../../tools/hazard3/sim.sh
source ../../tools/hazard3/shell/shell.sh
if ! $SIM ready; then
    echo "SKIP  the shell: needs tools/hazard3/setup.sh"
    exit "$FAILED"
fi

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/exp218.bin) of the 16384 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi
python3 ../../tools/hazard3/shell/uf2check.py build/exp218.uf2 build/exp218.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 16384 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp218.uf2 | cut -d' ' -f1)" == "$(cat exp218.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp218.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

DEVICES=(0 1 2 3 4 5)
WANT="0: writes ok 52455054 00000000 00000000 exit=0
1: writes differ at 19 52534554 00000000 exit=2
2: writes ok 52455054 00000002 00000200 exit=1
3: writes ok 52455054 00001000 00000040 exit=1
4: writes ok 52455054 00020000 00000800 exit=1
5: writes ok 52455054 000fffff 00000002 exit=1"
got="$(shell_stand_ins shell expected.txt "${DEVICES[@]}")"
said=(
    "a PIO that holds what the model says: every register written as expected.txt says, in order, and no case differs"
    "a PIO that never leaves reset: said so before case 1, after the pads and the reset and nothing more"
    "one that pushes on case 2's push iffull: case 2 alone, on what RX held at the first stop"
    "one whose pins stop at GPIO31: case 13 alone, on the pins"
    "one that never hands a word out in case 18: case 18 alone, on the words that never came"
    "one whose X is wrong everywhere: all 20 cases, the first on X"
)
for d in "${DEVICES[@]}"; do
    line="$(sed -n "$((d + 1))p" <<< "$got")"
    if [[ "$line" == "$(sed -n "$((d + 1))p" <<< "$WANT")" ]]; then
        pass "on the RTL, against ${said[$d]}"
    else
        fail "on the RTL, against ${said[$d]}" "$line"
    fi
done

# Wrong shells: each must change what the six runs say.
wrong() { shell_caught "$1" "$2" "$3" "$got" expected.txt "${DEVICES[@]}"; }
wrong "PIO0 is not reset between cases" shell.c '/^    wr(RESETS_RESET_SET, RESET_PIO0);$/d'
wrong "GPIO2..9 are pulled the other way" shell.c 's/? PADS_PUE : PADS_PDE;/? PADS_PDE : PADS_PUE;/'
wrong "what RX holds at the first stop is not taken" shell.c 's/^    uint32_t n1 = drain(rx1);$/    uint32_t n1 = 0; (void)drain;/'
wrong "the second batch is never written" shell.c '/^    for (uint32_t i = 0; i < c->ntx2; i++) wr(PIO_TXF0, c->tx2\[i\]);$/d'
wrong "Y is read where X should be" shell.c 's/uint32_t x = pull_out(I_MOV_ISR_X, &lost);/uint32_t x = pull_out(I_MOV_ISR_Y, \&lost);/'
wrong "the RX lists are not compared word by word" shell.c 's/^        if (got\[i\] != want\[i\]) return 0;$/        (void)got; (void)want;/'
wrong "a word that never comes out is not counted" shell.c 's/^    if (lost) differ |= 1u << 11;$/    (void)lost;/'
wrong "only the first case is run" shell.c 's/for (uint32_t k = 0; k < NCASES; k++)/for (uint32_t k = 0; k < 1; k++)/'

exit "$FAILED"
