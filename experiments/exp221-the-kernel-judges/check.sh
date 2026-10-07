#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp221 quick check — the half that needs no board.
#
#   1. proof/Same.lean checks, on Lean's own axioms: the kernel halts after
#      exactly 73 instructions with 0 when the two lists are the same and 1
#      when they are not, writing nothing; wrong kernels are refused; and
#      kernel.bin is the bytes it writes. exp220's proof of the two PIO
#      programs still checks;
#   2. the shell builds for the chip, into the first 8 KiB of flash, and its
#      UF2 reads back as built — byte for byte the committed one when the
#      toolchain is the recorded one;
#   3. on the Hazard3 RTL the kernel runs for real on what stand-in blocks
#      gave back: HALT 0 when they agree both ways, HALT 1 when the orders
#      disagree; the other stand-ins get their own verdicts; wrong shells are
#      caught.
#
# Whether the chip's blocks and the chip's CPU do it together is the board's:
# a person reads the LED.
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

$LEAN check proof/Same.lean || FAILED=1
$LEAN mutants proof/Same.lean || FAILED=1
$LEAN check ../exp220-either-order/proof/Through.lean || FAILED=1

SIM=../../tools/hazard3/sim.sh
source ../../tools/hazard3/shell/shell.sh
if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! $SIM ready; then
    echo "SKIP  the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

work="$(mktemp -d)"
$LEAN exec proof/Same.lean "$work/kernel.bin" > /dev/null
if cmp -s "$work/kernel.bin" kernel.bin && [[ "$(sha256sum kernel.bin | cut -d' ' -f1)" == "$(cat kernel.sha256)" ]]; then
    pass "kernel.bin is what proof/Same.lean writes, $(stat -c %s kernel.bin) bytes, and kernel.sha256 is its hash"
else
    fail "kernel.bin is what proof/Same.lean writes"
fi

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/exp221.bin) of the 8192 bytes it may use; the model halts after 73 both ways"
else
    fail "the shell builds"
    exit 1
fi
python3 ../../tools/hazard3/shell/uf2check.py build/exp221.uf2 build/exp221.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 8192 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp221.uf2 | cut -d' ' -f1)" == "$(cat exp221.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp221.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# The RTL: REPT verdict failed minstret a0 cause word block.
said=(
    "two blocks that work: the kernel, run for real, halts with 0 at minstret 76 — ok"
    "a PIO1 that never leaves reset: verdict 3, before anything is sent"
    "a PIO1 that hands words back unreversed: verdict 6, on the first word"
    "a PIO0 right on its own and wrong the second way round: the kernel, run for real, halts with 1 — verdict 7"
    "a PIO0 that never answers: verdict 4, on the first word"
    "a PIO1 that leaves a word in RX: verdict 8, before the kernel runs"
)
want=(
    "52455054 00000000 00000000 0000004c 00000000 00000008 0000000f 00000000 exit=0 "
    "52455054 00000003 00000000 00000000 00000000 00000000 00000000 00000000 exit=3 "
    "52455054 00000006 00000000 00000000 00000000 00000000 00000000 00000001 exit=6 "
    "52455054 00000007 00000000 0000004c 00000001 00000008 0000000f 00000000 exit=7 "
    "52455054 00000004 00000000 00000000 00000000 00000000 00000000 00000000 exit=4 "
    "52455054 00000008 00000000 00000000 00000000 00000000 0000000f 00000001 exit=8 "
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
shell_mutant "the chip is asked to count 75 — verdict 1" expect.h \
    's/#define EXPECT_INSTRET 76u/#define EXPECT_INSTRET 75u/' "52455054 00000001 00000000 "
shell_mutant "the shell flips a bit of every word in the first list — the kernel, run for real, finds them different: verdict 7" shell.c \
    's/^        second\[i\] = through(PIO0, rev);$/        second[i] = through(PIO0, rev); first[i] ^= 1u;/' "52455054 00000007 "
shell_mutant "the shell itself traps in step 3 — a fault, not a verdict" shell.c \
    's/^    step = 3;$/    step = 3;\n    __asm__ volatile (".word 0");/' "4641554c 00000003 00000002 "

exit "$FAILED"
