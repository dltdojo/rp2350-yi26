#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp104 interactive walkthrough — build and flash a firmware that brings up
# a USB serial port, then read what the board says. Needs the Pico 2 (non-W)
# and the exp102 toolchain. No extra hardware: the USB cable you already have
# carries both the firmware and the conversation.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp104-usb-serial
UF2=target/exp104-usb-serial.uf2

echo "${BOLD}exp104 — the board talks back${RESET}"
say "exp103's blink could not tell you anything. This firmware brings up a"
say "USB serial port, so the board reappears in lsusb and prints to your"
say "terminal — over the same cable that flashes it."

# ---------------------------------------------------------------------------
step 1 "Build and convert"

for tool in cargo elf2flash; do
    command -v "$tool" > /dev/null || die "'$tool' missing — run exp102 first."
done
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
FAMILY="$(od -An -tx4 -j28 -N4 "$UF2" | tr -d ' ')"
[[ "$FAMILY" == "e48bff59" ]] || die "UF2 family ID is $FAMILY, expected e48bff59."
ok "UF2 ready ($(stat -c%s "$UF2") bytes) — about 3x exp103's blink, and all"
say "  of that growth is the USB stack."

# ---------------------------------------------------------------------------
step 2 "Flash it"

if in_bootsel; then
    ok "Board is already in BOOTSEL mode."
else
    say "The BOOTSEL dance again: unplug → hold ${BOLD}BOOTSEL${RESET} → plug in → release."
    say "(Yes, still. This is the last experiment that makes you do it by hand"
    say " for no reward — a later one teaches the firmware to reboot itself.)"
    pause "Do that now."
    say "Watching for the board (up to 10 s)..."
    for _ in {1..10}; do in_bootsel && break; sleep 1; done
    in_bootsel || die "No board on USB (2e8a:000f). Charge-only cable? BOOTSEL released too early?"
fi

MP="$(rp2350_mount)" || die "Board on USB but no RP2350 drive appeared. Unplug and redo this step."
run_cmd cp "$UF2" "$MP/"
sync 2>/dev/null || true
say "Waiting for the board to reboot (up to 10 s)..."
for _ in {1..10}; do in_bootsel || break; sleep 1; done
in_bootsel && die "Board still in BOOTSEL mode — the UF2 was not accepted."
ok "Flashed. Boot drive gone, as always."

# ---------------------------------------------------------------------------
step 3 "The difference: the board comes back"

say "After exp103's blink, lsusb showed nothing at all. Watch what happens"
say "now that the firmware contains a USB stack (up to 10 s)..."
for _ in {1..10}; do [[ "$(yi26 state)" == "running" ]] && break; sleep 1; done
[[ "$(yi26 state)" == "running" ]] || die "Board did not enumerate. Try replugging, then re-run from step 2."
# --explain prints the lsusb command this is standing in for, so the plain
# host-side command is still something you see and can type yourself.
run_cmd yi26 port --explain
ok "1209:0001 — a pid.codes ID for open-source hardware, set in src/main.rs."

PORT=""
for _ in {1..10}; do PORT="$(exp_serial_port || true)"; [[ -n "$PORT" ]] && break; sleep 1; done
[[ -n "$PORT" ]] || die "Enumerated, but no /dev/ttyACM* appeared. Check: dmesg | tail"
ok "The kernel gave it a serial port: $PORT"
say "The port was found by asking the operating system which USB device is"
say "behind each serial port, and matching on our vendor/product ID — not by"
say "guessing at ttyACM0, which shifts when other devices are plugged in."

# ---------------------------------------------------------------------------
step 4 "Listen"

say "The firmware prints one line per second — but only once something opens"
say "the port (it waits for a connection first; a firmware that prints into"
say "a port nobody opened would stall on the first packet)."
say ""
say "Reading 6 seconds of output with plain cat:"
echo "  ${DIM}\$ timeout 6 cat $PORT${RESET}"
OUT="$(timeout 6 cat "$PORT" 2>/dev/null || true)"
if [[ -z "$OUT" ]]; then
    bad "Nothing arrived."
    say "If your user is not in the 'dialout' group, reading the port silently"
    say "fails. Fix with:  sudo usermod -aG dialout \$USER   (then log out/in)"
    say "Check with:  groups | grep dialout"
    die "No output on $PORT."
fi
echo "$OUT" | sed 's/^/    /'
ok "The board is talking."

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp104 complete — the board can tell you things now.${RESET}"
say ""
say "What you just proved:"
say "  1. One USB cable, two jobs: it flashed the firmware AND carries the"
say "     conversation. No probe, no second cable, no extra hardware."
say "  2. The board is a USB device because your code made it one — the USB"
say "     stack is ~7 KB of the firmware, and lsusb reflects your descriptors."
say "  3. Printing is now your debugging tool. Every experiment after this"
say "     can explain itself instead of blinking in code."
say ""
say "Try it yourself:  cat $PORT      (Ctrl-C to stop)"
say "Or a proper terminal:  picocom $PORT   /   screen $PORT 115200"
