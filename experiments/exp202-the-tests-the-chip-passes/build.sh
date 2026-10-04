#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp202 — build riscv-tests' RV32I and RV32M tests as flat images for the
# region at 0x80010000, with this experiment's environment, into build/.
#
#   ./build.sh          prints one line per test built; exit 1 if any did not
#
# And this experiment's own probes, in probes/: what the suite does not
# exercise, found by the mutants in semantics/mutants.txt that it let through.
#
# The sources are the suite pinned by tools/hazard3/setup.sh — the commit the
# Hazard3 repository itself names — so the RTL's own test run and this one
# read the same files.
#
# Two of rv32ui's tests are not built, and each is a decision, not a gap:
#   fence_i   Zifencei: the model has no `fence.i`, and refuses it on purpose
#   ma_data   misaligned access, checked through a trap handler written with
#             CSR instructions — the model faults on the first of them

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
SUITE=../../tools/hazard3/Hazard3/test/sim/riscv-tests/riscv-tests/isa
[[ -d "$SUITE" ]] || { echo "the suite is not here — run tools/hazard3/setup.sh" >&2; exit 2; }
SKIP=" fence_i ma_data "

mkdir -p build
status=0
for src in "$SUITE"/rv32ui/*.S "$SUITE"/rv32um/*.S probes/*.S; do
    set_name="$(basename "$(dirname "$src")")"
    [[ "$set_name" == probes ]] && set_name=probe
    name="$(basename "$src" .S)"
    [[ "$SKIP" == *" $name "* ]] && continue
    out="build/$set_name-$name"
    if clang --target=riscv32-unknown-elf -march=rv32im_zicsr -mabi=ilp32 -nostdlib -mno-relax \
            -fuse-ld=lld -I env -I "$SUITE/macros/scalar" -I "$SUITE/rv64ui" -I "$SUITE/rv64um" \
            -Wl,-T,env/link.ld -o "$out.elf" "$src" 2> "$out.err" \
        && llvm-objcopy -O binary "$out.elf" "$out.bin"; then
        echo "$set_name-$name $(stat -c %s "$out.bin")"
        rm -f "$out.err"
    else
        echo "FAIL  $set_name-$name does not build: $(head -1 "$out.err")"
        status=1
    fi
done
exit "$status"
