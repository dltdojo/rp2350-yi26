#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp203 — where the RTL's extra instructions come from.
#
#   measure.sh            two tables, then PASS/FAIL lines; exit 0 = as claimed
#   measure.sh --quiet    only the PASS/FAIL lines
#
# 1. The sweep: payloads of k `nop`s, then `addi t0, x0, 1; ecall` — HALT —
#    for k = 0..7, through the same harness as every kernel. The model counts
#    k + 2. The claim is that the RTL counts exactly a constant more, and that
#    each added instruction adds exactly one: so a proof's count, plus the
#    harness's constant, is the RTL's count.
# 2. counts.S, built twice (see its header): what one mret, one ecall and one
#    write to mcountinhibit each cost, read the same way both times — and the
#    two builds differ only in what sits in memory behind an mret.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
SIM=../../../tools/hazard3/sim.sh
RUN="$(../../../tools/lean/lean.sh exe rv32run)" || exit 2
read -r BASE SIZE < <($SIM region)
quiet="${1-}"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
status=0
say() { [[ "$quiet" == --quiet ]] || echo "$@"; }

cc() { clang --target=riscv32-unknown-elf -march=rv32im_zicsr -mabi=ilp32 -nostdlib -mno-relax \
    -fuse-ld=lld "$@" 2> /dev/null; }

say "  k   model   RTL minstret   RTL − model"
offsets=""
for k in 0 1 2 3 4 5 6 7; do
    { echo ".text"; echo ".globl _start"; echo "_start:"
      for _ in $(seq "$k"); do echo "    nop"; done
      echo "    addi t0, x0, 1"; echo "    ecall"; } > "$work/p.S"
    cc -Wl,-Ttext=$BASE -o "$work/p.elf" "$work/p.S" && llvm-objcopy -O binary "$work/p.elf" "$work/p.bin"
    l="$($RUN "$work/p.bin" "$BASE" "$SIZE" 1000 | sed -n 's/.*count=\([0-9]*\).*/\1/p')"
    r="$($SIM run "$work/p.bin" | sed -n 's/.*instret=\([0-9]*\).*/\1/p')"
    say "$(printf '  %d   %5s   %12s   %11s' "$k" "$l" "$r" "$((r - l))")"
    offsets+="$((r - l)) "
    [[ "$l" == "$((k + 2))" ]] || { echo "FAIL  the model counts k + 2 at k = $k — $l"; status=1; }
done
if [[ "$(tr ' ' '\n' <<< "$offsets" | sort -u | grep -c .)" -eq 1 ]]; then
    echo "PASS  every instruction the model counts, the RTL counts once: RTL − model = ${offsets%% *} for k = 0..7"
else
    echo "FAIL  RTL − model is the same for every k — $offsets"; status=1
fi

say
say "  measurement                                    apart  adjacent"
for v in apart adjacent; do
    flag=""; [[ $v == adjacent ]] && flag=-DADJACENT
    cc $flag -Wl,-Ttext=0x80000000 -Wl,-e,0x80000040 -o "$work/c.elf" counts.S \
        && llvm-objcopy -O binary "$work/c.elf" "$work/$v.bin"
    mapfile -t "vals_$v" < <($SIM bare "$work/$v.bin" | grep -E '^[0-9a-f]{8}$')
done
labels=("1  enable; read" "2  enable; disable; read" "3  enable; nop; disable; read" \
    "4  enable; mret to Machine" "5  enable; mret to User; ecall" \
    "6  enable; mret to User; illegal instruction" "7  enable; mret to User; nop; ecall")
for i in 0 1 2 3 4 5 6; do
    say "$(printf '  %-46s %5d  %8d' "${labels[$i]}" "$((16#${vals_apart[$i]}))" "$((16#${vals_adjacent[$i]}))")"
done
a=("${vals_apart[@]}"); d=("${vals_adjacent[@]}")
# What the README rests on, checked rather than believed:
[[ $((16#${a[0]})) -eq 0 && $((16#${a[1]})) -eq 1 ]] \
    && echo "PASS  the write that starts counting is not counted, the write that stops it is" \
    || { echo "FAIL  the write that starts counting is not counted, the write that stops it is"; status=1; }
[[ $((16#${a[3]})) -eq 2 ]] \
    && echo "PASS  one mret is counted as two" \
    || { echo "FAIL  one mret is counted as two — ${a[3]}"; status=1; }
[[ $((16#${a[4]})) -ge 3 ]] \
    && echo "PASS  an ecall is counted at all — the privileged specification says it should not be" \
    || { echo "FAIL  an ecall is counted at all"; status=1; }
[[ ${a[6]} != "${d[6]}" ]] \
    && echo "PASS  the same instructions count differently when only what lies behind an mret changes ($((16#${a[6]})) and $((16#${d[6]})))" \
    || { echo "FAIL  the same instructions count differently when only what lies behind an mret changes"; status=1; }
exit "$status"
