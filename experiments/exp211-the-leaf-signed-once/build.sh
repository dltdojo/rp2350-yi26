#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp211 — build the shell twice, from the same sources
# (tools/hazard3/shell/shell.sh says how):
#
#   build/exp211.uf2   the Pico 2: flash from 0x10000000, family `absolute`,
#                      HASH on the SHA-256 block, the counter in the board's
#                      own flash through the bootrom, LED out
#   build/sim.bin      the Hazard3 RTL: HASH in software, the counter in a
#                      RAM array that outlives each boot, a script of power
#                      cuts, print port out
#
# build/expect.h comes from gen.py (about a minute, on the Lean model); it is
# made again only when its sources change. Needs clang, lld, llvm-objcopy,
# Lean and cargo (for partimg).
#
#   ./build.sh       both; prints the UF2's size and SHA-256

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../../tools/hazard3/shell/shell.sh
H=../../tools/hazard3/harness
FLASH=32768

mkdir -p build
SOURCES=(gen.py ../../tools/hazard3/mss.py ../../tools/hazard3/wots.py ../../tools/hazard3/shell/expect.py
    ../exp213-the-signer-the-verifier-accepts/{keygen.bin,keygen.sha256,sign.bin,sign.sha256}
    ../exp206-the-root-the-path-climbs/{kernel.bin,kernel.sha256})
stale=0
for s in "${SOURCES[@]}"; do [[ build/expect.h -nt "$s" ]] || stale=1; done
if [[ $stale == 1 ]]; then
    python3 gen.py build/expect.h.new "$(../../tools/lean/lean.sh exe rv32run)" > build/gen.txt
    mv build/expect.h.new build/expect.h
fi
tail -1 build/gen.txt

shell_chip "$FLASH" build/chip -I build -I shell shell/shell.c shell/board_chip.c shell/flash_rom.S "$H/sha256.c"
cp build/chip.bin build/exp211.bin
cp build/chip.uf2 build/exp211.uf2
shell_sim build/sim -I build -I shell shell/shell.c shell/board_sim.c "$H/sha256.c"

echo "build/exp211.bin  $(stat -c %s build/exp211.bin) bytes, of the $FLASH the link allows"
echo "build/exp211.uf2  $(stat -c %s build/exp211.uf2) bytes  sha256 $(sha256sum build/exp211.uf2 | cut -d' ' -f1)"
