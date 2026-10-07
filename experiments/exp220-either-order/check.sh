#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp220 quick check — the half that needs no board.
#
#   1. proof/Through.lean checks, on Lean's own axioms: the two PIO programs'
#      words, what each does to every list of words that fits, that each
#      waits on an empty TX, and that the two orders give the same words;
#      wrong versions are refused. exp203's proof of the kernel still checks;
#   2. the shell builds for the chip, into the first 8 KiB of flash, and its
#      UF2 reads back as built — byte for byte the committed one when the
#      toolchain is the recorded one;
#   3. on the Hazard3 RTL the kernel runs for real and the shell's verdict is
#      ok against stand-in blocks that work; against five that do not, each
#      gets its own verdict; wrong shells are caught.
#
# Whether the three do it together on silicon is the board's: a person reads
# the LED.
#
# Needs Lean (tools/lean/setup.sh), the Hazard3 testbench
# (tools/hazard3/setup.sh), clang, lld, llvm-objcopy, cargo and python3.
# Without them it says SKIP. A few minutes, most of it the mutants.
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

$LEAN check proof/Through.lean || FAILED=1
$LEAN mutants proof/Through.lean || FAILED=1
$LEAN check ../exp203-the-count-the-proof-promised/proof/Copy64.lean || FAILED=1

SIM=../../tools/hazard3/sim.sh
source ../../tools/hazard3/shell/shell.sh
if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! $SIM ready; then
    echo "SKIP  the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/exp220.bin) of the 8192 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi
if grep -q "^// words_invert: 80a0 a0cf 8020   (PIO0)$" build/expect.h && grep -q "^// words_reverse: 80a0 a0d7 8020   (PIO1)$" build/expect.h; then
    pass "PIO0 gets words_invert, exp217's prog, and PIO1 words_reverse: 80a0 a0cf 8020 and 80a0 a0d7 8020"
else
    fail "the PIO words are the theorems'" "$(grep words_ build/expect.h)"
fi
python3 ../../tools/hazard3/shell/uf2check.py build/exp220.uf2 build/exp220.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 8192 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp220.uf2 | cut -d' ' -f1)" == "$(cat exp220.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp220.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# The RTL: REPT verdict failed minstret a0 cause word block.
work="$(mktemp -d)"
said=(
    "two blocks that work: the kernel halts with 0 at minstret 108, then all 16 words agree both ways — ok"
    "a PIO1 that never leaves reset: verdict 3, before the kernel runs"
    "a PIO1 that hands words back unreversed: verdict 7, on the first word"
    "a PIO0 right on its own and wrong the second way round: verdict 8, the orders disagreeing on the first word"
    "a PIO0 that never answers: verdict 5, on the first word, block 0"
    "a PIO1 that leaves a word in RX: verdict 9, block 1"
)
want=(
    "52455054 00000000 00000000 0000006c 00000000 00000008 0000000f 00000000 exit=0 "
    "52455054 00000003 00000000 00000000 00000000 00000000 00000000 00000000 exit=3 "
    "52455054 00000007 00000000 0000006c 00000000 00000008 00000000 00000001 exit=7 "
    "52455054 00000008 00000000 0000006c 00000000 00000008 00000000 00000000 exit=8 "
    "52455054 00000005 00000000 0000006c 00000000 00000008 00000000 00000000 exit=5 "
    "52455054 00000009 00000000 0000006c 00000000 00000008 0000000f 00000001 exit=9 "
)
for d in 0 1 2 3 4 5; do
    ./build.sh sim shell build "$work/s$d" "$d" 2> /dev/null
    got="$(shell_words "$work/s$d.bin")"
    if [[ "$got" == "${want[$d]}" ]]; then pass "on the RTL, against ${said[$d]}"
    else fail "on the RTL, against ${said[$d]}" "$got"; fi
done
rm -rf -- "$work"

# Wrong shells and wrong expectations, against the blocks that work.
shell_mutant "kernel.sha256 is not kernel.bin's hash — verdict 1, check 1" expect.h \
    's/KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/KERNEL_SHA[32] = {0x00/' "52455054 00000001 00000001 "
shell_mutant "the answers are only reversed, not complemented — verdict 8" expect.h \
    's/^static const uint32_t ANSWERS\[16\] = {0x[0-9a-f]\{8\}u/static const uint32_t ANSWERS[16] = {0x00000000u/' "52455054 00000008 "
shell_mutant "the shell itself traps in step 3 — a fault, not a verdict" shell.c \
    's/^    step = 3;$/    step = 3;\n    __asm__ volatile (".word 0");/' "4641554c 00000003 00000002 "

exit "$FAILED"
