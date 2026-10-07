#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp220 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh
source ../../tools/hazard3/shell/shell.sh

{
capture_header "exp220 — either order"

echo ">>> the shell, for the chip and for the RTL"
./build.sh
echo

echo ">>> what the chip is held to (build/expect.h, without the image)"
grep -E "^#define (KERNEL_LEN|SRC_OFF|DST_OFF|EXPECT_INSTRET|PROGRAM_LEN)|^// |^static const uint16_t (INVERT|REVERSE)|^static const uint32_t (INVERTED|REVERSED|ANSWERS)" build/expect.h
echo

echo ">>> on the RTL, the kernel for real and stand-ins for PIO0 and PIO1 that work: REPT verdict failed minstret a0 cause word block"
shell_words build/sim.bin
echo
echo

echo ">>> the checks"
./check.sh
} 2>&1 | tee capture.txt
