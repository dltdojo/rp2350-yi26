#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp237 — build the pure C hardware enclave shell for Pico 2 (RP2350).
#
#   1. Runs gen.py to generate build/payload.h containing monitor_chip.bin and exp229's kernel.bin
#   2. Compiles shell sources using clang --target=riscv32-unknown-elf
#   3. Links for flash at 0x10000000 with link_chip.ld, stack at 0x20030000
#   4. Packages flat binary build/exp237.bin into build/exp237.uf2 via tools/partimg

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"

S=../../tools/hazard3/shell
H=../../tools/hazard3/harness

mkdir -p build

python3 gen.py build/payload.h

FLASH_LIMIT=16384
MSTACK=0x20030000

clang --target=riscv32-unknown-elf -march=rv32im_zicsr -mabi=ilp32 -Os -nostdlib -ffreestanding \
    -fno-pic -mno-relax -fuse-ld=lld -Wall -Werror \
    -DMSTACK=$MSTACK -DFLASH_SIZE=$FLASH_LIMIT \
    -I build -I shell -I "$S" -I "$H" \
    -Wl,-T,"$S/link_chip.ld" -Wl,--defsym=FLASH_SIZE=$FLASH_LIMIT \
    -o build/exp237.elf \
    "$S/start_chip.S" shell/enclave.c shell/board_chip.c \
    "$S/usb_chip.c" "$S/usbdev.c"

llvm-objcopy -O binary build/exp237.elf build/exp237.bin

cargo run -q --offline --manifest-path ../../tools/partimg/Cargo.toml -- \
    bin build/exp237.bin absolute build/exp237.uf2 > /dev/null

echo "build/exp237.bin  $(stat -c %s build/exp237.bin) bytes, the build allows $FLASH_LIMIT"
echo "build/exp237.uf2  $(stat -c %s build/exp237.uf2) bytes  sha256 $(sha256sum build/exp237.uf2 | cut -d' ' -f1)"
