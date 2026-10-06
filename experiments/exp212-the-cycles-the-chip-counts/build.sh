#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp212 — build the shell twice, from the same sources
# (tools/hazard3/shell/shell.sh says how):
#
#   build/exp212.uf2   the Pico 2: 16 seeds, flash from 0x10000000, family
#                      `absolute`, HASH on the SHA-256 block, LED out
#   build/sim.bin      the Hazard3 RTL: the same schedule with 2 seeds (one
#                      key generation is minutes there), HASH in software,
#                      print port out
#
# build/rtl.txt is gen.py's three RTL runs (about seven minutes); the
# expect.h files are gen.py's Lean model runs over every seed (about a
# minute and a half). Each is made again only when its sources change.
# Needs clang, lld, llvm-objcopy, Lean, the Hazard3 testbench and cargo (for
# partimg).
#
#   ./build.sh                          both; prints the UF2's size and SHA-256
#   ./build.sh sim SHELL INCLUDE OUT    the RTL build only, OUT.bin, from the
#                                       shell sources in SHELL and expect.h in
#                                       INCLUDE

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../../tools/hazard3/shell/shell.sh
H=../../tools/hazard3/harness
FLASH=32768
CHIP_SEEDS=16
SIM_SEEDS=2

sim() { # shell-dir include-dir out
    shell_sim "$3" -I "$2" -I "$1" "$1/shell.c" "$1/board_sim.c" "$H/sha256.c"
}

if [[ "${1-}" == sim ]]; then
    sim "$2" "$3" "$4"
    exit 0
fi

mkdir -p build/chip build/sim
K=../exp213-the-signer-the-verifier-accepts
SOURCES=(gen.py ../../tools/hazard3/mss.py ../../tools/hazard3/wots.py ../../tools/hazard3/shell/expect.py
    "$K"/{keygen.bin,keygen.sha256,sign.bin,sign.sha256})
fresh() { # target
    local s
    for s in "${SOURCES[@]}"; do [[ "$1" -nt "$s" ]] || return 1; done
}
if ! fresh build/rtl.txt; then
    python3 gen.py rtl build/rtl.txt.new > /dev/null
    mv build/rtl.txt.new build/rtl.txt
fi
RUN="$(../../tools/lean/lean.sh exe rv32run)"
for d in chip:$CHIP_SEEDS sim:$SIM_SEEDS; do
    dir=build/${d%%:*}
    if ! fresh "$dir/expect.h" || [[ ! "$dir/expect.h" -nt build/rtl.txt ]]; then
        python3 gen.py expect "$dir/expect.h.new" "$RUN" build/rtl.txt "${d##*:}" > "$dir/gen.txt"
        mv "$dir/expect.h.new" "$dir/expect.h"
    fi
done
tail -1 build/chip/gen.txt

shell_chip "$FLASH" build/chip/shell -I build/chip -I shell shell/shell.c shell/board_chip.c "$H/sha256.c"
cp build/chip/shell.bin build/exp212.bin
cp build/chip/shell.uf2 build/exp212.uf2
sim shell build/sim build/sim

echo "build/exp212.bin  $(stat -c %s build/exp212.bin) bytes, of the $FLASH the link allows"
echo "build/exp212.uf2  $(stat -c %s build/exp212.uf2) bytes  sha256 $(sha256sum build/exp212.uf2 | cut -d' ' -f1)"
