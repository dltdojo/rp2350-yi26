#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp237 quick check — everything that needs no board:
#
#   1. emutest.py: the monitor (shell/monitor_chip.S) and the payloads run on
#      tools/monitor/emulator.py where the chip puts them; the kernel's three
#      operations, the scrub, three attacks, and nine mutants of the monitor that
#      must each be refused; probe_launch, as built for the chip, run the same way;
#   2. the page's checking (enclave.html, between `BEGIN enclave-check` and `END
#      enclave-check`), under node, fed in 64-byte packets, on fixture-emulator.txt
#      (the emulator's report, printed in the firmware's format) and on seventeen
#      single changes to it, each of which it must refuse; findCdc is
#      tools/pages/log.html's, byte for byte;
#   3. the shell builds for the chip into the first 16 KiB of flash; its UF2 reads
#      back as valid, byte for byte the committed one when built with the recorded
#      toolchain;
#   4. if board/capture.txt exists (a pasted capture from a Pico 2), the page's
#      checking is run on it too.
#
# What none of it reaches: the physical Pico 2 silicon. There is no board/capture.txt
# until someone pastes one, and the README says so.
#
# Needs clang, lld, llvm-objcopy, llvm-nm, python3 and node.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
source ../../tools/pages/pagecheck.sh
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

mkdir -p build

if ! command -v clang > /dev/null; then
    echo "SKIP  the emulator checks: need clang"
else
    ./build.sh > /dev/null || { fail "the shell builds"; exit 1; }
    python3 emutest.py || FAILED=1
    if python3 emutest.py --lines | cmp -s - fixture-emulator.txt; then
        pass "fixture-emulator.txt is what emutest.py prints now"
    else
        fail "fixture-emulator.txt is what emutest.py prints now" "regenerate it: python3 emutest.py --lines > fixture-emulator.txt"
    fi
    # The fixture is printed by Python and the board's lines by C: every key in the one is in the other.
    MISSING=""
    for k in $(grep -oE '[a-z_0-9]+=' fixture-emulator.txt | sort -u | tr -d '='); do
        grep -q "$k" shell/board_chip.c || MISSING="$MISSING $k"
    done
    if [[ -z "$MISSING" ]]; then
        pass "every key of the fixture's lines is one board_chip.c prints"
    else
        fail "every key of the fixture's lines is one board_chip.c prints" "missing from board_chip.c:$MISSING"
    fi
fi

if ! command -v node > /dev/null; then
    echo "SKIP  the page: node is not installed"
else
    page_parses enclave.html build
    page_findcdc enclave.html
    node page_test.mjs enclave.html fixture-emulator.txt || FAILED=1
    if [[ -f board/capture.txt ]]; then
        echo "--- board/capture.txt"
        node page_test.mjs enclave.html board/capture.txt || FAILED=1
    else
        echo "SKIP  board/capture.txt: no capture from a board has been pasted"
    fi
fi

S=../../tools/hazard3/shell
if ! command -v clang > /dev/null || ! command -v llvm-nm > /dev/null; then
    echo "SKIP  the shell: needs clang and llvm-nm"
    exit "$FAILED"
fi

if ./build.sh > /dev/null; then
    BIN_SIZE=$(stat -c %s build/exp237.bin)
    pass "the shell builds for the chip into ${BIN_SIZE} of the 16384 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi

ENTRY_POINT="$(llvm-nm build/exp237.elf | awk '$3 == "_start" {print $1}')"
python3 "$S/uf2check.py" build/exp237.uf2 build/exp237.bin "$ENTRY_POINT" 16384 0x20030000 || FAILED=1

if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    CURRENT_HASH="$(sha256sum build/exp237.uf2 | cut -d' ' -f1)"
    RECORDED_HASH="$(cat exp237.uf2.sha256)"
    if [[ "$CURRENT_HASH" == "$RECORDED_HASH" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp237.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes (got $CURRENT_HASH)"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

exit "$FAILED"
