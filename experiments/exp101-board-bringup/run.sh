#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp101-board-bringup — interactive bring-up check for a Raspberry Pi Pico 2
# on an Ubuntu host.
#
# What it does, in order:
#   1. Checks the host has the tools this script needs (all stock Ubuntu).
#   2. Guides you into BOOTSEL mode and confirms the board enumerates.
#   3. Finds the RP2350 bootloader drive and shows INFO_UF2.TXT.
#   4. (Optional) Shows `picotool info` if picotool happens to be installed.
#   5. Flashes the prebuilt assets/blink.uf2 and confirms the board rebooted.
#   6. Asks you to confirm the LED is blinking, then prints a summary.
#
# No sudo, no Rust toolchain, no compilation. Run it from this directory:
#   ./run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UF2="${SCRIPT_DIR}/assets/blink.uf2"

BOOTSEL_VIDPID="2e8a:000f"   # Raspberry Pi RP2350 Boot
DRIVE_LABEL="RP2350"

# ---------- output helpers -------------------------------------------------

BOLD=$'\e[1m'; GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'

RESULTS=()

pass() { echo "  ${GREEN}PASS${RESET}  $1"; RESULTS+=("PASS  $1"); }
fail() { echo "  ${RED}FAIL${RESET}  $1"; RESULTS+=("FAIL  $1"); }
skip() { echo "  ${YELLOW}SKIP${RESET}  $1"; RESULTS+=("SKIP  $1"); }
info() { echo "        $1"; }

step() {
    echo
    echo "${BOLD}== Step $1: $2${RESET}"
}

die() {
    echo
    echo "${RED}${BOLD}Stopping here.${RESET} $1"
    echo "Fix the issue above and re-run ./run.sh — it is safe to run any number of times."
    exit 1
}

prompt_enter() {
    # Reads from the terminal even if stdin is redirected.
    read -r -p "        --> $1 Press Enter when done. " _ < /dev/tty
}

