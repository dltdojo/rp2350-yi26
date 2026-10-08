#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp223 quick check — the half that needs no board.
#
#   1. proof/Condition.lean checks, on Lean's own axioms: in a 128 KiB region,
#      the kernel runs exp222's health tests over 1024 samples and halts with
#      1 after exactly 17425 instructions having written nothing, or runs
#      exp208's SHA-256 over the same samples and halts with 0 after exactly
#      334284, the digest SHA-256 of their 4096 bytes and nothing else
#      changed but its scratch; wrong kernels and wrong claims are refused;
#      kernel.bin is the bytes it writes;
#   2. the differential: on fourteen streams, edge cases among them, the
#      Lean model and the Hazard3 RTL halt as exp114's tests in Python say,
#      and when they pass, both digests are hashlib's;
#   3. the shell builds for the chip, into the first 16 KiB of flash, and its
#      UF2 reads back as built — byte for byte the committed one when the
#      toolchain is the recorded one;
#   4. on the RTL the kernel runs for real on three sources from a stand-in
#      TRNG: a good one is conditioned, its digest sha256.c's, and both broken
#      sources are withheld; a TRNG giving all ones is withheld; one giving
#      nothing is said so; wrong shells are caught.
#
# Whether the chip's TRNG passes, and the chip's SHA-256 block agrees with the
# kernel, is the board's: a person reads the LED.
#
# Needs Lean (tools/lean/setup.sh), the Hazard3 testbench
# (tools/hazard3/setup.sh), clang, lld, llvm-objcopy, cargo and python3.
# Without them it says SKIP. Half an hour, most of it the mutants and the
# RTL hashing its 128 KiB region.
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

$LEAN check proof/Condition.lean || FAILED=1
$LEAN mutants proof/Condition.lean || FAILED=1

SIM=../../tools/hazard3/sim.sh
source ../../tools/hazard3/shell/shell.sh
if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! $SIM ready; then
    echo "SKIP  the differential and the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

work="$(mktemp -d)"
$LEAN exec proof/Condition.lean "$work/kernel.bin" > /dev/null
if cmp -s "$work/kernel.bin" kernel.bin && [[ "$(sha256sum kernel.bin | cut -d' ' -f1)" == "$(cat kernel.sha256)" ]]; then
    pass "kernel.bin is what proof/Condition.lean writes, $(stat -c %s kernel.bin) bytes, and kernel.sha256 is its hash"
else
    fail "kernel.bin is what proof/Condition.lean writes"
fi
# The theorem is about the pieces at 0, 0x1000 and 0x2000; the file is them.
if python3 - "$work/sha.bin" <<'PY'
import subprocess, sys
k = open("kernel.bin", "rb").read()
subprocess.run(["../../tools/lean/lean.sh", "exec", "../exp208-the-hash-the-kernel-computes/proof/Sha.lean",
                "kernel", sys.argv[1]], capture_output=True)
sha = open(sys.argv[1], "rb").read()
ok = len(sha) == 1008 and k[0x1000:0x1000 + len(sha)] == sha and not any(k[136:0x1000]) \
    and not any(k[0x1000 + len(sha):0x2000]) and len(k) == 0x2000 + 292
sys.exit(0 if ok else 1)
PY
then pass "kernel.bin holds exp208's sha.bin, byte for byte, at 0x1000, and zeros between the pieces"
else fail "kernel.bin holds exp208's sha.bin at 0x1000"; fi
python3 differential/differential.py "$($LEAN exe rv32run)" || FAILED=1

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/exp223.bin) of the 16384 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi
python3 ../../tools/hazard3/shell/uf2check.py build/exp223.uf2 build/exp223.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 16384 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp223.uf2 | cut -d' ' -f1)" == "$(cat exp223.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp223.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# The RTL: REPT verdict source failed a0 minstret cause.
said=(
    "a stand-in TRNG that works: its samples pass and their digest is sha256.c's, both broken sources are withheld, each check as conditions says — ok"
    "a stand-in TRNG giving all ones: the kernel, run for real, withholds its digest at minstret 17428 — verdict 3"
    "a stand-in TRNG giving nothing: verdict 2, before the kernel runs"
)
want=(
    "52455054 00000000 00000003 00000000 00000000 00000000 00000000 exit=0 "
    "52455054 00000003 00000000 00000000 00000001 00004414 00000008 exit=3 "
    "52455054 00000002 00000000 00000000 00000000 00000000 00000000 exit=2 "
)
for d in 0 1 2; do
    ./build.sh sim shell build "$work/s$d" "$d" 2> /dev/null
    got="$(shell_words "$work/s$d.bin" 2000000000)"
    if [[ "$got" == "${want[$d]}" ]]; then pass "on the RTL, against ${said[$d]}"
    else fail "on the RTL, against ${said[$d]}" "$got"; fi
done
rm -rf -- "$work"

# Wrong shells and wrong expectations, against the stand-in that works.
shell_mutant "kernel.sha256 is not kernel.bin's hash — verdict 1, check 1" expect.h \
    's/KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/KERNEL_SHA[32] = {0x00/' "52455054 00000001 00000000 00000001 "
shell_mutant "the chip is asked to count one more when healthy — verdict 1, check 3" expect.h \
    's/#define INSTRET_PASS 334287u/#define INSTRET_PASS 334288u/' "52455054 00000001 00000000 00000003 "
shell_mutant "the digest is held against SHA-256 of one block fewer — verdict 1, check 4" shell.c \
    's/sha_ok = board_sha(r + SAMPLES_OFF, 4 \* N, want);/sha_ok = board_sha(r + SAMPLES_OFF, 4 * N - 64, want);/' \
    "52455054 00000001 00000000 00000004 "
shell_mutant "the digest and its scratch are not cleared before the region is hashed again — verdict 1, check 5" shell.c \
    's/^        for (uint32_t i = DIGEST_OFF; i < SCRATCH_END; i++) v\[i\] = 0;$/        (void)v;/' \
    "52455054 00000001 00000000 00000005 "
shell_mutant "the shell itself traps in step 3 — a fault, not a verdict" shell.c \
    's/^    step = 3;$/    step = 3;\n    __asm__ volatile (".word 0");/' "4641554c 00000003 00000002 "

exit "$FAILED"
