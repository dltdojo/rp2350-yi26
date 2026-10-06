#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp211 quick check — everything that can be checked without the board. The
# board half is a person pulling the power and reading the LED; see the README.
#
#   1. the model: TLC on every design and attacker in model/, against
#      expected.txt, and every line of code the model stands for still there;
#   2. shell/counter.h on the host, over a fake NOR flash: a power cut at
#      every step and every pair of steps, writes torn three ways, three
#      starting flashes, a flash that takes no program and one that takes
#      part — no leaf twice, every run exhausts — and six wrong counters each
#      caught;
#   3. gen.py: on the Lean model, keygen writes mss.py's tree, and every one
#      of the 16 leaves signs and is accepted by exp206's verifier;
#   4. the shell builds; its UF2, read back independently of partimg, is
#      family `absolute` and exactly the image; with the toolchain recorded in
#      build-toolchain.txt, it is byte for byte the one whose SHA-256 is
#      committed;
#   5. the same shell on the Hazard3 RTL, booted 18 times in one simulation
#      over a flash that outlives each boot, with the power cut in the middle
#      of the first erase, in a window, and in the middle of a claim: every
#      leaf signed once and accepted, the two cut ones wasted, the 17th
#      claim refused.
#
# Needs clang, lld, llvm-objcopy, cargo, a host C compiler, java with
# tools/tlc/setup.sh, Lean (tools/lean/setup.sh) and the Hazard3 testbench
# (tools/hazard3/setup.sh). About fifteen minutes, nearly all of it the RTL.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# A person pulls the power and reads the LED: no UART on this board, no USB
# in this firmware.
PRESENCE=3
LIFELINE="no: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back"
presence_check
lifeline_check

USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

TLC=../../tools/tlc/tlc.sh
if command -v java > /dev/null && [[ -f ../../tools/tlc/tla2tools.jar ]]; then
    "$TLC" parse model || FAILED=1
    "$TLC" cited model || FAILED=1
    "$TLC" check model || FAILED=1
else
    echo "SKIP  the model: needs java and tools/tlc/setup.sh (the network, once)"
fi

# The counter on the host, and wrong counters it must catch.
mkdir -p build
countertest() { # dir holding counter.h
    cc -O2 -Wall -Werror -I "$1" -o "$1/countertest" host/countertest.c && "$1/countertest"
}
work="$(mktemp -d)"; cp shell/counter.h "$work/"
countertest "$work" || FAILED=1
rm -rf -- "$work"
counter_mutant() { # what sed
    local work; work="$(mktemp -d)"
    cp shell/counter.h "$work/"
    sed -i "$2" "$work/counter.h"
    if cmp -s "$work/counter.h" shell/counter.h; then
        fail "the host test catches a counter where $1" "the sed changed nothing"
    elif ! cc -O2 -Wall -Werror -I "$work" -o "$work/countertest" host/countertest.c 2> /dev/null; then
        fail "the host test catches a counter where $1" "it does not build"
    elif "$work/countertest" > /dev/null; then
        fail "the host test catches a counter where $1" "every case still passed"
    else
        pass "the host test catches a counter where $1"
    fi
    rm -rf -- "$work"
}
counter_mutant "a part-written claim reads as free" \
    's/uint32_t claimed = flash_word(ctr_claim_at(i)) != CTR_FREE;/uint32_t claimed = flash_word(ctr_claim_at(i)) == 0;/'
counter_mutant "the claim is not read back" \
    's/return flash_word(ctr_claim_at(c->used)) != CTR_FREE ? CTR_SIGN : CTR_UNWRITTEN;/return CTR_SIGN;/'
counter_mutant "the marker is written before the claims are erased" \
    's/    flash_erase_sector(CTR_CLAIM);/    flash_program_word(CTR_MARK, CTR_MAGIC);\n    flash_erase_sector(CTR_CLAIM);/'
counter_mutant "formatting does not erase the claims" 's/    flash_erase_sector(CTR_CLAIM);//'
counter_mutant "the claims need not be a prefix" 's/            if (gap) return CTR_CORRUPT;//'
counter_mutant "the leaf claimed is not the next one" \
    's/flash_program_word(ctr_claim_at(c->used), 0);/flash_program_word(ctr_claim_at(c->used + 1 < CTR_LEAVES ? c->used + 1 : c->used), 0);/'

source ../../tools/hazard3/shell/shell.sh
if [[ "$(../../tools/lean/lean.sh version 2>&1)" != Lean* ]] || ! "$SHELL_SIM" ready; then
    echo "SKIP  the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

if ./build.sh > build/build.txt; then
    pass "the shell builds for the chip and for the RTL, the chip's $(stat -c %s build/exp211.bin) bytes in its 32 KiB"
else
    fail "the shell builds" "$(tail -3 build/build.txt)"
    exit 1
fi
leaves="$(grep -c '^leaf .* sign halt code=00000000 .* verify halt code=00000000' build/gen.txt)"
if [[ "$leaves" == 16 ]] && grep -q "tree is mss.py's" build/gen.txt; then
    pass "gen.py: on the Lean model keygen writes mss.py's tree, and all 16 leaves sign and are accepted by exp206's verifier"
else
    fail "gen.py: every leaf signs and is accepted" "$leaves"
fi
python3 ../../tools/hazard3/shell/uf2check.py build/exp211.uf2 build/exp211.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 32768 || FAILED=1

if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp211.uf2 | cut -d' ' -f1)" == "$(cat exp211.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp211.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# The RTL: 18 boots of one script (board_sim.c). Boot 0 is cut in its first
# erase, boot 2 in its window, boot 3 while its claim is written; boots 1
# and 4 to 16 sign leaves 0 and 3 to 15; boot 17 finds every leaf used.
got="$(shell_words build/sim.bin 4000000000)"
echo "$got" > build/sim-words.txt
want="4355545f 00000000 00000002 424f4f54 00000001 00000000 00000000 00000000 00000000 00000000 "
want+="4355545f 00000002 00000003 4355545f 00000003 00000002 "
for boot in $(seq 4 16); do
    leaf=$((boot - 1))
    want+="$(printf '424f4f54 %08x 00000000 %08x %08x %08x 00000002 ' "$boot" "$leaf" "$leaf" $((leaf - 2)))"
done
want+="424f4f54 00000011 00000001 00000010 00000010 0000000e 00000002 52455054 00000001 exit=0 "
if [[ "$got" == "$want" ]]; then
    pass "on the RTL, 18 boots over one flash: cut in the first erase, in a window and mid-claim, 14 leaves signed once and each accepted, 2 wasted, the 17th claim refused"
else
    fail "on the RTL the 18 boots go as the script says" "$got"
fi

exit "$FAILED"
