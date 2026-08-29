#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp101 quick check — non-interactive verdict, no prompts, no changes.
# Answers one question: can this host see a Pico 2 in BOOTSEL mode right now?
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed
#
# New here? Run ./run.sh instead — it walks you through every step.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
require_supported_platform

PRESENCE=2   # a hand on BOOTSEL while the cable goes in; lsusb and lsblk do the rest
LIFELINE="no: no firmware of its own"
presence_check
lifeline_check

USB_IFACE="bootrom"
USB_CARRIES="descriptors+files"
USB_HOST="bootrom"
USB_RUNS_ON="bootrom"
usb_check

# 1. Host tools (all stock Ubuntu; else: sudo apt install usbutils util-linux udisks2)
for tool in lsusb lsblk udisksctl; do
    command -v "$tool" > /dev/null && pass "$tool installed" \
                                   || fail "$tool installed" "sudo apt install usbutils util-linux udisks2"
done

# 2. Board enumerated in BOOTSEL mode
#
# Three outcomes, not two, because "not in BOOTSEL" has two very different
# causes and only one of them is this experiment's business.
#
# A board running firmware from a later experiment is not a failure of your
# cable, your host or your board — it is a board doing something else, and
# telling you to unplug and hold BOOTSEL would be sending you to fix what is
# not broken. That is the rule lib.sh states about `exp_running`, and this
# check used to be the one place in the repository that broke it: running
# `./check.sh` here after exp103 reported two red lines about hardware that
# was working perfectly.
if lsusb -d 2e8a:000f > /dev/null 2>&1; then
    pass "Pico 2 in BOOTSEL mode (USB 2e8a:000f)"
elif lsusb -d 1209:0001 > /dev/null 2>&1; then
    echo "SKIP  a board is attached and running firmware, not in BOOTSEL"
    echo "      That is not a fault. This experiment is about the bootloader:"
    echo "      to run it, hold BOOTSEL while plugging in — or from a later"
    echo "      experiment's firmware, just run 'yi26 bootsel'."
    exit "$FAILED"
else
    fail "Pico 2 in BOOTSEL mode (USB 2e8a:000f)" "unplug, hold BOOTSEL, plug in"
fi

# 3. Boot drive visible and mounted
# Raw shell on purpose: exp101 runs before Rust exists — see run.sh.
MP="$(lsblk -rno LABEL,MOUNTPOINT 2>/dev/null \
    | awk '$1 == "RP2350" && $2 != "" {print $2; exit}' | sed 's/\\x20/ /g')"
if [[ -n "$MP" ]]; then
    pass "RP2350 boot drive mounted at $MP"
    # 4. It really is an RP2350
    if grep -qs "RP2350" "$MP/INFO_UF2.TXT"; then
        pass "INFO_UF2.TXT identifies an RP2350"
    else
        fail "INFO_UF2.TXT identifies an RP2350" "is this a Pico 1 (RP2040)?"
    fi
else
    fail "RP2350 boot drive mounted" "run ./run.sh to mount it, or open it in your file manager"
fi

exit "$FAILED"
