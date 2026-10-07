#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp216 — build the shell twice, from the same sources
# (tools/hazard3/shell/shell.sh says how):
#
#   build/exp216.uf2   the Pico 2: flash sector 0, family `absolute`, LED out
#   build/sim.bin      the Hazard3 RTL: the testbench's RAM, writes printed,
#                      reads answered by a stand-in PIO and pin that work
#
# Needs clang, lld, llvm-objcopy and cargo (for partimg).
#
#   ./build.sh                          both; prints the UF2's size and SHA-256
#   ./build.sh sim SHELL DEVICE OUT     the RTL build only, OUT.bin, from the
#                                       shell sources in SHELL, against stand-in
#                                       DEVICE (board_sim.c lists them)

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../../tools/hazard3/shell/shell.sh

sim() { # shell-dir device out
    shell_sim "$3" -DDEVICE="$2" -I "$1" "$1/shell.c" "$1/board_sim.c"
}

if [[ "${1-}" == sim ]]; then
    sim "$2" "$3" "$4"
    exit 0
fi

mkdir -p build
shell_chip 4096 build/chip -I shell shell/shell.c shell/board_chip.c
mv build/chip.bin build/exp216.bin
mv build/chip.uf2 build/exp216.uf2

sim shell 0 build/sim

echo "build/exp216.bin  $(stat -c %s build/exp216.bin) bytes, flash sector 0 holds 4096"
echo "build/exp216.uf2  $(stat -c %s build/exp216.uf2) bytes  sha256 $(sha256sum build/exp216.uf2 | cut -d' ' -f1)"
