#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp226 quick check — everything that needs no board.
#
#   1. the USB device's logic (tools/hazard3/shell/usbdev.c), built for this
#      machine: its descriptors field by field and against the tree exp115
#      recorded from a real Pico 2; an enumeration as Linux does it; log.html's
#      own requests; the bulk IN queue. Wrong versions of it are caught;
#   2. the shell builds for the chip, into the first 16 KiB of flash, from
#      exp225's shell/shell.c and expect.h unchanged — and its UF2 reads back
#      as built, byte for byte the committed one when the toolchain is the
#      recorded one;
#   3. on the RTL, which has no USB controller, exp225's shell as exp226
#      compiles it lives exp225's two lives;
#   4. every log a board gave back (board/*.txt) is replayed: each LIFE line is
#      rule30.py's life, with minstret 3082.
#
# What none of it reaches is the controller itself: tools/hazard3/shell/
# usb_chip.c is tried by a board, and the page that reads it is a person's.
#
# Needs clang, lld, llvm-objcopy, a host C compiler, Lean, the Hazard3
# testbench, cargo and python3. Under a minute.
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
USB_CARRIES="descriptors+control+log"
USB_HOST="webusb"
USB_RUNS_ON="own"
usb_check

S=../../tools/hazard3/shell
E=../exp225-the-life-every-beat-proved
PRODUCT="exp226 the shell that speaks"

python3 "$S/usbdev_test.py" "$PRODUCT" 226 ../exp115-webusb-enumerate/README.md || FAILED=1

# Wrong versions of the device's logic: each must be caught by the tests above.
usbdev_mutant() { # what sed
    local work
    work="$(mktemp -d)"
    cp "$S/usbdev.c" "$S/usbdev.h" "$work/"
    sed -i "$2" "$work/usbdev.c"
    if cmp -s "$work/usbdev.c" "$S/usbdev.c"; then
        fail "the tests catch a usbdev.c where $1" "the sed changed nothing"
    elif USBDEV_C="$work/usbdev.c" timeout 60 python3 "$S/usbdev_test.py" "$PRODUCT" 226 > "$work/out" 2>&1; then
        fail "the tests catch a usbdev.c where $1" "every test passed"
    else
        pass "the tests catch a usbdev.c where $1: $(grep -m1 '^FAIL' "$work/out" | sed 's/^FAIL  //')"
    fi
    rm -rf -- "$work"
}
usbdev_mutant "the configuration's length is miscounted, 75 for 70" 's/#define CONFIG_LEN 70/#define CONFIG_LEN 75/'
usbdev_mutant "the address is taken before SET_ADDRESS's status stage" \
    's/^        pending_address = (uint8_t)(value \& 0x7f);$/        pending_address = (uint8_t)(value \& 0x7f); usbhw_set_address(pending_address);/'
usbdev_mutant "the bulk IN endpoint is 0x81, the interrupt endpoint's" 's/7, 0x05, 0x82, 0x02,/7, 0x05, 0x81, 0x02,/'
usbdev_mutant "DTR is read from bit 1, RTS" 's/usbdev.dtr = (uint8_t)(value \& 1);/usbdev.dtr = (uint8_t)((value >> 1) \& 1);/'
usbdev_mutant "a 64-byte answer short of what was asked gets no empty packet after" 's/tx_zlp = len < asked \&\& len % USBDEV_EP0_SIZE == 0 \&\& len > 0;/tx_zlp = 0;/'
usbdev_mutant "the device qualifier is answered with the device descriptor" \
    's/if (type == 0x01 \&\& index == 0) { \*len = sizeof DEVICE; return DEVICE; }/if ((type == 0x01 || type == 0x06) \&\& index == 0) { *len = sizeof DEVICE; return DEVICE; }/'

LEAN=../../tools/lean/lean.sh
SIM=../../tools/hazard3/sim.sh
source ../../tools/hazard3/shell/shell.sh
if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! $SIM ready; then
    echo "SKIP  the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip from exp225's shell.c and expect.h, in $(stat -c %s build/exp226.bin) of the 16384 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi
python3 "$S/uf2check.py" build/exp226.uf2 build/exp226.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 16384 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/exp226.uf2 | cut -d' ' -f1)" == "$(cat exp226.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 exp226.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# The RTL has no USB controller; what it can say is that the shell and kernel
# exp226 compiles are exp225's, living exp225's lives.
want="$(cd "$E" && python3 - <<'PY'
from rule30 import SEED0, history
out, seed = [], SEED0
for r in range(2):
    h = history(seed)
    col = sum(((h[g] >> 16) & 1) << g for g in range(32))
    out += ["4c494645", f"{r:08x}", f"{3082:08x}", f"{h[0]:08x}", f"{h[-1]:08x}", f"{col:08x}"]
    seed = h[-1]
print(" ".join(out) + " exit=0 ")
PY
)"
got="$(shell_words build/sim.bin)"
if [[ "$got" == "$want" ]]; then
    pass "on the RTL, exp225's shell as exp226 builds it lives exp225's two lives, minstret 3082"
else
    fail "on the RTL, exp225's shell lives exp225's two lives" "$got"
fi

# What boards said, replayed.
shopt -s nullglob
logs=(board/*.txt)
if (( ${#logs[@]} )); then
    python3 replay.py "${logs[@]}" || FAILED=1
else
    echo "SKIP  replaying a board's log: none recorded yet (board/*.txt)"
fi

exit "$FAILED"
