#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp103 interactive walkthrough — build the blink firmware, convert it to
# UF2, flash it through the boot drive from exp101, and watch the LED prove
# the whole toolchain. Needs the Pico 2 (non-W) and the exp102 toolchain.
#
#   ./run.sh
#
# Rebuild-only verdict without a board: ./check.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp103-embassy-blink
UF2=target/exp103-embassy-blink.uf2

echo "${BOLD}exp103 — the LED is the toolchain, proven end to end${RESET}"
say "Source code → ELF → UF2 → boot drive → running firmware. Every arrow"
say "is one step below. The code itself is the walkthrough: read src/main.rs"
say "— every line explains itself."

# ---------------------------------------------------------------------------
step 1 "Toolchain check"

for tool in cargo elf2flash; do
    command -v "$tool" > /dev/null || die "'$tool' missing — run exp102 first (../exp102-rust-toolchain/run.sh)."
done
ok "cargo and elf2flash present."

# ---------------------------------------------------------------------------
step 2 "Compile"

say "cargo cross-compiles src/main.rs for the Cortex-M33 (the .cargo/config"
say "in this directory makes that the default target):"
run_cmd cargo build --release
ok "ELF produced: $ELF ($(stat -c%s "$ELF") bytes)"
say "That ELF is a normal Linux-style executable container — but the boot"
say "drive only eats UF2. One more step."

# ---------------------------------------------------------------------------
step 3 "Convert to UF2"

run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
FAMILY="$(od -An -tx4 -j28 -N4 "$UF2" | tr -d ' ')"
[[ "$FAMILY" == "e48bff59" ]] || die "UF2 family ID is $FAMILY, expected e48bff59 (rp2350-arm-s)."
ok "UF2 produced ($(stat -c%s "$UF2") bytes), family ID e48bff59 = 'RP2350, Arm, secure'."
say "That ID is how the bootloader will know this firmware is meant for it."

# ---------------------------------------------------------------------------
step 4 "Board into BOOTSEL mode"

if in_bootsel; then
    ok "Board is already in BOOTSEL mode."
else
    say "Same dance as exp101: unplug → hold ${BOLD}BOOTSEL${RESET} → plug in → release."
    pause "Do that now."
    say "Watching for the board (up to 10 s)..."
    for _ in {1..10}; do in_bootsel && break; sleep 1; done
    in_bootsel || die "No board on USB (2e8a:000f). Charge-only cable? BOOTSEL released too early?"
    ok "Board enumerated."
fi

MP="$(rp2350_mountpoint)"
if [[ -z "$MP" ]]; then
    PART="$(lsblk -rno NAME,LABEL 2>/dev/null | awk '$2 == "RP2350" {print $1; exit}')"
    [[ -n "$PART" ]] || die "Board on USB but no RP2350 drive. Unplug and redo this step."
    run_cmd udisksctl mount -b "/dev/${PART}"
    MP="$(rp2350_mountpoint)"
    [[ -n "$MP" ]] || die "Mount did not stick. Open the drive in your file manager, then re-run."
fi
ok "Boot drive at: $MP"

# ---------------------------------------------------------------------------
step 5 "Flash — and watch the drive vanish"

say "Flashing is the file copy exp101 promised. Watch the board's LED and"
say "keep an eye on the drive — the moment the copy lands, the drive"
say "disappears. That is the success signal, not a failure."
confirm "Copy the firmware onto the drive now?" || die "Nothing flashed."
run_cmd cp "$UF2" "$MP/"
sync 2>/dev/null || true
say "Waiting for the board to reboot into your firmware (up to 10 s)..."
for _ in {1..10}; do in_bootsel || break; sleep 1; done
in_bootsel && die "Board still in BOOTSEL mode — the UF2 was not accepted. Redo step 4 and re-run."
ok "The vanishing act: boot drive gone, board rebooted into YOUR code."

# ---------------------------------------------------------------------------
step 6 "The proof"

say "Look at the board."
confirm "Is the LED blinking, once per second?" || {
    bad "No blink."
    say "On a Pico 2 W this is expected — its LED is not on GPIO 25 (see the"
    say "README). On a non-W board: redo from step 4; if it persists, run"
    say "./check.sh and open an issue with its output."
    exit 1
}
ok "That blink is your source code, cross-compiled, linked, converted,"
say "  flashed, and scheduled by an async executor — the whole toolchain,"
say "  proven end to end."

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp103 complete.${RESET}"
say ""
say "Things worth noticing now:"
say "  1. lsusb shows no board — this firmware has no USB code, and exp101"
say "     explained why that is normal. BOOTSEL brings the drive back anytime."
say "  2. To flash ANY change you must do the button dance again. Feel that"
say "     friction — a later experiment teaches firmware to reboot itself"
say "     into the bootloader, and the button retires."
say "  3. Try the 'Make it yours' exercise in the README: change the blink"
say "     period in src/main.rs and re-run ./run.sh."
