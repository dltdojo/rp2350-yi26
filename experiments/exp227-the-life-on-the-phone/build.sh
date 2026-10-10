#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp227 — exp225's shell and kernel, unchanged, over exp226's USB port: the
# shell is exp225's shell/shell.c, its expect.h is exp225's gen.py's, the USB
# port and status line are tools/hazard3/shell/speak.h, and only how a life is
# shown is this experiment's (shell/board_chip.c).
#
#   build/exp227.uf2   the Pico 2: the first 16 KiB of flash, family `absolute`
#
# There is no RTL build: the RTL has no USB controller, and what exp227 adds
# is only what goes out over it. exp226's check.sh runs this shell on the RTL.
#
# Needs clang, lld, llvm-objcopy, Lean (for the model), the Hazard3 testbench
# (for minstret) and cargo (for partimg).

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../../tools/hazard3/shell/shell.sh
H=../../tools/hazard3/harness
S=../../tools/hazard3/shell
E=../exp225-the-life-every-beat-proved

mkdir -p build
RUN="$(../../tools/lean/lean.sh exe rv32run)"
python3 "$E/gen.py" build/expect.h "$RUN"

shell_chip 16384 build/chip -I build -I "$E/shell" "$E/shell/shell.c" shell/board_chip.c \
    "$S/usb_chip.c" "$S/usbdev.c" "$H/sha256.c"
mv build/chip.bin build/exp227.bin
mv build/chip.uf2 build/exp227.uf2

echo "build/exp227.bin  $(stat -c %s build/exp227.bin) bytes, the build allows 16384"
echo "build/exp227.uf2  $(stat -c %s build/exp227.uf2) bytes  sha256 $(sha256sum build/exp227.uf2 | cut -d' ' -f1)"
