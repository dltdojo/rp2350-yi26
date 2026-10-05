# SPDX-License-Identifier: Apache-2.0
#
# tools/hazard3/shell — building a shell, and checking one, for an experiment's
# build.sh and check.sh to source. A shell is a payload's Machine-mode host:
# exp209's runs one kernel, exp210's runs two kernels' cases. Each is built
# twice from the same sources:
#
#   the chip   flash from 0x10000000, family `absolute`, region 0x20070000;
#              start_chip.S, the experiment's board_chip.c (which includes
#              led.h), and the experiment's own sources
#   the RTL    the testbench's RAM, region 0x80010000; start_sim.S and the
#              experiment's board_sim.c, which prints instead of blinking
#
# and both include tools/hazard3/harness/harness.S with -DSHELL, so the
# instructions around the payload — the ones minstret counts — are the RTL
# harness's own.
#
#   shell_chip FLASH OUT SRC...   OUT.elf, OUT.bin, OUT.uf2; the link refuses
#                                 an image over FLASH bytes
#   shell_sim OUT SRC...          OUT.elf, OUT.bin, for `sim.sh bare`
#   shell_words BIN [CYCLES]      what the RTL build printed, on one line
#   shell_mutant WHAT FILE SED WANT
#                                 check.sh's wrong shells: copy shell/ and
#                                 build/expect.h, apply SED to FILE (a file
#                                 in shell/, or expect.h), rebuild with
#                                 `./build.sh sim SHELL INCLUDE OUT`, and pass
#                                 when what it prints matches WANT* — WANT is
#                                 a pattern, so it may hold a * of its own.
#                                 MUTANT_EXPECT, if set, is the expect.h to
#                                 copy instead of build/expect.h
#
# SRC may include -I and -D flags. Needs clang, lld, llvm-objcopy and cargo
# (for tools/partimg); shell_words and shell_mutant need the Hazard3 testbench,
# and shell_mutant needs ../lib.sh's pass and fail.

SHELL_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELL_HARNESS="$SHELL_TOOLS/../harness"
SHELL_SIM="$SHELL_TOOLS/../sim.sh"

shell_cc() {
    clang --target=riscv32-unknown-elf -march=rv32im_zicsr -mabi=ilp32 -Os -nostdlib -ffreestanding \
        -fno-pic -mno-relax -fuse-ld=lld -Wall -Werror -I "$SHELL_HARNESS" -I "$SHELL_TOOLS" "$@"
}

shell_chip() { # flash-bytes out src...
    local flash="$1" out="$2"; shift 2
    shell_cc -DSHELL -DREGION=0x20070000 -DMSTACK=0x20070000 \
        -Wl,-T,"$SHELL_TOOLS/link_chip.ld" -Wl,--defsym=FLASH_SIZE="$flash" \
        -o "$out.elf" "$SHELL_TOOLS/start_chip.S" "$SHELL_HARNESS/harness.S" "$@" &&
    llvm-objcopy -O binary "$out.elf" "$out.bin" &&
    cargo run -q --offline --manifest-path "$SHELL_TOOLS/../../partimg/Cargo.toml" -- \
        bin "$out.bin" absolute "$out.uf2" > /dev/null
}

shell_sim() { # out src...
    local out="$1"; shift
    shell_cc -DSHELL -DREGION=0x80010000 -DMSTACK=0x80010000 -Wl,-T,"$SHELL_TOOLS/link_sim.ld" \
        -o "$out.elf" "$SHELL_TOOLS/start_sim.S" "$SHELL_HARNESS/harness.S" "$@" &&
    llvm-objcopy -O binary "$out.elf" "$out.bin"
}

shell_words() { "$SHELL_SIM" bare "$1" --cycles "${2-200000000}" | tr '\n' ' '; }

shell_mutant() { # what file sed want
    local work target orig expect="${MUTANT_EXPECT:-build/expect.h}"
    work="$(mktemp -d)"
    cp -r shell "$work/shell"; cp "$expect" "$work/expect.h"
    if [[ "$2" == expect.h ]]; then target="$work/expect.h" orig="$expect"
    else target="$work/shell/$2" orig="shell/$2"; fi
    sed -i "$3" "$target"
    if cmp -s "$target" "$orig"; then
        fail "the shell catches a version where $1" "the sed changed nothing"
    elif ./build.sh sim "$work/shell" "$work" "$work/sim" 2> /dev/null && [[ "$(shell_words "$work/sim.bin")" == $4* ]]; then
        pass "the shell catches a version where $1"
    else
        fail "the shell catches a version where $1" "$(shell_words "$work/sim.bin" 2> /dev/null)"
    fi
    rm -rf -- "$work"
}
