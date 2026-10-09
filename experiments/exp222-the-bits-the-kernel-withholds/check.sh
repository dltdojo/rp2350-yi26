#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp222 quick check — the half that needs no board.
#
#   1. proof/Health.lean checks, on Lean's own axioms: the kernel runs SP
#      800-90B's repetition count and adaptive proportion tests over 1024
#      samples exactly as exp114 has them, and halts with 1 after exactly
#      17427 instructions having written nothing, or with 0 after exactly
#      23574 having copied the samples to the output and nothing else;
#      wrong kernels are refused; kernel.bin is the bytes it writes;
#   2. the differential: on fourteen streams, edge cases among them, the
#      Lean model and the Hazard3 RTL halt as exp114's tests in Python say;
#   3. the shell builds for the chip, into the first 8 KiB of flash, and its
#      UF2 reads back as built — byte for byte the committed one when the
#      toolchain is the recorded one;
#   4. on the RTL the kernel runs for real on three sources from a stand-in
#      TRNG: a good one passes and both broken sources are withheld; a TRNG
#      giving all ones is withheld; one giving nothing is said so; wrong
#      shells are caught.
#
# Whether the chip's TRNG passes, and the chip does what the RTL does, is the
# board's: a person reads the LED.
#
# Needs Lean (tools/lean/setup.sh), the Hazard3 testbench
# (tools/hazard3/setup.sh), clang, lld, llvm-objcopy, cargo and python3.
# Without them it says SKIP. A few minutes, half of it the RTL runs.
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

$LEAN check proof/Health.lean || FAILED=1
$LEAN mutants proof/Health.lean || FAILED=1

SIM=../../tools/hazard3/sim.sh
source ../../tools/hazard3/shell/shell.sh
if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! $SIM ready; then
    echo "SKIP  the differential and the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

work="$(mktemp -d)"
$LEAN exec proof/Health.lean "$work/kernel.bin" > /dev/null
if cmp -s "$work/kernel.bin" kernel.bin && [[ "$(sha256sum kernel.bin | cut -d' ' -f1)" == "$(cat kernel.sha256)" ]]; then
    pass "kernel.bin is what proof/Health.lean writes, $(stat -c %s kernel.bin) bytes, and kernel.sha256 is its hash"
else
    fail "kernel.bin is what proof/Health.lean writes"
fi
python3 differential/differential.py "$($LEAN exe rv32run)" || FAILED=1

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/exp222.bin) of the 8192 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi
python3 ../../tools/hazard3/shell/uf2check.py build/exp222.uf2 build/exp222.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 8192 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp222.uf2 | cut -d' ' -f1)" == "$(cat exp222.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp222.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# The RTL: REPT verdict source failed a0 minstret cause.
said=(
    "a stand-in TRNG that works: its samples pass and are copied, both broken sources are withheld, each check as withholds says — ok"
    "a stand-in TRNG giving all ones: the kernel, run for real, withholds its samples at minstret 17430 — verdict 3"
    "a stand-in TRNG giving nothing: verdict 2, before the kernel runs"
)
want=(
    "52455054 00000000 00000003 00000000 00000000 00000000 00000000 exit=0 "
    "52455054 00000003 00000000 00000000 00000001 00004416 00000008 exit=3 "
    "52455054 00000002 00000000 00000000 00000000 00000000 00000000 exit=2 "
)
stand_in() { # device
    local d="$1" got
    ./build.sh sim shell build "$work/s$d" "$d" 2> /dev/null
    got="$(shell_words "$work/s$d.bin")"
    if [[ "$got" == "${want[$d]}" ]]; then pass "on the RTL, against ${said[$d]}"
    else fail "on the RTL, against ${said[$d]}" "$got"; fi
}

# Every RTL run below is on its own copy, so they run side by side; the lines
# come out in this order regardless.
side_by_side_begin
for d in 0 1 2; do side_by_side stand_in "$d"; done

# Wrong shells and wrong expectations, against the stand-in that works.
side_by_side shell_mutant "kernel.sha256 is not kernel.bin's hash — verdict 1, check 1" expect.h \
    's/KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/KERNEL_SHA[32] = {0x00/' "52455054 00000001 00000000 00000001 "
side_by_side shell_mutant "the chip is asked to count one more when healthy — verdict 1, check 3" expect.h \
    's/#define INSTRET_PASS 23578u/#define INSTRET_PASS 23579u/' "52455054 00000001 00000000 00000003 "
side_by_side shell_mutant "the broken source is nine ones then a zero no longer, but a fair alternation — it passes: verdict 4" shell.c \
    's/^    gather();$/    gather();\n    if (source == 2) for (uint32_t i = 0; i < N; i++) samples[i] = i % 2;/' "52455054 00000004 00000002 "
side_by_side shell_mutant "the output is not cleared before the region is hashed again — the region differs: verdict 1, check 5" shell.c \
    's/^            w\[OUT_OFF \/ 4 + i\] = 0;$/            (void)0;/' "52455054 00000001 00000000 00000005 "
side_by_side shell_mutant "the shell itself traps in step 3 — a fault, not a verdict" shell.c \
    's/^    step = 3;$/    step = 3;\n    __asm__ volatile (".word 0");/' "4641554c 00000003 00000002 "
side_by_side_end
rm -rf -- "$work"

exit "$FAILED"
