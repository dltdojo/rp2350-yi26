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

# 1. Host tools (all stock Ubuntu; else: sudo apt install usbutils util-linux udisks2)
for tool in lsusb lsblk udisksctl; do
    command -v "$tool" > /dev/null && pass "$tool installed" \
                                   || fail "$tool installed" "sudo apt install usbutils util-linux udisks2"
done

# 2. Board enumerated in BOOTSEL mode
if lsusb -d 2e8a:000f > /dev/null 2>&1; then
    pass "Pico 2 in BOOTSEL mode (USB 2e8a:000f)"
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
