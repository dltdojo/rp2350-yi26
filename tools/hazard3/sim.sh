#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tools/hazard3 — run a payload on the Hazard3 RTL, under the harness.
#
#   sim.sh run PAYLOAD.bin [--dump BYTES FILE] [--cycles N]
#       One line on stdout:
#         halt code=<hex> instret=<n> cycles=<n>
#         fault mcause=<hex> mepc=<hex> mtval=<hex> instret=<n>
#         timeout
#       With --dump, the first BYTES of the payload's region afterwards, one
#       little-endian word per line in hex, to FILE — the testbench's own
#       --sigfile format.
#   sim.sh ready      exit 0 when tools/hazard3/setup.sh has run
#   sim.sh region     the region's base and size, as two hex numbers
#
# The payload is a flat binary linked to run at the region's base,
# 0x80010000. On the chip the region is in SRAM at another address; a kernel
# that is to run on both must not depend on where it is, which is the
# kernel's problem and not this tool's.
#
# The harness is built on first use, with the system's clang, into build/.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB="$HERE/Hazard3/test/sim/tb_verilator/tb"
BUILD="$HERE/build"
REGION=0x80010000
REGION_SIZE=0x10000

ready() { [[ -x "$TB" ]]; }

harness() {
    local src="$HERE/harness" out="$BUILD/harness.bin"
    if [[ ! -f "$out" || "$src/harness.S" -nt "$out" || "$src/handler.c" -nt "$out" || "$src/link.ld" -nt "$out" ]]; then
        mkdir -p "$BUILD"
        clang --target=riscv32-unknown-elf -march=rv32im_zicsr -mabi=ilp32 -O2 -nostdlib \
            -ffreestanding -fno-pic -mno-relax -fuse-ld=lld -Wl,-T,"$src/link.ld" \
            -o "$BUILD/harness.elf" "$src/harness.S" "$src/handler.c" || return 1
        llvm-objcopy -O binary "$BUILD/harness.elf" "$out" || return 1
    fi
    echo "$out"
}

case "${1-}" in
    ready) ready; exit;;
    region) echo "$REGION $REGION_SIZE"; exit 0;;
    run) ;;
    *) sed -n '3,22p' "${BASH_SOURCE[0]}"; exit 2;;
esac

payload="${2-}"
[[ -f "$payload" ]] || { echo "no payload '$payload'" >&2; exit 2; }
ready || { echo "the testbench is not built — run tools/hazard3/setup.sh" >&2; exit 2; }
shift 2
dump_bytes=""; dump_file=""; cycles=2000000
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dump) dump_bytes="$2"; dump_file="$3"; shift 3;;
        --cycles) cycles="$2"; shift 2;;
        *) echo "unknown option $1" >&2; exit 2;;
    esac
done

hbin="$(harness)" || { echo "the harness did not build" >&2; exit 2; }
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
size=$(( REGION - 0x80000000 ))
[[ $(stat -c %s "$hbin") -le $size ]] || { echo "the harness is larger than the space below the region" >&2; exit 2; }
cp "$hbin" "$work/image.bin"
truncate -s "$size" "$work/image.bin"
cat "$payload" >> "$work/image.bin"

args=(--bin "$work/image.bin" --cycles "$cycles")
if [[ -n "$dump_bytes" ]]; then
    args+=(--dump "$(printf '0x%x' "$REGION")" "$(printf '0x%x' $(( REGION + dump_bytes )))" --sigfile "$work/sig")
fi
"$TB" "${args[@]}" > "$work/log" 2>&1
[[ -n "$dump_file" && -f "$work/sig" ]] && cp "$work/sig" "$dump_file"

# The handler prints tagged hex words, one per line; the testbench adds its
# own lines around them.
mapfile -t words < <(grep -E '^[0-9a-f]{8}$' "$work/log")
if [[ "${words[0]-}" == 48414c54 ]]; then
    echo "halt code=${words[1]} instret=$((16#${words[2]})) cycles=$((16#${words[3]}))"
elif [[ "${words[0]-}" == 4641554c ]]; then
    echo "fault mcause=${words[1]} mepc=${words[2]} mtval=${words[3]} instret=$((16#${words[4]}))"
else
    echo "timeout"
fi
