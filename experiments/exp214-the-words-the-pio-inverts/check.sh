#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp214 quick check — the half that needs no board.
#
#   1. invert.pio assembles, with pioasm, to the words shell/pio.h encodes by
#      hand from the datasheet;
#   2. the shell builds for the chip, into flash sector 0, and its UF2 is
#      what tools/hazard3/shell/uf2check.py reads back — byte for byte the
#      committed one when the toolchain is the recorded one;
#   3. on the Hazard3 RTL, which has no PIO, the shell writes exactly
#      expected.txt — every register, in order — and reports ok against a
#      stand-in that works; and against five stand-ins that fail, each in its
#      own way, it reports that way;
#   4. wrong shells are each caught by (3).
#
# Whether PIO0 really hands the words back complemented is the board's: a
# person reads the LED. Nothing here simulates PIO.
#
# Needs tools/pioasm/setup.sh for (1) and the Hazard3 testbench
# (tools/hazard3/setup.sh), clang, lld, llvm-objcopy and cargo for the rest.
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

PIOASM=../../tools/pioasm/pioasm-2.3.1/pioasm
if [[ ! -x "$PIOASM" ]]; then
    echo "SKIP  invert.pio against pioasm: needs tools/pioasm/setup.sh"
else
    asm="$("$PIOASM" -o hex invert.pio | tr '\n' ' ')"
    hand="$(sed -n 's/^static const uint16_t PROGRAM\[PROGRAM_LEN\] = {\(.*\)};.*/\1/p' shell/pio.h |
        tr -d ' ' | tr ',' '\n' | sed 's/^0x//' | tr '\n' ' ')"
    if [[ -n "$asm" && "$asm" == "$hand" ]]; then
        pass "invert.pio is the words shell/pio.h encodes by hand: pioasm says ${asm% }"
    else
        fail "invert.pio is the words shell/pio.h encodes by hand" "pioasm '$asm', by hand '$hand'"
    fi
fi

SIM=../../tools/hazard3/sim.sh
source ../../tools/hazard3/shell/shell.sh
if ! $SIM ready; then
    echo "SKIP  the shell: needs tools/hazard3/setup.sh"
    exit "$FAILED"
fi

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/exp214.bin) of sector 0's 4096 bytes"
else
    fail "the shell builds"
    exit 1
fi
python3 ../../tools/hazard3/shell/uf2check.py build/exp214.uf2 build/exp214.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp214.uf2 | cut -d' ' -f1)" == "$(cat exp214.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp214.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# What a shell in DIR says against each stand-in, one run per line.
stand_ins() { # dir
    local work d
    work="$(mktemp -d)"
    for d in 0 1 2 3 4 5; do
        ./build.sh sim "$1" "$d" "$work/sim$d" 2> /dev/null &&
            echo "$d: $(shell_words "$work/sim$d.bin" | python3 writes.py expected.txt)"
    done
    rm -rf -- "$work"
}

WANT="0: writes ok 52455054 00000000 00000000 exit=0 
1: writes differ at 2 52455054 00000001 00000000 exit=1 
2: writes differ at 10 52455054 00000002 00000000 exit=2 
3: writes differ at 10 52455054 00000003 00000000 exit=3 
4: writes differ at 17 52455054 00000004 deadbeef exit=4 
5: writes differ at 17 52455054 00000005 01000000 exit=5 "
got="$(stand_ins shell)"
said=(
    "a PIO that works: every register written as expected.txt says, in order, and ok"
    "one that never leaves reset: verdict 1, after the reset write and nothing more"
    "one that never answers: verdict 2 on the first word"
    "one that hands the word back unchanged: verdict 3 on the first word"
    "one that answers the last word wrongly: verdict 4 on deadbeef"
    "one that leaves a word in RX: verdict 5, FSTAT showing it"
)
for d in 0 1 2 3 4 5; do
    line="$(sed -n "$((d + 1))p" <<< "$got")"
    if [[ "$line " == "$(sed -n "$((d + 1))p" <<< "$WANT")" ]]; then
        pass "on the RTL, against ${said[$d]}"
    else
        fail "on the RTL, against ${said[$d]}" "$line"
    fi
done

# Wrong shells: each must change what the six runs say.
shell_wrong() { # what file sed
    local work
    work="$(mktemp -d)"
    cp -r shell "$work/shell"
    sed -i "$3" "$work/shell/$2"
    if cmp -s "$work/shell/$2" "shell/$2"; then
        fail "the RTL runs catch a shell where $1" "the sed changed nothing"
    elif [[ "$(stand_ins "$work/shell")" != "$got" ]]; then
        pass "the RTL runs catch a shell where $1"
    else
        fail "the RTL runs catch a shell where $1" "every run said the same as the right shell's"
    fi
    rm -rf -- "$work"
}
shell_wrong "PIO1 is taken out of reset, not PIO0" pio.h 's/^#define RESET_PIO0         (1u << 11)$/#define RESET_PIO0         (1u << 12)/'
shell_wrong "the program wraps after its second instruction" shell.c 's/EXECCTRL_WRAP(0, PROGRAM_LEN - 1)/EXECCTRL_WRAP(0, PROGRAM_LEN - 2)/'
shell_wrong "SM0 is not sent to instruction 0 before it starts" shell.c '/^    wr(PIO_SM0_INSTR, JMP_0);$/d'
shell_wrong "mov isr, osr is loaded, without the complement" pio.h 's/{0x80a0, 0xa0cf, 0x8020}/{0x80a0, 0xa0c7, 0x8020}/'
shell_wrong "a wrong answer is not looked for" shell.c 's/^        if (r != ~w) board_report(V_WRONG, w);$/        (void)r;/'
shell_wrong "the FIFOs are not looked at at the end" shell.c 's/^        board_report(V_LEFTOVER, f);$/        (void)f;/'

exit "$FAILED"
