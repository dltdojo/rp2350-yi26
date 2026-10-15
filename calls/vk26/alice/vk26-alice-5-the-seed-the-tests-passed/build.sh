#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# vk26-alice-5 — build the shell twice, from the same sources
# (tools/hazard3/shell/shell.sh says how):
#
#   build/vk26-alice-5.uf2   the Pico 2: the first 64 KiB of flash (the code,
#                            the three kernels, the 120 NIST cases), family
#                            `absolute`, USB and the LED (speak.h), the TRNG,
#                            HASH and HASHB on the SHA-256 block
#   build/sim.bin            the Hazard3 RTL: the same, a stand-in TRNG, HASH
#                            and HASHB in software, one round, printed
#
# Needs clang, lld, llvm-objcopy, Lean (for the kernels and the model), the
# Hazard3 testbench (for the RTL's counts) and cargo (for partimg).
#
#   ./build.sh                                  both; prints the UF2's size and SHA-256
#   ./build.sh sim SHELL INCLUDE OUT [DEVICE]   the RTL build only, OUT.bin, from the
#                                               shell sources in SHELL and expect.h in
#                                               INCLUDE, against stand-in DEVICE

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"
TOOLS=../../../../tools
source "$TOOLS/hazard3/shell/shell.sh"
H=$TOOLS/hazard3/harness
S=$TOOLS/hazard3/shell
FLASH=65536

sim() { # shell-dir include-dir out device
    shell_sim "$3" -DDEVICE="${4:-0}" -I "$2" -I "$1" -I ../shell "$1/shell.c" "$1/board_sim.c" "$H/sha256.c"
}

if [[ "${1-}" == sim ]]; then
    sim "$2" "$3" "$4" "${5-0}"
    exit 0
fi

mkdir -p build
LEAN=$TOOLS/lean/lean.sh
"$LEAN" exec proof/Seed.lean build/kernel.bin build/trust.bin build/drbg.bin > /dev/null
cmp -s build/kernel.bin kernel.bin || { echo "build.sh: kernel.bin is not what proof/Seed.lean writes" >&2; exit 1; }
python3 gen.py build/expect.h "$("$LEAN" exe rv32run)" build/trust.bin build/drbg.bin

shell_chip "$FLASH" build/chip -I build -I shell -I ../shell shell/shell.c shell/board_chip.c \
    "$S/usb_chip.c" "$S/usbdev.c" "$H/sha256.c"
mv build/chip.bin build/vk26-alice-5.bin
mv build/chip.uf2 build/vk26-alice-5.uf2
sim shell build build/sim

echo "build/vk26-alice-5.bin  $(stat -c %s build/vk26-alice-5.bin) bytes, the build allows $FLASH"
echo "build/vk26-alice-5.uf2  $(stat -c %s build/vk26-alice-5.uf2) bytes  sha256 $(sha256sum build/vk26-alice-5.uf2 | cut -d' ' -f1)"