prompt_yn() {
    local answer
    read -r -p "        --> $1 [y/n] " answer < /dev/tty
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# ---------- device helpers -------------------------------------------------

in_bootsel() { lsusb -d "${BOOTSEL_VIDPID}" > /dev/null 2>&1; }

# Prints the block device (e.g. sda1) carrying the RP2350 boot drive, if any.
boot_partition() {
    lsblk -rno NAME,LABEL 2>/dev/null | awk -v l="${DRIVE_LABEL}" '$2 == l {print $1; exit}'
}

# Prints the mount point of the RP2350 boot drive, if mounted.
boot_mountpoint() {
    lsblk -rno LABEL,MOUNTPOINT 2>/dev/null \
        | awk -v l="${DRIVE_LABEL}" '$1 == l && $2 != "" {print $2; exit}' \
        | sed 's/\\x20/ /g'
}

wait_for() {
    # wait_for <seconds> <function> — polls once a second.
    local seconds="$1" fn="$2" i
    for ((i = 0; i < seconds; i++)); do
        if "$fn"; then return 0; fi
        sleep 1
    done
    "$fn"
}

bootsel_gone() { ! in_bootsel; }

# ---------- Step 1: host tools ---------------------------------------------

step 1 "Check host tools"

HOST_OK=1
for tool in lsusb lsblk udisksctl; do
    if command -v "$tool" > /dev/null 2>&1; then
        pass "$tool found"
    else
        fail "$tool not found"
        HOST_OK=0
    fi
done
if [[ $HOST_OK -eq 0 ]]; then
    info "On Ubuntu: sudo apt install usbutils util-linux udisks2"
    die "Missing host tools."
fi

if [[ ! -f "$UF2" ]]; then
    fail "assets/blink.uf2 not found"
    die "The prebuilt firmware is missing — did the clone complete? See assets/README.md to rebuild it."
fi
pass "assets/blink.uf2 present ($(stat -c%s "$UF2") bytes)"

# ---------- Step 2: get the board into BOOTSEL mode ------------------------

step 2 "Put the Pico 2 into BOOTSEL mode"

if in_bootsel; then
    pass "Board is already in BOOTSEL mode (USB ${BOOTSEL_VIDPID})"
else
    info "The Pico 2 has one button, labelled ${BOLD}BOOTSEL${RESET}, next to the USB connector."
    info "1. Unplug the board (if plugged in)."
    info "2. Hold the BOOTSEL button down."
    info "3. While holding it, plug the USB cable into this computer."
    info "4. Release the button."
    prompt_enter "Do that now."
    echo "        Waiting up to 10 s for the board to enumerate..."
    if wait_for 10 in_bootsel; then
        pass "Board enumerated as USB ${BOOTSEL_VIDPID} (Raspberry Pi RP2350 Boot)"
    else
        fail "No USB device ${BOOTSEL_VIDPID} appeared"
        info "Most common cause: a charge-only USB cable. Try a different cable —"
        info "it must be a data cable. Also try another USB port, and make sure"
        info "you keep BOOTSEL held until AFTER the cable is plugged in."
        die "Board not detected."
    fi
fi
info "lsusb says: $(lsusb -d ${BOOTSEL_VIDPID})"

# ---------- Step 3: find the boot drive and read INFO_UF2.TXT --------------

step 3 "Find the RP2350 boot drive"

PART="$(boot_partition || true)"
if [[ -z "$PART" ]]; then
    fail "No block device labelled ${DRIVE_LABEL} found"
    die "The board enumerated but no boot drive appeared. Unplug, redo Step 2, and re-run."
fi
pass "Boot drive found: /dev/${PART}"

MP="$(boot_mountpoint || true)"
if [[ -z "$MP" ]]; then
    info "Drive is not mounted yet — asking udisks to mount it (no sudo needed)..."
    udisksctl mount -b "/dev/${PART}" > /dev/null
    MP="$(boot_mountpoint || true)"
fi
if [[ -z "$MP" ]]; then
    fail "Could not mount /dev/${PART}"
    die "Try opening the drive once in your file manager, then re-run."
fi
pass "Mounted at: ${MP}"

if [[ -f "${MP}/INFO_UF2.TXT" ]]; then
    pass "INFO_UF2.TXT is readable:"
    sed 's/^/          | /' "${MP}/INFO_UF2.TXT"
    if grep -q "RP2350" "${MP}/INFO_UF2.TXT"; then
        pass "Bootloader identifies the chip as RP2350"
    else
        fail "INFO_UF2.TXT does not mention RP2350 — is this a Pico 1 (RP2040)?"
        die "This repository targets the Pico 2 (RP2350) only."
    fi
else
    fail "INFO_UF2.TXT not found on the drive"
    die "Unexpected drive contents."
fi

# ---------- Step 4: picotool (optional) ------------------------------------

step 4 "Query the chip with picotool (optional)"

if command -v picotool > /dev/null 2>&1; then
    if picotool info 2>/dev/null; then
        pass "picotool can talk to the board"
    else
        skip "picotool is installed but could not access the board (udev rules?) — not required for this experiment"
    fi
else
    skip "picotool not installed — not required for this experiment; a later experiment sets it up"
fi

# ---------- Step 5: flash the prebuilt blink firmware ----------------------

step 5 "Flash the prebuilt blink firmware"

info "About to copy assets/blink.uf2 to ${MP}."
info "This overwrites whatever firmware is currently on the board — for a"
info "brand-new Pico 2 there is nothing on it yet, so nothing is lost, and"
info "the ROM bootloader itself can never be overwritten."
if ! prompt_yn "Flash it now?"; then
    skip "Flashing declined by user"
    die "Nothing flashed. Re-run when ready."
fi

cp "$UF2" "${MP}/"
sync
pass "blink.uf2 copied"

echo "        Waiting up to 10 s for the board to reboot into the new firmware..."
if wait_for 10 bootsel_gone; then
    pass "Board rebooted — the boot drive is gone, firmware is running"
else
    fail "Board still shows the boot drive after 10 s"
    die "The UF2 may not have been accepted. Redo Step 2 and re-run."
fi

# ---------- Step 6: confirm the LED ----------------------------------------

step 6 "Confirm the LED"

info "Look at the board. The green LED next to the USB connector should be"
info "blinking about once per second."
if prompt_yn "Is the LED blinking?"; then
    pass "LED confirmed blinking"
else
    fail "LED not blinking"
    info "If you have a Pico 2 W: this is expected — its LED is wired to the"
    info "wireless chip, not GPIO25, and this repository currently targets the"
    info "non-W Pico 2 only. On a non-W board, redo Step 2 and re-run."
    die "LED check failed."
fi

info "One more thing worth noticing:"
info "  lsusb no longer shows the board at all — the blink firmware has no"
info "  USB function, so the board is invisible to the host while it runs."
info "  This is normal. To get the boot drive back at any time: unplug, hold"
info "  BOOTSEL, plug in. That recovery loop always works; the board cannot"
info "  be bricked."

# ---------- Summary ---------------------------------------------------------

echo
echo "${BOLD}== Summary ==${RESET}"
for r in "${RESULTS[@]}"; do
    echo "  $r"
done
echo
echo "${GREEN}${BOLD}exp101 complete.${RESET} Your board, cable, and host all work."
echo "Next: exp102 — build this exact same blink from source with Rust + Embassy."
