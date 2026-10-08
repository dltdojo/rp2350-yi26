#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp223 — build the shell twice, from the same sources
# (tools/hazard3/shell/shell.sh says how), each with the 128 KiB region:
#
#   build/exp223.uf2   the Pico 2: the first 16 KiB of flash, family `absolute`, LED out
#   build/sim.bin      the Hazard3 RTL: the kernel for real, a stand-in TRNG
#                      that works
#
# Needs clang, lld, llvm-objcopy, Lean (for the model's region), the Hazard3
# testbench (for minstret) and cargo (for partimg).
#
#   ./build.sh                                  both; prints the UF2's size and SHA-256
#   ./build.sh sim SHELL INCLUDE OUT [DEVICE]   the RTL build only, OUT.bin, from the
#                                               shell sources in SHELL and expect.h in
#                                               INCLUDE, against stand-in DEVICE

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../../tools/hazard3/shell/shell.sh
H=../../tools/hazard3/harness
export SHELL_WIDE=1

sim() { # shell-dir include-dir out device
    shell_sim "$3" -DDEVICE="${4:-0}" -I "$2" -I "$1" "$1/shell.c" "$1/board_sim.c" "$H/sha256.c"
}

if [[ "${1-}" == sim ]]; then
    sim "$2" "$3" "$4" "${5-0}"
    exit 0
fi

mkdir -p build
RUN="$(../../tools/lean/lean.sh exe rv32run)"
python3 gen.py build/expect.h "$RUN"

shell_chip 16384 build/chip -I build -I shell shell/shell.c shell/board_chip.c "$H/sha256.c"
mv build/chip.bin build/exp223.bin
mv build/chip.uf2 build/exp223.uf2
sim shell build build/sim

echo "build/exp223.bin  $(stat -c %s build/exp223.bin) bytes, the build allows 16384"
echo "build/exp223.uf2  $(stat -c %s build/exp223.uf2) bytes  sha256 $(sha256sum build/exp223.uf2 | cut -d' ' -f1)"
