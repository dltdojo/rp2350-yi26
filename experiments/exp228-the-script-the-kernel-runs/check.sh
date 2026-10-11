#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp228 quick check — everything that needs no board.
#
#   1. proof/Script.lean checks, on Lean's own axioms: started at base with the
#      region as `Input` describes it — the kernel and its table, a script of
#      at most 1020 bytes, a stack of at most 32 elements of at most 80 bytes —
#      the RV32IM kernel halts, and its exit code is the specification's
#      verdict (kernel_verdict), whatever hashes and signature answers the
#      shell gives. Wrong kernels and wrong claims are refused, the first
#      ENCODE among them. kernel.py writes what the proof holds, and
#      kernel.bin is what the proof writes;
#   2. the specification, run, agrees with script.py on every hand case, 672
#      of arithmetic at the edges and 300 fuzzed;
#   3. the Lean model and the Hazard3 RTL halt with script.py's verdict on all
#      of those, run as images;
#   4. the shell's BIP340 (shell/bip340.c), on this machine, gives every one of
#      BIP340's test vectors its result, and 200 signatures reference.py made,
#      half with a bit flipped;
#   5. the shell builds for the chip, into the first 32 KiB of flash, and its
#      UF2 reads back as built — byte for byte the committed one when the
#      toolchain is the recorded one;
#   6. on the RTL the shell runs every hand case, answering HASHB with
#      SHA-256 and CHECKSIG with BIP340, and each halts with its verdict and
#      the model's count; wrong shells are caught;
#   7. every log a phone gave back (board/*.txt): each CASE line its case's
#      verdict, minstret and signatures (board.py).
#
# What none of it reaches: the chip running it, and a phone reading it; a
# pasted log is what one did, once.
#
# Needs Lean (tools/lean/setup.sh), the Hazard3 testbench
# (tools/hazard3/setup.sh), a host C compiler, clang, lld, llvm-objcopy, cargo
# and python3. Without Lean or the testbench it says SKIP. About fifteen
# minutes: the proof is checked whole three times (check, the kernel's bytes,
# the specification run) and once more for each wrong version, two at a time,
# unless run.sh has just judged them.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=2
LIFELINE="no: a C shell, not crates/lifeline — BOOTSEL by hand is the way back"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="webusb"
USB_RUNS_ON="own"
usb_check

LEAN=../../tools/lean/lean.sh
export LEAN_JOBS="${LEAN_JOBS:-2}"   # each wrong version is the whole proof: two at a time fit

$LEAN check proof/Script.lean || FAILED=1
$LEAN mutants proof/Script.lean || FAILED=1

if python3 kernel.py --check; then
    pass "proof/Script.lean's kernel is what kernel.py writes from its labels"
else
    fail "proof/Script.lean's kernel is what kernel.py writes from its labels"
fi

SIM=../../tools/hazard3/sim.sh
source ../../tools/hazard3/shell/shell.sh
if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! $SIM ready; then
    echo "SKIP  the specification run, the differential and the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

work="$(mktemp -d)"
$LEAN exec proof/Script.lean "$work/kernel.bin" > /dev/null
if cmp -s "$work/kernel.bin" kernel.bin && [[ "$(sha256sum kernel.bin | cut -d' ' -f1)" == "$(cat kernel.sha256)" ]]; then
    pass "kernel.bin is what proof/Script.lean writes, $(stat -c %s kernel.bin) bytes, and kernel.sha256 is its hash"
else
    fail "kernel.bin is what proof/Script.lean writes"
