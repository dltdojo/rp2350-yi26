#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp232 — build the shell twice, from the same sources
# (tools/hazard3/shell/shell.sh says how):
#
#   build/exp232.uf2   the Pico 2: the first 16 KiB of flash, family `absolute`,
#                      the LED, exp226's USB port (tools/hazard3/shell/speak.h)
#                      and the TRNG (tools/hazard3/shell/trng.h)
#   build/sim.bin      the Hazard3 RTL: the search and six patients, printed
#
# cure.h is gen.py's: the kernel, what its shell checks, and the trial's
# constants.
#
# Needs clang, lld, llvm-objcopy, Lean (for the model), the Hazard3 testbench
# (for minstret) and cargo (for partimg).
#
#   ./build.sh                          both; prints the UF2's size and SHA-256
#   ./build.sh sim SHELL INCLUDE OUT    the RTL build only, OUT.bin, from the
#                                       shell sources in SHELL and cure.h in
#                                       INCLUDE — check.sh's wrong shells

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../../tools/hazard3/shell/shell.sh
H=../../tools/hazard3/harness
S=../../tools/hazard3/shell

sim() { # shell-dir include-dir out
    shell_sim "$3" -I "$2" -I "$1" -I build "$1/shell.c" "$1/board_sim.c" "$H/sha256.c"
}

if [[ "${1-}" == sim ]]; then
    sim "$2" "$3" "$4"
    exit 0
fi

mkdir -p build
python3 gen.py build/cure.h "$(../../tools/lean/lean.sh exe rv32run)"

shell_chip 16384 build/chip -I build -I shell shell/shell.c shell/board_chip.c \
    "$S/usb_chip.c" "$S/usbdev.c" "$H/sha256.c"
mv build/chip.bin build/exp232.bin
mv build/chip.uf2 build/exp232.uf2
sim shell build build/sim

echo "build/exp232.bin  $(stat -c %s build/exp232.bin) bytes, the build allows 16384"
echo "build/exp232.uf2  $(stat -c %s build/exp232.uf2) bytes  sha256 $(sha256sum build/exp232.uf2 | cut -d' ' -f1)"
