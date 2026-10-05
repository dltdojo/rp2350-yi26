#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp209 — build the shell twice, from the same sources:
#
#   build/exp209.uf2   the Pico 2: flash sector 0, family `absolute`, LED out
#   build/sim.bin      the Hazard3 RTL: the testbench's RAM, print port out
#
# Both include tools/hazard3/harness/harness.S with -DSHELL, so the
# instructions around the payload are the RTL harness's own. Needs clang, lld,
# llvm-objcopy, Lean (for the model's region) and cargo (for partimg).
#
#   ./build.sh                          both; prints the UF2's size and SHA-256
#   ./build.sh sim SHELL INCLUDE OUT    the RTL build only, from the shell
#                                       sources in SHELL and expect.h in
#                                       INCLUDE — check.sh's wrong shells

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"
H=../../tools/hazard3/harness

cc() { clang --target=riscv32-unknown-elf -march=rv32im_zicsr -mabi=ilp32 -Os -nostdlib -ffreestanding \
    -fno-pic -mno-relax -fuse-ld=lld -Wall -Werror -I "$H" "$@"; }

sim() { # shell-dir include-dir out.bin
    cc -I "$2" -I "$1" -DSHELL -DREGION=0x80010000 -DMSTACK=0x80010000 -Wl,-T,"$1/link_sim.ld" \
        -o "$3.elf" "$1/start_sim.S" "$H/harness.S" "$1/shell.c" "$1/board_sim.c" "$H/sha256.c"
    llvm-objcopy -O binary "$3.elf" "$3"
}

if [[ "${1-}" == sim ]]; then
    sim "$2" "$3" "$4"
    exit 0
fi

mkdir -p build
RUN="$(../../tools/lean/lean.sh exe rv32run)"
python3 gen.py build/expect.h "$RUN"

cc -I build -I shell -DSHELL -DREGION=0x20070000 -DMSTACK=0x20070000 -Wl,-T,shell/link_chip.ld \
    -o build/chip.elf shell/start_chip.S "$H/harness.S" shell/shell.c shell/board_chip.c "$H/sha256.c"
llvm-objcopy -O binary build/chip.elf build/exp209.bin
cargo run -q --offline --manifest-path ../../tools/partimg/Cargo.toml -- bin build/exp209.bin absolute build/exp209.uf2 > /dev/null
sim shell build build/sim.bin

echo "build/exp209.bin  $(stat -c %s build/exp209.bin) bytes, flash sector 0 holds 4096"
echo "build/exp209.uf2  $(stat -c %s build/exp209.uf2) bytes  sha256 $(sha256sum build/exp209.uf2 | cut -d' ' -f1)"
