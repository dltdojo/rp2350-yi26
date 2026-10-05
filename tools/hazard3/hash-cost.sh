#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tools/hazard3 — what one HASH costs in minstret, measured. exp204 wrote it;
# exp205 needed the same number second.
#
#   hash-cost.sh            the table, then PASS/FAIL lines; exit 0 = as claimed
#   hash-cost.sh --quiet    only the PASS/FAIL lines
#
# Payloads that make k HASH calls in a row and then HALT, for k = 0..7, through
# the same harness as every kernel. The model counts each `ecall` as one
# instruction, so it counts k + 8. The claim is that the RTL counts exactly
#
#     model + C + k × P
#
# for two constants: C, the harness's (exp203 measured 3), and P, what one
# HASH round trip through the harness adds that the model does not count.
#
# Each payload is run three ways, which differ only in bytes the model never
# reads as code:
#   zeros    everything after the payload zero
#   input    the 64 bytes hashed are 0xa5 instead — the count must not move
#   behind   the word right after the HALT `ecall` is a `nop` instead of zero
#            — and it does move, by one: exp203's "what lies behind" again,
#            this time behind an ecall rather than an mret
# A kernel's image with zeros behind its last ecall counts as `zeros` does.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
SIM=./sim.sh
RUN="$(../lean/lean.sh exe rv32run)" || exit 2
read -r BASE SIZE < <($SIM region)
quiet="${1-}"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
status=0
say() { [[ "$quiet" == --quiet ]] || echo "$@"; }

cc() { clang --target=riscv32-unknown-elf -march=rv32im_zicsr -mabi=ilp32 -nostdlib -mno-relax \
    -fuse-ld=lld "$@" 2> /dev/null; }

say "  k   model   RTL: zeros   input   behind   RTL − model"
offsets=()
for k in 0 1 2 3 4 5 6 7; do
    { echo ".text"; echo ".globl _start"; echo "_start:"
      echo "    auipc s0, 0"
      echo "    lui t1, 8"
      echo "    add a0, s0, t1"            # the input, at base + 0x8000
      echo "    addi a1, x0, 64"
      echo "    addi a2, a0, 64"           # the output right after it
      echo "    addi t0, x0, 0"
      for _ in $(seq "$k"); do echo "    ecall"; done
      echo "    addi t0, x0, 1"; echo "    ecall"; } > "$work/p.S"
    cc -Wl,-Ttext=$BASE -o "$work/p.elf" "$work/p.S" && llvm-objcopy -O binary "$work/p.elf" "$work/p.bin"
    cp "$work/p.bin" "$work/z.bin"; truncate -s $((0x8040)) "$work/z.bin"
    { head -c $((0x8000)) "$work/z.bin"; head -c 64 /dev/zero | tr '\0' '\245'; } > "$work/i.bin"
    { cat "$work/p.bin"; printf '\x13\x00\x00\x00'; } > "$work/n.bin"; truncate -s $((0x8040)) "$work/n.bin"
    l="$($RUN "$work/z.bin" "$BASE" "$SIZE" 1000 | sed -n 's/.*count=\([0-9]*\).*/\1/p')"
    z="$($SIM run "$work/z.bin" | sed -n 's/.*instret=\([0-9]*\).*/\1/p')"
    i="$($SIM run "$work/i.bin" | sed -n 's/.*instret=\([0-9]*\).*/\1/p')"
    n="$($SIM run "$work/n.bin" | sed -n 's/.*instret=\([0-9]*\).*/\1/p')"
    say "$(printf '  %d   %5s   %10s   %5s   %6s   %11s' "$k" "$l" "$z" "$i" "$n" "$((z - l))")"
    offsets+=("$((z - l))")
    [[ "$l" == "$((k + 8))" ]] || { echo "FAIL  the model counts k + 8 at k = $k — $l"; status=1; }
    [[ "$z" == "$i" ]] || { echo "FAIL  the count does not depend on the bytes hashed, at k = $k — $z and $i"; status=1; }
    [[ "$n" == "$((z + 1))" ]] || { echo "FAIL  a nop behind the last ecall is counted once, at k = $k — $z and $n"; status=1; }
done
C=${offsets[0]}; P=$((offsets[1] - offsets[0]))
linear=1
for k in 0 1 2 3 4 5 6 7; do [[ ${offsets[$k]} -eq $((C + k * P)) ]] || linear=0; done
if [[ $linear -eq 1 ]]; then
    echo "PASS  RTL − model = $C + $P × HASH calls, for k = 0..7: the harness's constant is $C and one HASH costs $P more"
else
    echo "FAIL  RTL − model is a constant plus a fixed cost per HASH — ${offsets[*]}"; status=1
fi
[[ $status -eq 0 ]] && echo "PASS  the bytes hashed do not move the count; a nop behind the HALT ecall, never executed, adds one, at every k"
exit "$status"
