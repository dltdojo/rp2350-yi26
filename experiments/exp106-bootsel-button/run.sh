#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp106 interactive walkthrough — give a board with no user button a button,
# then press it and watch the LED. Nothing to wire, nothing to buy.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp106-bootsel-button
UF2=target/exp106-bootsel-button.uf2

echo "${BOLD}exp106 — the button that was there all along${RESET}"
say "The Pico 2 has exactly one button, and exp101 said it was only for"
say "getting into the bootloader at power-on. That was true only because"
say "nothing was looking at it while the firmware ran. Now something will."

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
step 2 "Flash it"

say "If the board is running exp105 or later, this needs no button at all —"
say "the firmware reboots itself. That is exp105 paying for itself."
ensure_bootsel || die "Board never reached BOOTSEL mode."

MP="$(rp2350_mount)" || die "Board is in BOOTSEL but its drive never appeared. Check: lsblk"
ok "Boot drive at $MP"
run_cmd cp "$UF2" "$MP/"
sync 2>/dev/null || true

PORT=""
for _ in {1..15}; do PORT="$(exp_serial_port || true)"; [[ -n "$PORT" ]] && break; sleep 1; done
[[ -n "$PORT" ]] || die "Board did not come back up. Check: dmesg | tail"
ok "Running, serial port at $PORT"

# ---------------------------------------------------------------------------
step 3 "Press it"

say "Hold ${BOLD}BOOTSEL${RESET} down. The LED should light while you hold it and go"
say "out when you let go. Pressing it now does ${BOLD}not${RESET} reboot anything — the"
say "ROM only looks at this button at power-on, which is exactly why it is"
say "free for us to use."
say ""
say "Watching the firmware's log for 20 seconds — press it a few times:"
echo "  ${DIM}\$ cat $PORT${RESET}"
OUT="$(timeout 20 cat "$PORT" 2>/dev/null || true)"
if [[ -n "$OUT" ]]; then
    echo "$OUT" | sed 's/^/    /'
    ok "The firmware saw your presses."
else
    say "  (no log captured — the firmware only prints on a press/release edge)"
fi

if ! confirm "Did the LED follow the button?"; then
    bad "LED did not follow."
    say "On a Pico 2 W the LED is not on GPIO 25 — see ../README.md#boards."
    say "Otherwise run ./check.sh and open an issue with its output."
    exit 1
fi
ok "A button, on a board that does not have one."

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp106 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. BOOTSEL is readable at runtime, so the Pico 2 does have a user"
say "     button after all — no wiring, no parts, nothing to buy."
say "  2. It is not a GPIO. Read the cost printed in the log above: every"
say "     check runs with interrupts disabled while the flash chip is"
say "     unreachable. Cheap enough for a button, far too expensive for a"
say "     tight loop."
say "  3. Hidden machinery should be labelled, not denied. Everything the"
say "     hack does is written out in crates/bootsel/src/lib.rs — read it."
