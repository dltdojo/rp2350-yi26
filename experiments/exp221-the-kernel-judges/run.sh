#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp221 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh
source ../../tools/hazard3/shell/shell.sh

{
capture_header "exp221 — the kernel judges"

echo ">>> the kernel, as proof/Same.lean writes it"
../../tools/lean/lean.sh exec proof/Same.lean | grep -v axioms
echo

echo ">>> the shell, for the chip and for the RTL"
./build.sh
echo

echo ">>> what the chip is held to (build/expect.h, without the image)"
grep -E "^#define (KERNEL_LEN|FIRST_OFF|SECOND_OFF|EXPECT_INSTRET|PROGRAM_LEN)|^// |^static const uint16_t (INVERT|REVERSE)|^static const uint32_t (WORDS|INVERTED|REVERSED)" build/expect.h
echo

echo ">>> on the RTL, stand-ins for PIO0 and PIO1 that work, and the kernel judging what they gave, for real: REPT verdict failed minstret a0 cause word block"
shell_words build/sim.bin
echo
echo

echo ">>> the checks"
./check.sh
} 2>&1 | tee capture.txt
