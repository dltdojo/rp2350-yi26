#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp219 quick check — the half that needs no board.
#
#   1. the bytes on each side are the ones a theorem is about: kernel.bin is
#      exp203's, by its kernel.sha256, and its proof still checks; the PIO
#      words are exp217's `prog`, and its proof still checks;
#   2. the shell builds for the chip, into the first 8 KiB of flash, and its
#      UF2 reads back as built — byte for byte the committed one when the
#      toolchain is the recorded one;
#   3. on the Hazard3 RTL the kernel runs for real and the shell's verdict is
#      ok against a PIO stand-in that works; against five that do not, each
#      gets its own verdict; wrong shells are caught.
#
# Whether PIO0 and the copy kernel do it together on silicon is the board's:
# a person reads the LED.
#
# Needs Lean (tools/lean/setup.sh), the Hazard3 testbench
# (tools/hazard3/setup.sh), clang, lld, llvm-objcopy, cargo and python3.
# Without them it says SKIP. A few minutes, most of it the two proofs.
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
EXP203=../exp203-the-count-the-proof-promised
EXP217=../exp217-the-words-the-model-inverts

$LEAN check "$EXP203/proof/Copy64.lean" || FAILED=1
$LEAN check "$EXP217/proof/Invert.lean" || FAILED=1

SIM=../../tools/hazard3/sim.sh
source ../../tools/hazard3/shell/shell.sh
if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! $SIM ready; then
    echo "SKIP  the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/exp219.bin) of the 8192 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi
if grep -q "^// exp217's \`prog\`: 80a0 a0cf 8020$" build/expect.h; then
    pass "the PIO words are exp217's prog, the ones its theorems are about: 80a0 a0cf 8020"
else
    fail "the PIO words are exp217's prog" "$(grep "prog" build/expect.h)"
fi
python3 ../../tools/hazard3/shell/uf2check.py build/exp219.uf2 build/exp219.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 8192 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp219.uf2 | cut -d' ' -f1)" == "$(cat exp219.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp219.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# The RTL: REPT verdict failed minstret a0 cause word.
work="$(mktemp -d)"
said=(
    "a PIO that works: the kernel halts with 0 after minstret 108, then all 16 words come back complemented — ok"
    "a PIO that never leaves reset: verdict 2, before the kernel runs"
    "one already holding a word while the kernel runs: verdict 3, after it halts"
    "one that never answers: verdict 4 on the first word"
    "one that hands each word back as it was: verdict 5 on the first word"
    "one that leaves a word in RX: verdict 6, after all 16"
)
want=(
    "52455054 00000000 00000000 0000006c 00000000 00000008 0000000f exit=0 "
    "52455054 00000002 00000000 00000000 00000000 00000000 00000000 exit=2 "
    "52455054 00000003 00000000 0000006c 00000000 00000008 00000000 exit=3 "
    "52455054 00000004 00000000 0000006c 00000000 00000008 00000000 exit=4 "
    "52455054 00000005 00000000 0000006c 00000000 00000008 00000000 exit=5 "
    "52455054 00000006 00000000 0000006c 00000000 00000008 0000000f exit=6 "
)
for d in 0 1 2 3 4 5; do
    ./build.sh sim shell build "$work/s$d" "$d" 2> /dev/null
    got="$(shell_words "$work/s$d.bin")"
    if [[ "$got" == "${want[$d]}" ]]; then pass "on the RTL, against ${said[$d]}"
    else fail "on the RTL, against ${said[$d]}" "$got"; fi
done
rm -rf -- "$work"

# Wrong shells and wrong expectations: each must be caught, against the PIO
# stand-in that works.
shell_mutant "kernel.sha256 is not kernel.bin's hash — verdict 1, check 1" expect.h \
    's/KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/KERNEL_SHA[32] = {0x00/' "52455054 00000001 00000001 "
shell_mutant "the model's region hash is not the model's — verdict 1, check 6" expect.h \
    's/REGION_SHA\[32\] = {0x[0-9a-f][0-9a-f]/REGION_SHA[32] = {0x00/' "52455054 00000001 00000006 "
shell_mutant "the chip is asked to count 107 — verdict 1" expect.h \
    's/#define EXPECT_INSTRET 108u/#define EXPECT_INSTRET 107u/' "52455054 00000001 00000000 "
shell_mutant "the answers are the words themselves, not their complements — verdict 5" expect.h \
    's/ANSWERS\[16\] = {0x[0-9a-f]\{8\}u/ANSWERS[16] = {0x00000000u/' "52455054 00000005 "
shell_mutant "the words go to PIO0 one word past where the kernel wrote them — verdict 5" shell.c \
    's/(REGION + DST_OFF);/(REGION + DST_OFF + 4);/' "52455054 00000005 "
shell_mutant "the shell itself traps in step 3 — a fault, not a verdict" shell.c \
    's/^    step = 3;$/    step = 3;\n    __asm__ volatile (".word 0");/' "4641554c 00000003 00000002 "

exit "$FAILED"
