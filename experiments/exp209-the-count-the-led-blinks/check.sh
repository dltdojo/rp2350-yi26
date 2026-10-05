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
#   4. the same shell, built for the Hazard3 RTL, gives the verdict `ok`: all
#      six checks pass and minstret is 108, the RTL harness's count;
#   5. wrong shells each turn the verdict to not-ok — the bit the LED blinks —
#      except a PMP mismatch, which by design is reported but does not;
#   6. a shell that traps itself is reported as a fault, not a verdict.
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
source ../../tools/hazard3/shell/shell.sh
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
python3 ../../tools/hazard3/shell/uf2check.py build/exp209.uf2 build/exp209.bin \
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

# The RTL: REPT ok failed minstret pmpcfg0 pmpaddr0^want a0 cause.
got="$(shell_words build/sim.bin)"
harness="$($SIM run ../exp203-the-count-the-proof-promised/kernel.bin | sed -n 's/.*instret=\([0-9]*\).*/\1/p')"
if [[ "$got" == "52455054 00000001 00000000 0000006c 0000001f 00000000 "*"exit=0 " && "$harness" == 108 ]]; then
    pass "on the RTL the shell's verdict is ok: all six checks pass, PMP reads back as written, minstret = 108"
else
    fail "on the RTL the shell's verdict is ok, minstret 108" "$got; harness $harness"
fi

# Wrong shells: each must be caught by the check it breaks.
NOT_OK="52455054 00000000 "
shell_mutant "kernel.sha256 is not kernel.bin's hash — not ok" expect.h \
    's/KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/KERNEL_SHA[32] = {0x00/' "$NOT_OK"
shell_mutant "HALT is looked for under t0 = 2 — not ok" shell.c \
    's/int halted = cause == 8 \&\& x\[5\] == 1;/int halted = cause == 8 \&\& x[5] == 2;/' "$NOT_OK"
shell_mutant "the result is expected to be 1 — not ok" shell.c \
    's/halted \&\& x\[10\] == 0,/halted \&\& x[10] == 1,/' "$NOT_OK"
shell_mutant "the source is looked for 64 bytes late — not ok" expect.h \
    's/#define SRC_OFF 0x1000/#define SRC_OFF 0x1040/' "$NOT_OK"
shell_mutant "the model's region hash is not the model's — not ok" expect.h \
    's/REGION_SHA\[32\] = {0x[0-9a-f][0-9a-f]/REGION_SHA[32] = {0x00/' "$NOT_OK"
shell_mutant "the chip is asked to count 107 — not ok" expect.h \
    's/#define EXPECT_INSTRET 108u/#define EXPECT_INSTRET 107u/' "$NOT_OK"
shell_mutant "PMP entry 0 is expected to say something else — reported as check 2, still ok" shell.c \
    's/res.pmpcfg == 0x1f \&\& res.pmpaddr_xor == 0/res.pmpcfg == 0x1e \&\& res.pmpaddr_xor == 0/' "52455054 00000001 00000002 "
shell_mutant "the shell itself traps in step 2 — a fault, not a verdict" shell.c \
    's/^    step = 2;$/    step = 2;\n    __asm__ volatile (".word 0");/' "4641554c 00000002 00000002 "

exit "$FAILED"
