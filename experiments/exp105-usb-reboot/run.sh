#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp105 interactive walkthrough — flash a firmware that can put itself into
# the bootloader, then prove it by rebooting the board without touching it.
#
#   ./run.sh
#
# The first flash still needs the BOOTSEL button, because the firmware
# currently on the board (exp104) cannot reboot itself. Every flash after
# this one is automatic.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp105-usb-reboot
UF2=target/exp105-usb-reboot.uf2

echo "${BOLD}exp105 — retire the BOOTSEL button${RESET}"
say "exp101 promised that some boards reflash without anyone pressing"
say "anything, and that the trick is the running firmware cooperating."
say "This is that firmware."

# ---------------------------------------------------------------------------
step 1 "Build and convert"

for tool in cargo elf2flash; do
    command -v "$tool" > /dev/null || die "'$tool' missing — run exp102 first."
done
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
FAMILY="$(od -An -tx4 -j28 -N4 "$UF2" | tr -d ' ')"
[[ "$FAMILY" == "e48bff59" ]] || die "UF2 family ID is $FAMILY, expected e48bff59."
ok "UF2 ready ($(stat -c%s "$UF2") bytes)."

# ---------------------------------------------------------------------------
step 2 "Into the bootloader — the last manual press"

say "Getting the board into BOOTSEL mode. If the firmware already on it can"
say "reboot itself, this happens without you; otherwise you get asked."
ensure_bootsel || die "Board never reached BOOTSEL mode."

MP="$(rp2350_mount)" || die "Board on USB but no RP2350 drive appeared."
run_cmd cp "$UF2" "$MP/"
sync 2>/dev/null || true
for _ in {1..10}; do in_bootsel || break; sleep 1; done
in_bootsel && die "Board still in BOOTSEL mode — the UF2 was not accepted."
ok "Flashed."

PORT=""
for _ in {1..15}; do PORT="$(exp_serial_port || true)"; [[ -n "$PORT" ]] && break; sleep 1; done
[[ -n "$PORT" ]] || die "No serial port appeared. Check: dmesg | tail"
ok "Running, serial port at $PORT"

# ---------------------------------------------------------------------------
step 3 "The proof: reboot it without touching it"

say "Now the point of the experiment. Setting the port to 1200 baud is not a"
say "request to transmit slowly — this firmware reads it as 'put yourself"
say "into the bootloader'. Nothing is sent; the baud rate IS the message."
say ""
say "Keep your hands off the board."
# --explain prints the two stty commands this stands in for, and why it takes
# two of them. The point of the experiment is the 1200, not the tool.
run_cmd yi26 bootsel --explain

say "Watching for the bootloader (up to 10 s)..."
for _ in {1..10}; do in_bootsel && break; sleep 1; done
in_bootsel || die "Board did not enter BOOTSEL. Is the auto-reboot feature disabled in Cargo.toml?"
ok "It rebooted itself. The serial port is gone and the RP2350 drive is back —"
say "  and nobody pressed anything."
run_cmd yi26 state --explain

# ---------------------------------------------------------------------------
step 4 "Put it back"

say "The board is sitting in the bootloader, so re-flashing is now just a"
say "copy — no button, no replugging:"
MP="$(rp2350_mount)" || die "Boot drive did not mount."
run_cmd cp "$UF2" "$MP/"
sync 2>/dev/null || true
for _ in {1..15}; do PORT="$(exp_serial_port || true)"; [[ -n "$PORT" ]] && break; sleep 1; done
[[ -n "$PORT" ]] || die "Board did not come back up."
ok "Back up and running at $PORT — a full edit-flash cycle, hands free."

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp105 complete — the button is retired.${RESET}"
say ""
say "What you just proved:"
say "  1. A firmware can put itself into the ROM bootloader. The button was"
say "     never the only door — it was the only door for firmware that had"
say "     no way to cooperate."
say "  2. The signal is just a baud rate, which is why ANY program that opens"
say "     this port at 1200 baud will reboot your board. Convenience and"
say "     footgun are the same mechanism — see the README to switch it off."
say "  3. From here on, ./run.sh in later experiments reflashes without"
say "     asking you for anything, as long as the firmware keeps the watcher."
say ""
say "Still watching the log:  cat $PORT"
