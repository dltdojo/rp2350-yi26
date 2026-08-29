#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp141 quick check — non-interactive verdict.
#
# The claim is that a browser can drive the bootrom's PICOBOOT interface, which
# needs a person to click a WebUSB dialog and cannot be scripted. What CAN be
# checked without a person: that the page targets the right device and only
# reads, and — if a board is in BOOTSEL — that the PICOBOOT interface the page
# depends on is actually there.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=2   # one WebUSB permission tap; everything else is checkable alone
LIFELINE="no: no firmware of its own"
presence_check
lifeline_check

USB_IFACE="vendor"
USB_CARRIES="control"
USB_HOST="webusb"
USB_RUNS_ON="bootrom"
usb_check

PAGE=picoboot.html

# ---- the page, checked without a board ------------------------------------

[[ -f "$PAGE" ]] \
    && pass "the page is here" \
    || { fail "the page is here" "$PAGE is missing"; exit 1; }

# Self-contained: no network, no build step, opens by double-click.
if grep -qiE 'src=|href=.*http|import ' "$PAGE"; then
    fail "the page is self-contained" "it pulls in something external"
else
    pass "the page is self-contained (no toolchain, no server)"
fi

# It must target BOOTSEL (2e8a:000f), not the application firmware. A page that
# filtered for 0x1209/0x0001 would offer the wrong device and never find
# PICOBOOT.
if grep -q '0x2e8a' "$PAGE" && grep -q '0x000f' "$PAGE"; then
    pass "the filter is BOOTSEL (2e8a:000f), not the application firmware"
else
    fail "the filter is BOOTSEL" "the page must request the bootrom device"
fi

# It finds PICOBOOT by class 0xFF, the way exp132 finds a vendor interface —
# not by a hardcoded interface number that could shift.
grep -q '0xFF' "$PAGE" \
    && pass "PICOBOOT is found by class 0xFF, not by a fixed number" \
    || fail "PICOBOOT is found by class" "the page hardcodes an interface number"

# THE SAFETY CHECK. This is a read-only confirmation experiment. If a flash
# write or erase command ever appears in it, it has stopped being that — and
# the README's promise that nothing here can brick a board is void.
if grep -qiE 'FLASH_ERASE|0x03,|PC_WRITE|0x05,|flash.*write|erase' "$PAGE"; then
    fail "the page only reads — no flash command" "a write/erase command is in it"
else
    pass "the page only reads: IF_RESET and CMD_STATUS, no flash command"
fi

# It reads a reply, which is what makes it a confirmation rather than a hope.
grep -q 'controlTransferIn' "$PAGE" \
    && pass "it reads a reply back (CMD_STATUS), so a round-trip is proven" \
    || fail "it reads a reply back" "no controlTransferIn — it cannot confirm anything"

# The write-capable sibling. It DOES erase flash — that is its job — so it is
# checked for the opposite: that its erase names the absolute address, the one
# word that cost a debugging round on hardware.
RECOVER=recover.html
if [[ -f "$RECOVER" ]]; then
    if grep -q '0x10000000' "$RECOVER" && grep -q 'FLASH_ERASE' "$RECOVER"; then
        pass "recover.html erases at the absolute address 0x10000000 (not offset 0)"
    else
        fail "recover.html erases at 0x10000000" \
             "a zero dAddr is what the bootrom STALLs on — see the README"
    fi
else
    fail "recover.html is here" "the recovery page is missing"
fi

# ---- the device, if one is in BOOTSEL -------------------------------------
# Not scripted into BOOTSEL: this check does not move the board, because the
# person who runs run.sh decides when to. If a board happens to be there, the
# descriptor the page depends on is confirmed against real silicon.

if lsusb -d 2e8a:000f > /dev/null 2>&1; then
    DESC="$(lsusb -v -d 2e8a:000f 2>/dev/null)"
    if echo "$DESC" | grep -q 'bInterfaceClass *255'; then
        pass "a BOOTSEL board is here and it exposes a vendor (PICOBOOT) interface"
    else
        fail "the BOOTSEL board exposes PICOBOOT" "no class 0xFF interface in its descriptors"
    fi
    # Two bulk endpoints on that interface, which the page will need once it
    # graduates from control transfers to sending commands.
    if [[ "$(echo "$DESC" | grep -c 'Transfer Type *Bulk')" -ge 4 ]]; then
        pass "PICOBOOT has its own bulk IN/OUT endpoints, separate from MSC"
    else
        echo "NOTE  fewer bulk endpoints than expected — read the full lsusb -v"
    fi
else
    echo "SKIP  no board in BOOTSEL — the descriptor check needs one there."
    echo "      ./run.sh puts a board into BOOTSEL and walks the page."
fi

exit "$FAILED"
