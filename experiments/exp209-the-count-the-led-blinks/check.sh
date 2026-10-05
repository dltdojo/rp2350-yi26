#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp209 quick check — everything that can be checked without the board. The
# board half is a person counting an LED; see the README.
#
#   1. the shared SHA-256 agrees with hashlib, and partimg's tests pass;
#   2. the shell builds, fits in flash sector 0, and its UF2 — read back
#      independently of partimg — is family `absolute`, all in sector 0, and
#      starts with a jump to _start and the IMAGE_DEF block that names it;
#   3. with the toolchain recorded in build-toolchain.txt, the UF2 is byte for
#      byte the one whose SHA-256 is committed — the file that was handed over;
#   4. the same shell, built for the Hazard3 RTL, passes all six of its checks
#      and counts minstret = 108, what the RTL harness counts for exp203;
#   5. seven wrong shells are each caught by the check they break;
#   6. the LED's patterns read back, counted as a person counts, as what was
#      blinked.
#
# Needs clang, lld, llvm-objcopy, cargo, a host C compiler, Lean
# (tools/lean/setup.sh) and the Hazard3 testbench (tools/hazard3/setup.sh).
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

SIM=../../tools/hazard3/sim.sh
if [[ "$(../../tools/lean/lean.sh version 2>&1)" != Lean* ]] || ! $SIM ready; then
    echo "SKIP  the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

../../tools/hazard3/sha256-test.sh || FAILED=1
if cargo test -q --offline --manifest-path ../../tools/partimg/Cargo.toml > /dev/null 2>&1; then
    pass "partimg's tests pass, its bin mode among them"
else
    fail "partimg's tests pass"
fi

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/exp209.bin) of sector 0's 4096 bytes"
else
    fail "the shell builds"
    exit 1
fi
python3 host/uf2check.py build/exp209.uf2 build/exp209.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" || FAILED=1

if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp209.uf2 | cut -d' ' -f1)" == "$(cat exp209.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp209.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# The RTL: REPT failed number instret cycles a0 cause.
words() { $SIM bare "$1" --cycles 200000000 | tr '\n' ' '; }
got="$(words build/sim.bin)"
harness="$($SIM run ../exp203-the-count-the-proof-promised/kernel.bin | sed -n 's/.*instret=\([0-9]*\).*/\1/p')"
if [[ "$got" == "52455054 00000000 0000006c 0000006c "*"exit=0 " && "$harness" == 108 ]]; then
    pass "on the RTL the shell passes all six checks and counts minstret = 108, as the RTL harness does"
else
    fail "on the RTL the shell passes all six checks and counts 108" "$got; harness $harness"
fi

# Wrong shells: each must be caught by the check it breaks.
mutant() { # what file sed expected-words
    local work; work="$(mktemp -d)"
    cp -r shell "$work/shell"; cp build/expect.h "$work/"
    local target="$work/shell/$2"; [[ "$2" == expect.h ]] && target="$work/expect.h"
    sed -i "$3" "$target"
    if cmp -s "$target" "$([[ "$2" == expect.h ]] && echo build/expect.h || echo "shell/$2")"; then
        fail "the shell catches a version where $1" "the sed changed nothing"
    elif ./build.sh sim "$work/shell" "$work" "$work/sim.bin" 2> /dev/null && [[ "$(words "$work/sim.bin")" == "$4"* ]]; then
        pass "the shell catches a version where $1"
    else
        fail "the shell catches a version where $1" "$(words "$work/sim.bin" 2>/dev/null)"
    fi
    rm -rf -- "$work"
}
mutant "kernel.sha256 is not kernel.bin's hash — check 1" expect.h \
    's/KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/KERNEL_SHA[32] = {0x00/' "52455054 00000001 "
mutant "PMP entry 0 is expected to say something else — check 2" shell.c \
    's/(csrr(pmpcfg0) \& 0xff) == 0x1f/(csrr(pmpcfg0) \& 0xff) == 0x1e/' "52455054 00000002 "
mutant "HALT is looked for under t0 = 2 — check 3, mcause 8" shell.c \
    's/int halted = cause == 8 \&\& x\[5\] == 1;/int halted = cause == 8 \&\& x[5] == 2;/' "52455054 00000003 00000008 "
mutant "the result is expected to be 1 — check 4" shell.c \
    's/else if (x\[10\] != 0) res.failed = 4;/else if (x[10] != 1) res.failed = 4;/' "52455054 00000004 "
mutant "the source is looked for 64 bytes late — check 5" expect.h \
    's/#define SRC_OFF 0x1000/#define SRC_OFF 0x1040/' "52455054 00000005 "
mutant "the model's region hash is not the model's — check 6" expect.h \
    's/REGION_SHA\[32\] = {0x[0-9a-f][0-9a-f]/REGION_SHA[32] = {0x00/' "52455054 00000006 "
mutant "the shell itself traps in step 2 — a fault, not a failed check" shell.c \
    's/^    step = 2;$/    step = 2;\n    __asm__ volatile (".word 0");/' "4641554c 00000002 00000002 "

if cc -O2 -Wall -Werror -I shell -o build/blinktest host/blinktest.c shell/blink.c; then
    python3 host/blinktest.py build/blinktest | grep -E '^(PASS|FAIL)' || FAILED=1
    [[ ${PIPESTATUS[0]} -eq 0 ]] || FAILED=1
else
    fail "the LED's patterns build for this machine"
fi

exit "$FAILED"
