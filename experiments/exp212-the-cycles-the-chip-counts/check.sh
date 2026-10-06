#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp212 quick check — everything that can be checked without the board. The
# board half is a person saying "slow", or how many flashes; see the README.
#
#   1. verdict.h, the LED's decision, gives each of its seven answers on the
#      results that must give it — and thirteen wrong versions of it are caught;
#   2. gen.py ran every seed on the Lean model and three runs on the RTL, and
#      they agreed: code 0, one count per kind, keygen's tree mss.py's, and
#      minstret = count + 3 + 4 S;
#   3. the shell builds; its UF2, read back independently of partimg, is
#      family `absolute` and exactly the image; with the toolchain recorded in
#      build-toolchain.txt, it is byte for byte the one whose SHA-256 is
#      committed — the file that was handed over;
#   4. the same shell built for the Hazard3 RTL, with two seeds, passes every
#      check of every run, reads the RTL harness's mcycle on every one, and
#      says slow.
#
# Needs clang, lld, llvm-objcopy, cargo, a host C compiler, Lean
# (tools/lean/setup.sh) and the Hazard3 testbench (tools/hazard3/setup.sh).
# About fifteen minutes, most of it the key generator on the RTL; twenty-five
# the first time.
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

# The decision, on the host, and wrong decisions it must refuse.
mkdir -p build
verdicttest() { # dir holding verdict.h
    cc -O2 -Wall -Werror -I "$1" -o "$1/verdicttest" host/verdicttest.c && "$1/verdicttest"
}
work="$(mktemp -d)"; cp shell/verdict.h "$work/"
verdicttest "$work" || FAILED=1
rm -rf -- "$work"
verdict_mutant() { # what sed
    local work; work="$(mktemp -d)"
    cp shell/verdict.h "$work/"
    sed -i "$2" "$work/verdict.h"
    if cmp -s "$work/verdict.h" shell/verdict.h; then
        fail "verdict.h is caught when $1" "the sed changed nothing"
    elif verdicttest "$work" > /dev/null 2>&1; then
        fail "verdict.h is caught when $1" "every case still passed"
    else
        pass "verdict.h is caught when $1"
    fi
    rm -rf -- "$work"
}
verdict_mutant "it does not count the runs" 's/    if (ran != n) return V_CHECK;//'
verdict_mutant "it ignores a failed check" 's/        if (res\[i\].failed) return V_CHECK;//'
verdict_mutant "it does not ask that every kind ran" 's/        if (first\[k\] == NONE) return V_CHECK;//'
verdict_mutant "it does not compare the key generations" 's/if (c != res\[first\[KEYGEN\]\].cycles) keygen_all = 0;//'
verdict_mutant "it blames the first key generation when the others differ too" \
    's/!keygen_all \&\& keygen_rest \&\& sign_all/!keygen_all \&\& sign_all/'
verdict_mutant "it blames the first key generation when a signature differs too" \
    's/keygen_rest \&\& sign_all \&\& moved/keygen_rest \&\& moved/'
verdict_mutant "it does not compare the signatures" \
    's/} else if (k == SIGN \&\& c != res\[first\[SIGN\]\].cycles) {/} else if (0) {/'
verdict_mutant "it does not compare with the RTL" 's/        if (c != runs\[i\].cycles) rtl = 0;//'
verdict_mutant "it lets a blind measurement through" 's/    if (!moved) return V_BLIND;//'
verdict_mutant "it compares one run short" \
    '0,/for (uint32_t i = 0; i < n; i++)/!s/for (uint32_t i = 0; i < n; i++)/for (uint32_t i = 0; i + 1 < n; i++)/'
verdict_mutant "it says slow off the RTL's numbers" 's/return rtl ? V_SLOW : V_NOT_RTL;/return V_SLOW;/'
verdict_mutant "it times the warm-up too" \
    '0,/if (k == KEYGEN_WARM) continue;/!s/        if (k == KEYGEN_WARM) continue;//'
verdict_mutant "it does not check the warm-up" \
    's/        if (res\[i\].failed) return V_CHECK;/        if (res[i].failed \&\& runs[i].kind != KEYGEN_WARM) return V_CHECK;/'

source ../../tools/hazard3/shell/shell.sh
if [[ "$(../../tools/lean/lean.sh version 2>&1)" != Lean* ]] || ! "$SHELL_SIM" ready; then
    echo "SKIP  the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

if ./build.sh > build/build.txt; then
    pass "the shell builds for the chip and for the RTL, the chip's $(stat -c %s build/exp212.bin) bytes in its 32 KiB"
else
    fail "the shell builds" "$(tail -3 build/build.txt)"
    exit 1
fi
runs="$(grep -c ' seed ' build/chip/gen.txt)"
if [[ "$runs" == 34 ]]; then
    pass "gen.py: 16 seeds and a warm-up, 34 runs on the model — code 0, one count per kind, the tree mss.py's — and the RTL's minstret count + 3 + 4 S"
else
    fail "gen.py ran 34 runs" "$runs"
fi
python3 ../../tools/hazard3/shell/uf2check.py build/exp212.uf2 build/exp212.bin \
    "$(llvm-nm build/chip/shell.elf | awk '$3 == "_start" {print $1}')" 32768 || FAILED=1

if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp212.uf2 | cut -d' ' -f1)" == "$(cat exp212.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp212.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# The RTL: RUN_ i failed mcycle minstret, per run; then REPT verdict.
got="$(shell_words build/sim.bin 2000000000)"
echo "$got" > build/sim-words.txt
want=""
i=0
while read -r _ _ _ _ _ _ _ _ _ _ instret _ cycles; do
    want+="$(printf '52554e5f %08x 00000000 %08x %08x ' "$i" "$cycles" "$instret")"
    i=$((i + 1))
done < <(grep ' seed ' build/sim/gen.txt)
want+="52455054 00000000 exit=0 "
if [[ "$got" == "$want" ]]; then
    pass "on the RTL the shell passes every check of all $i runs, reads the RTL harness's mcycle on each, and says slow"
else
    fail "on the RTL the shell says slow" "$got"
fi

exit "$FAILED"
