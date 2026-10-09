#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp224 quick check — the half that needs no board.
#
#   1. proof/Judge.lean checks, on Lean's own axioms: the judge reads three
#      records of facts and halts with exactly the verdict its specification
#      gives — exp223's five checks per record, the first failing record, the
#      TRNG withheld, a broken source let through — whatever the records
#      hold, writing nothing; wrong judges and wrong claims are refused;
#      judge.bin is the bytes it writes;
#   2. the differential: on sixty sets of records the Lean model and the
#      Hazard3 RTL halt as the specification in Python says;
#   3. the shell builds for the chip, into the first 16 KiB of flash, and its
#      UF2 reads back as built — byte for byte the committed one when the
#      toolchain is the recorded one;
#   4. on the RTL, exp223's kernel and the judge run for real on three
#      sources from a stand-in TRNG: a good one, all ones, nothing; wrong
#      shells are caught by the judge, not by the shell; and a shell that
#      lies is not caught, which is the boundary this experiment draws.
#
# Whether the chip agrees is the board's: a person reads the LED.
#
# Needs Lean (tools/lean/setup.sh), the Hazard3 testbench
# (tools/hazard3/setup.sh), clang, lld, llvm-objcopy, cargo and python3.
# Without them it says SKIP. Half an hour, most of it the RTL hashing the
# 128 KiB region for each wrong shell.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=3
LIFELINE="no: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back"
presence_check
lifeline_check

USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

LEAN=../../tools/lean/lean.sh

$LEAN check proof/Judge.lean || FAILED=1
$LEAN mutants proof/Judge.lean || FAILED=1

SIM=../../tools/hazard3/sim.sh
source ../../tools/hazard3/shell/shell.sh
if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! $SIM ready; then
    echo "SKIP  the differential and the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

work="$(mktemp -d)"
$LEAN exec proof/Judge.lean "$work/judge.bin" > /dev/null
if cmp -s "$work/judge.bin" judge.bin && [[ "$(sha256sum judge.bin | cut -d' ' -f1)" == "$(cat judge.sha256)" ]]; then
    pass "judge.bin is what proof/Judge.lean writes, $(stat -c %s judge.bin) bytes, and judge.sha256 is its hash"
else
    fail "judge.bin is what proof/Judge.lean writes"
fi
python3 differential/differential.py "$($LEAN exe rv32run)" || FAILED=1

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/exp224.bin) of the 16384 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi
python3 ../../tools/hazard3/shell/uf2check.py build/exp224.uf2 build/exp224.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 16384 0x20060000 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp224.uf2 | cut -d' ' -f1)" == "$(cat exp224.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp224.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# The RTL: REPT verdict source failed code minstret cause — the last three the judge's.
said=(
    "a stand-in TRNG that works: the judge halts with 0 — ok"
    "a stand-in TRNG giving all ones: exp223's kernel withholds, and the judge says so — verdict 3, source 0"
    "a stand-in TRNG giving nothing: verdict 2, from the shell, before anything runs"
)
want=(
    "52455054 00000000 00000000 00000000 00000000 "
    "52455054 00000003 00000000 00000000 00000003 "
    "52455054 00000002 00000000 00000000 00000000 00000000 00000000 exit=2 "
)
for d in 0 1 2; do
    ./build.sh sim shell build "$work/s$d" "$d" 2> /dev/null
    got="$(shell_words "$work/s$d.bin")"
    if [[ "$got" == "${want[$d]}"* ]]; then pass "on the RTL, against ${said[$d]}"
    else fail "on the RTL, against ${said[$d]}" "$got"; fi
done

# Wrong shells and wrong expectations, against the stand-in that works. The
# shell no longer checks anything: each is caught by the judge, whose code
# names the source and the check.
shell_mutant "kernel.sha256 is not exp223's kernel's hash — the judge: source 0, check 1 (code 0x41)" expect.h \
    's/KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/KERNEL_SHA[32] = {0x00/' "52455054 00000001 00000000 00000001 00000041 "
shell_mutant "the chip is asked to count one more when healthy — the judge: source 0, check 3 (code 0x101)" expect.h \
    's/#define INSTRET_PASS 334287u/#define INSTRET_PASS 334288u/' "52455054 00000001 00000000 00000004 00000101 "
shell_mutant "the broken source is made fair, and exp223's kernel lets it through — the judge: verdict 4, source 2 (code 0x14)" shell.c \
    's/^    gather();$/    gather();\n    if (source == 2) for (uint32_t i = 0; i < N; i++) samples[i] = i % 2;/' \
    "52455054 00000004 00000002 00000000 00000014 "
shell_mutant "the digest is held against SHA-256 of one block fewer — the judge: source 0, check 4 (code 0x201)" shell.c \
    's/rec->shaok = board_sha(r + SAMPLES_OFF, 4 \* N, rec->want);/rec->shaok = board_sha(r + SAMPLES_OFF, 4 * N - 64, rec->want);/' \
    "52455054 00000001 00000000 00000008 00000201 "
shell_mutant "the digest and its scratch are not cleared before the region is hashed again — the judge: source 0, check 5 (code 0x401)" shell.c \
    's/^        for (uint32_t i = DIGEST_OFF; i < SCRATCH_END; i++) v\[i\] = 0;$/        (void)v;/' \
    "52455054 00000001 00000000 00000010 00000401 "
shell_mutant "judge.sha256 is not judge.bin's hash — verdict 5, the one check left in the shell" expect.h \
    's/JUDGE_SHA\[32\] = {0x[0-9a-f][0-9a-f]/JUDGE_SHA[32] = {0x00/' "52455054 00000005 00000000 00000000 00000000 "
shell_mutant "the shell itself traps in step 3 — a fault, not a verdict" shell.c \
    's/^    step = 3;$/    step = 3;\n    __asm__ volatile (".word 0");/' "4641554c 00000003 00000002 "

# The boundary: a shell that lies. It writes a byte into the region after
# exp223's kernel has run — memory the theorem says is untouched — and then
# gives the judge the hash from before instead of the hash after. The judge
# believes its facts, so this comes out ok. It is here to say so.
lie="$(mktemp -d)"
cp -r shell "$lie/shell"; cp build/expect.h "$lie/expect.h"
sed -i 's/^    rec->shaok &= board_sha(r, REGION_SIZE, rec->after);$/    v[0x5000] = 1;\n    copy(rec->after, rec->before, 32);/' "$lie/shell/shell.c"
if cmp -s "$lie/shell/shell.c" shell/shell.c; then
    fail "a shell that lies is not caught" "the sed changed nothing"
elif ./build.sh sim "$lie/shell" "$lie" "$lie/sim" 2> /dev/null \
        && [[ "$(shell_words "$lie/sim.bin")" == "52455054 00000000 00000000 00000000 00000000 "* ]]; then
    pass "a shell that lies — scribbles on the region, then hands the judge the hash from before — is NOT caught: verdict 0. The judge can only judge the facts it is given"
else
    fail "a shell that lies is not caught" "$(shell_words "$lie/sim.bin" 2> /dev/null)"
fi
rm -rf -- "$lie" "$work"

exit "$FAILED"