fi
python3 differential/spec.py "$LEAN" 300 || FAILED=1
python3 differential/differential.py "$($LEAN exe rv32run)" kernel.bin 300 || FAILED=1
python3 differential/bip340.py cc "$work" || FAILED=1
rm -rf -- "$work"

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/exp228.bin) of the 32768 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi
python3 ../../tools/hazard3/shell/uf2check.py build/exp228.uf2 build/exp228.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 32768 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp228.uf2 | cut -d' ' -f1)" == "$(cat exp228.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp228.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# Every case on the RTL: CASE i code want minstret sigs valid, then DONE.
got="$(shell_words build/sim.bin 4000000000)"
if python3 - "$got" <<'PY'
import re, sys
words = sys.argv[1].split()
want = [l for l in open("build/expect.h") if l.startswith('    {"')]
rows, i = [], 0
while i < len(words) and words[i] == "43415345":
    rows.append([int(w, 16) for w in words[i + 1:i + 7]])
    i += 7
ok = len(rows) == len(want) and words[i:] == ["444f4e45", f"{len(want):08x}", "exit=0"]
for k, (row, line) in enumerate(zip(rows, want)):
    w, instret = [int(x) for x in re.findall(r", (\d+)", line)[-2:]]
    ok &= row[0] == k and row[1] == w and row[2] == w and row[3] == instret
sys.exit(0 if ok else 1)
PY
then
    pass "on the RTL the shell runs all $(grep -c '^    {"' build/expect.h) cases, SHA-256 and BIP340 answering the calls, each halting with script.py's verdict and the model's count"
else
    fail "on the RTL the shell runs every case to its verdict" "$got"
fi

# Every log a phone gave back: each CASE line its case's verdict, minstret and
# signatures, each ROUND line closing a round, nothing dropped.
shopt -s nullglob
logs=(board/*.txt)
if (( ${#logs[@]} )); then
    python3 board.py build/expect.h "${logs[@]}" || FAILED=1
    if python3 board.py build/expect.h <(sed '0,/^CASE 00000007 00000012 00000004 00000004 000004a0/s//CASE 00000007 00000012 00000004 00000004 000004a1/' board/round1-log.txt) > /dev/null; then
        fail "board.py catches a log one instruction off for one case" "it passed"
    else
        pass "board.py catches a log one instruction off for one case"
    fi
else
    echo "SKIP  checking a phone's log: none recorded yet (board/*.txt)"
fi

# Wrong shells and wrong expectations: each is caught by the check it names.
side_by_side_begin
side_by_side shell_mutant "kernel.sha256 is not kernel.bin's hash — check 1" expect.h \
    's/KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/KERNEL_SHA[32] = {0x00/' "43415345 00000000 00000000 00000000 0000006f 00000000 00000000 4641494c 00000001 "
side_by_side shell_mutant "the first case is said to be rejected — check 2" expect.h \
    's/^    {"one", \([0-9]*\), \([0-9]*\), \([0-9]*\), \([0-9]*\), 0,/    {"one", \1, \2, \3, \4, 11,/' "43415345 00000000 00000000 0000000b "
side_by_side shell_mutant "the chip is asked to count one more for the first case — check 3" expect.h \
    's/^\(    {"one", .*\), 111},$/\1, 112},/' "43415345 00000000 00000000 00000000 0000006f 00000000 00000000 4641494c 00000003 "
side_by_side shell_mutant "HASHB hashes one byte too few — check 2, where a hash is compared" shell.c \
    's/sha256((const uint8_t \*)x\[10\], x\[11\], (uint8_t \*)x\[12\]);/sha256((const uint8_t *)x[10], x[11] - (x[11] > 0), (uint8_t *)x[12]);/' \
    "*4641494c 00000002 "
side_by_side shell_mutant "CHECKSIG says yes to every signature — check 2, at the invalid one" shell.c \
    's/x\[10\] = bip340_verify((const uint8_t \*)x\[10\], MSG, 32, (const uint8_t \*)x\[11\]) ? 1 : 0;/x[10] = 1;/' \
    "*4641494c 00000002 "
side_by_side shell_mutant "BIP340's challenge leaves the key out — check 2, at the first valid signature" bip340.c \
    's/data\[32 + i\] = pk\[i\];/data[32 + i] = 0;/' "*4641494c 00000002 "
side_by_side shell_mutant "the shell itself traps in step 3 — a fault, not a check" shell.c \
    's/^    step = 3;$/    step = 3;\n    __asm__ volatile (".word 0");/' "4641554c 00000003 00000002 "
side_by_side_end

exit "$FAILED"
