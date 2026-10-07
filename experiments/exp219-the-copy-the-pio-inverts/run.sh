#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp219 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh
source ../../tools/hazard3/shell/shell.sh

{
capture_header "exp219 — the copy the PIO inverts"

echo ">>> the shell, for the chip and for the RTL"
./build.sh
echo

echo ">>> what the chip is held to (build/expect.h, without the image)"
grep -E "^#define (KERNEL_LEN|SRC_OFF|DST_OFF|EXPECT_INSTRET|PROGRAM_LEN)|^// |^static const uint16_t PROGRAM|^static const uint32_t ANSWERS" build/expect.h
echo

echo ">>> on the RTL, the kernel for real and a stand-in PIO that works: REPT verdict failed minstret a0 cause word"
shell_words build/sim.bin
echo
echo

echo ">>> the checks"
./check.sh
} 2>&1 | tee capture.txt
