#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp228 — build the shell twice, from the same sources
# (tools/hazard3/shell/shell.sh says how):
#
#   build/exp228.uf2   the Pico 2: the first 32 KiB of flash, family `absolute`,
#                      USB and the LED (tools/hazard3/shell/speak.h)
#   build/sim.bin      the Hazard3 RTL: the same cases, the same BIP340, one
#                      round, printed
#
# Needs clang, lld, llvm-objcopy, Lean (for the model), the Hazard3 testbench
# (for the RTL build's run) and cargo (for partimg).
#
#   ./build.sh                                  both; prints the UF2's size and SHA-256
#   ./build.sh sim SHELL INCLUDE OUT            the RTL build only, OUT.bin, from the
#                                               shell sources in SHELL and expect.h in
#                                               INCLUDE

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../../tools/hazard3/shell/shell.sh
H=../../tools/hazard3/harness
S=../../tools/hazard3/shell

sim() { # shell-dir include-dir out
    shell_sim "$3" -I "$2" -I "$1" "$1/shell.c" "$1/board_sim.c" "$1/bip340.c" "$H/sha256.c"
}

if [[ "${1-}" == sim ]]; then
    sim "$2" "$3" "$4"
    exit 0
fi

mkdir -p build
RUN="$(../../tools/lean/lean.sh exe rv32run)"
python3 gen.py build/expect.h "$RUN"

shell_chip 32768 build/chip -I build -I shell shell/shell.c shell/board_chip.c shell/bip340.c \
    "$S/usb_chip.c" "$S/usbdev.c" "$H/sha256.c"
mv build/chip.bin build/exp228.bin
mv build/chip.uf2 build/exp228.uf2
sim shell build build/sim

echo "build/exp228.bin  $(stat -c %s build/exp228.bin) bytes, the build allows 32768"
echo "build/exp228.uf2  $(stat -c %s build/exp228.uf2) bytes  sha256 $(sha256sum build/exp228.uf2 | cut -d' ' -f1)"
