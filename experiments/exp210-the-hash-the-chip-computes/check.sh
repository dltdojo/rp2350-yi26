#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp210 quick check — everything that can be checked without the board. The
# board half is a person saying "slow" or "fast"; see the README.
#
#   1. the shell's own SHA-256 (its judge) agrees with hashlib;
#   2. sha_hw.h, the SHA-256 block's driver, feeds a fake block the padded
#      message and returns its digest — and three wrong drivers are caught;
#   3. gen.py ran every case on the model and the RTL, and they agreed with
#      Python's verdict, the proved count and the measured minstret;
#   4. the shell builds; its UF2, read back independently of partimg, is
#      family `absolute` and exactly the image; with the toolchain recorded in
#      build-toolchain.txt, it is byte for byte the one whose SHA-256 is
#      committed — the file that was handed over;
#   5. the same shell built for the Hazard3 RTL (HASH in software there) passes
#      every check of every case, and its minstret is the RTL harness's;
#   6. wrong shells each turn the verdict to not-ok, caught by the check they
#      break, and a shell that traps itself is a fault, not a verdict.
#
# Needs clang, lld, llvm-objcopy, cargo, a host C compiler, Lean
# (tools/lean/setup.sh) and the Hazard3 testbench (tools/hazard3/setup.sh).
# About six minutes, most of it gen.py on the first run.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# The LED is the only channel: no UART on this board, no USB in this firmware.
PRESENCE=3
LIFELINE="no: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back"
presence_check
lifeline_check

USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

source ../../tools/hazard3/shell/shell.sh
if [[ "$(../../tools/lean/lean.sh version 2>&1)" != Lean* ]] || ! "$SHELL_SIM" ready; then
    echo "SKIP  the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

../../tools/hazard3/sha256-test.sh || FAILED=1

# The driver against the fake block, and three wrong drivers it must refuse.
mkdir -p build
shatest() { # shell-dir
    cc -O2 -Wall -Werror -I "$1" -o build/shafake host/shafake.c && python3 host/shatest.py build/shafake
}
shatest shell || FAILED=1
driver_mutant() { # what sed
    local work; work="$(mktemp -d)"
    cp -r shell "$work/shell"
    sed -i "$2" "$work/shell/sha_hw.h"
    if cmp -s "$work/shell/sha_hw.h" shell/sha_hw.h; then
        fail "the fake catches a driver that $1" "the sed changed nothing"
    elif shatest "$work/shell" > /dev/null; then
        fail "the fake catches a driver that $1" "it passed"
    else
        pass "the fake catches a driver that $1"
    fi
    rm -rf -- "$work"
}
driver_mutant "does not wait for WDATA_RDY" 's/    while (!(sha_rd(SHA_CSR) \& SHA_WDATA_RDY)) {}//'
driver_mutant "turns BSWAP off" 's/sha_wr(SHA_CSR, SHA_BSWAP | /sha_wr(SHA_CSR, /'
driver_mutant "gives the length in bytes, not bits" 's/__builtin_bswap32(len \* 8)/__builtin_bswap32(len)/'
driver_mutant "reads the sums before SUM_VLD" 's/    while (!(sha_rd(SHA_CSR) \& SHA_SUM_VLD)) {}//'

if ./build.sh > build/build.txt; then
    pass "the shell builds for the chip and for the RTL, the chip's $(stat -c %s build/exp210.bin) bytes in its 128 KiB"
else
    fail "the shell builds" "$(tail -3 build/build.txt)"
    exit 1
fi
cases="$(grep -c 'kernel [01]  verdict' build/gen.txt)"
if [[ "$cases" == 21 ]]; then
    pass "gen.py: on all 21 cases the model gives Python's verdict at the proved count, and the RTL agrees with minstret = count + 3 + 4 S"
else
    fail "gen.py ran all 21 cases" "$cases"
fi
python3 ../../tools/hazard3/shell/uf2check.py build/exp210.uf2 build/exp210.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 131072 || FAILED=1

if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp210.uf2 | cut -d' ' -f1)" == "$(cat exp210.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp210.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# The RTL: CASE i ok failed a0 minstret mcause, per case; then REPT ok failed-cases.
got="$(shell_words build/sim.bin 2000000000)"
echo "$got" > build/sim-words.txt
want=""
i=0
while read -r _ _ _ _ verdict _ _ _ _ _ instret _; do
    want+="$(printf '43415345 %08x 00000001 00000000 %08x %08x 00000008 ' "$i" "$verdict" "$instret")"
    i=$((i + 1))
done < <(grep 'kernel [01]  verdict' build/gen.txt)
want+="52455054 00000001 00000000 exit=0 "
if [[ "$got" == "$want" ]]; then
    pass "on the RTL the shell passes all six checks on all 21 cases: the model's verdict and region, the RTL harness's minstret"
else
    fail "on the RTL the shell passes every case" "$got"
fi

# Wrong shells, on two cases (each kernel's `valid`) to be quick. Each must be
# caught by the check it breaks: the first CASE line says which.
MUTANT_EXPECT=build/expect-two.h
if [[ ! build/expect-two.h -nt build/expect.h ]]; then
    python3 gen.py build/expect-two.h "$(../../tools/lean/lean.sh exe rv32run)" valid > /dev/null
fi
first() { echo "43415345 00000000 00000000 $(printf '%08x' "$1") "; }
shell_mutant "kernel.sha256 is not kernel.bin's hash — check 1" expect.h \
    '/KERNEL_SHA/,/^};/ s/^    {0x[0-9a-f][0-9a-f], /    {0x00, /' "$(first 1)"
shell_mutant "HALT is looked for under t0 = 2 — checks 2 and 3" shell.c \
    's/int halted = cause == 8 \&\& x\[5\] == 1;/int halted = cause == 8 \&\& x[5] == 2;/' "$(first 23)"
shell_mutant "the model's verdict is taken to be 1 — check 3" shell.c \
    's/halted \&\& x\[10\] == e->a0,/halted \&\& x[10] == 1,/' "$(first 3)"
shell_mutant "the hash block answers one bit wrong — checks 3 and 4: the verdict turns, and the region is not the model's" board_sim.c \
    's/    sha256(src, len, dst);/    sha256(src, len, dst);\n    dst[0] ^= 1;/' "$(first 34)"
shell_mutant "a block the model changed is expected unchanged — check 4" shell.c \
    's/CASE_OUT\[q\].at == n) b = CASE_OUT\[q\].block;/CASE_OUT[q].at == n) b = 0;/' "$(first 4)"
shell_mutant "the chip is asked to count one fewer — check 5" expect.h \
    's/^    {0, 0, 17690u,/    {0, 0, 17689u,/' "$(first 5)"
shell_mutant "the hash block reports an error — check 6" board_sim.c \
    's/    return 1;/    return 0;/' "$(first 6)"
shell_mutant "the shell stops after the first case — not ok" shell.c \
    's/if (current == NCASES) board_report/if (current == 1) board_report/' "43415345 00000000 00000001 *52455054 00000000 00000000 "
shell_mutant "the shell itself traps in step 2 — a fault, not a verdict" shell.c \
    's/^    step = 2;$/    step = 2;\n    __asm__ volatile (".word 0");/' "4641554c 00000002 00000002 "

exit "$FAILED"
