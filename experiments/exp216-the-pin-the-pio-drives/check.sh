#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp216 quick check — the half that needs no board.
#
#   1. the program's proof checks, on Lean's own axioms: its nine words are
#      what lean/Pio's proved encode makes, they read back as the program,
#      and every jump and the wrap are inside it; wrong versions are refused;
#   2. shell/program.h is what Lean writes, and drive.pio assembles, with
#      pioasm, to the same nine words;
#   3. the shell builds for the chip, into flash sector 0, and its UF2 reads
#      back as built — byte for byte the committed one when the toolchain is
#      the recorded one;
#   4. on the Hazard3 RTL, which has neither PIO nor GPIO, the shell writes
#      exactly expected.txt, and against seven stand-ins — one that works,
#      six that fail — gives each its verdict; wrong shells are caught.
#
# Whether PIO0 really drives GPIO25 is the board's: a person reads the LED.
#
# Needs Lean (tools/lean/setup.sh), pioasm (tools/pioasm/setup.sh), the
# Hazard3 testbench (tools/hazard3/setup.sh), clang, lld, llvm-objcopy and
# cargo. Without them it says SKIP. About a minute.
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
PIOASM=../../tools/pioasm/pioasm-2.3.1/pioasm

$LEAN check proof/Program.lean || FAILED=1
$LEAN mutants proof/Program.lean || FAILED=1

if [[ "$($LEAN version 2>&1)" != Lean* ]]; then
    echo "SKIP  shell/program.h against Lean: needs tools/lean/setup.sh"
else
    work="$(mktemp -d)"
    $LEAN exec proof/Program.lean header "$work/program.h" > /dev/null
    if cmp -s "$work/program.h" shell/program.h; then
        pass "shell/program.h is what proof/Program.lean writes through Lean's encode"
    else
        fail "shell/program.h is what proof/Program.lean writes" "Lean wrote something else"
    fi
    rm -rf -- "$work"
fi
if [[ ! -x "$PIOASM" ]]; then
    echo "SKIP  drive.pio against pioasm: needs tools/pioasm/setup.sh"
else
    asm="$("$PIOASM" -o hex drive.pio | tr '\n' ' ')"
    lean="$(sed -n 's/^static const uint16_t PROGRAM\[PROGRAM_LEN\] = {\(.*\)};.*/\1/p' shell/program.h |
        tr -d ' ' | tr ',' '\n' | sed 's/^0x//' | tr '\n' ' ')"
    if [[ -n "$asm" && "$asm" == "$lean" ]]; then
        pass "pioasm makes the same nine words of drive.pio as Lean's encode: ${asm% }"
    else
        fail "pioasm makes the same words of drive.pio as Lean's encode" "pioasm '$asm', Lean '$lean'"
    fi
fi

SIM=../../tools/hazard3/sim.sh
source ../../tools/hazard3/shell/shell.sh
if ! $SIM ready; then
    echo "SKIP  the shell: needs tools/hazard3/setup.sh"
    exit "$FAILED"
fi

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/exp216.bin) of sector 0's 4096 bytes"
else
    fail "the shell builds"
    exit 1
fi
python3 ../../tools/hazard3/shell/uf2check.py build/exp216.uf2 build/exp216.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp216.uf2 | cut -d' ' -f1)" == "$(cat exp216.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp216.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

DEVICES=(0 1 2 3 4 5 6)
WANT="0: writes ok 52455054 00000000 00000000 exit=0 
1: writes differ at 2 52455054 00000001 00000000 exit=1 
2: writes differ at 18 52455054 00000002 00000000 exit=2 
3: writes differ at 19 52455054 00000003 00000001 exit=3 
4: writes differ at 18 52455054 00000004 00000000 exit=4 
5: writes differ at 19 52455054 00000005 00000001 exit=5 
6: writes differ at 25 52455054 00000006 01000000 exit=6 "
got="$(shell_stand_ins shell expected.txt "${DEVICES[@]}")"
said=(
    "a PIO and pin that work: every register written as expected.txt says, in order, and ok"
    "a PIO that never leaves reset: verdict 1, after the reset write and nothing more"
    "one that never answers: verdict 2 on the first command"
    "one that answers the second command wrongly: verdict 3 on command 1 (from 0)"
    "a pin that stays at SIO's 1: verdict 4 on the first command, told 0"
    "a pin that stays at 0: verdict 5 on the second command, told 1"
    "one that leaves a word in RX: verdict 6, FSTAT showing it"
)
for d in "${DEVICES[@]}"; do
    line="$(sed -n "$((d + 1))p" <<< "$got")"
    if [[ "$line " == "$(sed -n "$((d + 1))p" <<< "$WANT")" ]]; then
        pass "on the RTL, against ${said[$d]}"
    else
        fail "on the RTL, against ${said[$d]}" "$line"
    fi
done

# Wrong shells: each must change what the seven runs say.
wrong() { shell_caught "$1" "$2" "$3" "$got" expected.txt "${DEVICES[@]}"; }
wrong "the pin is never handed to PIO0" shell.c '/^    wr(GPIO_CTRL(PIN), FUNCSEL_PIO0);$/d'
wrong "SET pins are mapped from GPIO24, not GPIO25" shell.c 's/wr(PIO_SM0_PINCTRL, PINCTRL_SET(PIN, 1));/wr(PIO_SM0_PINCTRL, PINCTRL_SET(PIN - 1, 1));/'
wrong "the wrap starts at 0, so set pindirs runs every time round" shell.c 's/EXECCTRL_WRAP(WRAP_BOTTOM, WRAP_TOP)/EXECCTRL_WRAP(0, WRAP_TOP)/'
wrong "the pin is not read back" shell.c 's/^        if (pin != c) board_report(c ? V_PIN : V_SIO, i);$/        (void)pin;/'
wrong "the answer is not looked at" shell.c 's/^        if (rd(PIO_RXF0) != c) board_report(V_ANSWER, i);$/        (void)rd(PIO_RXF0);/'
wrong "the pin is not given back to SIO at the end" shell.c '/^    wr(GPIO_CTRL(PIN), FUNCSEL_SIO);$/d'

exit "$FAILED"
