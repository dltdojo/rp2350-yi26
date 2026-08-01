#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp101 interactive walkthrough — puts your Pico 2 into BOOTSEL mode and
# shows you what the host sees at each step, with the actual commands printed
# so you can learn them as they run. Nothing is flashed; nothing on the board
# changes. Safe to re-run any number of times.
#
#   ./run.sh
#
# In a hurry, or checking a setup you already understand? ./check.sh gives
# a one-screen pass/fail verdict with no interaction.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
require_supported_platform

echo "${BOLD}exp101 — is my Pico 2 alive?${RESET}"
say "This walkthrough proves your board, cable, and this computer all work."
say "It takes about two minutes and changes nothing on the board."

# ---------------------------------------------------------------------------
step 1 "Host tools"

for tool in lsusb lsblk udisksctl; do
    command -v "$tool" > /dev/null \
        || die "'$tool' is missing. Install with: sudo apt install usbutils util-linux udisks2"
done
ok "lsusb, lsblk, udisksctl all present (stock Ubuntu)"

# exp101 uses raw shell rather than the repository's `yi26` helper, on purpose
# and by necessity. This experiment runs before exp102 installs Rust, so it
# cannot depend on a tool that has to be compiled first — and showing `lsusb`,
# `lsblk` and `udisksctl` directly is what this experiment is *for*. Every
# later experiment delegates these to the helper; see ../lib.sh.
bootsel_now() { lsusb -d 2e8a:000f > /dev/null 2>&1; }
mountpoint_now() {
    lsblk -rno LABEL,MOUNTPOINT 2>/dev/null \
        | awk '$1 == "RP2350" && $2 != "" {print $2; exit}' | sed 's/\\x20/ /g'
}

# ---------------------------------------------------------------------------
step 2 "Put the board into BOOTSEL mode"

if bootsel_now; then
    ok "Board is already in BOOTSEL mode — skipping the button dance."
else
    say "The Pico 2 has exactly one button, ${BOLD}BOOTSEL${RESET}, next to the USB port."
    say "Holding it during power-up tells the chip's built-in ROM bootloader to"
    say "present itself as a USB drive instead of running whatever is in flash."
    say ""
    say "  1. Unplug the board if it is plugged in."
    say "  2. Hold BOOTSEL down."
    say "  3. Plug the cable in ${BOLD}while holding${RESET} the button."
    say "  4. Release."
    pause "Do that now."
    say "Watching for the board (up to 10 s)..."
    for _ in {1..10}; do bootsel_now && break; sleep 1; done
    if ! bootsel_now; then
        bad "No board appeared on USB."
        say "The #1 cause is a charge-only USB cable — it powers the board but"
        say "carries no data. Try a different cable, then a different USB port,"
        say "and keep BOOTSEL held until the cable is fully plugged in."
        die "Board not detected."
    fi
fi

say "Here is how the host sees it — this is USB enumeration:"
run_cmd lsusb -d 2e8a:000f
ok "Vendor 2e8a is Raspberry Pi; product 000f is 'RP2350 Boot'."

# ---------------------------------------------------------------------------
step 3 "The boot drive"

say "In BOOTSEL mode the board pretends to be a USB flash drive. Check the"
say "block devices:"
run_cmd lsblk -o NAME,SIZE,LABEL,MOUNTPOINT

MP="$(mountpoint_now)"
if [[ -z "$MP" ]]; then
    PART="$(lsblk -rno NAME,LABEL 2>/dev/null | awk '$2 == "RP2350" {print $1; exit}')"
    [[ -n "$PART" ]] || die "Board is on USB but no drive labelled RP2350 showed up. Unplug and redo Step 2."
    say "The drive exists but is not mounted yet. Mounting (no sudo needed):"
    run_cmd udisksctl mount -b "/dev/${PART}"
    MP="$(mountpoint_now)"
    [[ -n "$MP" ]] || die "Mount did not stick. Open the RP2350 drive once in your file manager, then re-run."
fi
ok "Boot drive mounted at: $MP"

say ""
say "The drive contains a self-description file. Read it:"
run_cmd cat "$MP/INFO_UF2.TXT"
grep -qs "RP2350" "$MP/INFO_UF2.TXT" \
    || die "This board does not identify as RP2350 — a Pico 1 (RP2040)? This repo needs a Pico 2."
ok "The ROM bootloader confirms: this is an RP2350."

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp101 complete — your board, cable, and host all work.${RESET}"
say ""
say "What you just proved:"
say "  1. BOOTSEL mode lives in ROM. It works no matter what is in flash,"
say "     so this board can never be bricked. Unplug → hold BOOTSEL → plug in"
say "     is the recovery loop under every experiment in this repo."
say "  2. 'lsusb -d 2e8a:000f' is how you ask 'is a Pico 2 in BOOTSEL mode?'"
say "  3. That RP2350 drive is the flashing interface: copying a .uf2 file"
say "     onto it writes flash and reboots the board. exp103 does exactly"
say "     that — with a firmware you build yourself (exp102 sets up the tools)."
say ""
say "You can unplug the board now, or leave it — nothing was changed."
say "Quick re-verify anytime: ./check.sh"
