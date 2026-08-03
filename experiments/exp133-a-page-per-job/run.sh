#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp133 interactive walkthrough — a page per job, and three of them working
# at once off one volume.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp133-a-page-per-job
UF2=target/exp133-a-page-per-job.uf2
MODEL="exp133 drawer"

echo "${BOLD}exp133 — a page per job${RESET}"
say ""
say "exp131 put a draw page and a log page on one volume and could not open"
say "both. The fix was to weld the log into the draw page, and that cost"
say "composability: every future appliance would carry its own copy."
say ""
say "This one gives it back. Three tools, three jobs, and none of them knows"
say "anything about the others."

# ---------------------------------------------------------------------------
step 1 "Build and flash"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"
ok "Two interfaces: a read-only volume, and the port the draw travels on."

# ---------------------------------------------------------------------------
step 2 "The volume, and the bit exp126 left clear"
say ""
run_cmd yi26 log --seconds 5
say ""
say "${DIM}MODE SENSE(6) -> READ-ONLY (WP set)${RESET}. exp126 left that bit at zero and"
say "the volume was writable — which is why an Android phone created a"
say "${BOLD}LOST.DIR${RESET} on it within a minute of mounting. A host writes to your device"
say "unless you tell it not to, and a draw appliance should not be scribbled on."
say ""
DEV=""
for d in /sys/block/*/; do
    [[ -r "$d/device/model" ]] || continue
    M="$(cat "$d/device/model" 2>/dev/null)"
    [[ "${M%"${M##*[![:space:]]}"}" == "$MODEL" ]] && DEV="$(basename "$d")"
done
if [[ -n "$DEV" ]]; then
    run_cmd lsblk -o NAME,RO,SIZE,LABEL "/dev/$DEV"
    say ""
    say "${BOLD}RO is 1.${RESET} The host was told, and believed it."
fi

# ---------------------------------------------------------------------------
step 3 "Draw, on a channel of its own"
say ""
run_cmd yi26 echo '2100-2567'
say ""
say "That went to the ${BOLD}vendor${RESET} interface — class 0xFF, which promises nothing,"
say "so no driver claims it and anything may. Meanwhile the kernel still holds"
say "the serial port and the storage one. ${BOLD}Three owners${RESET}, one cable."
say ""
say "And the provenance query that splitting the channels made necessary:"
run_cmd yi26 echo '?'
say ""
say "exp130's page read the build string off the boot log. A page holding only"
say "this interface never sees that log, so the channel answers directly — the"
say "protection survives the split instead of being lost in it."

# ---------------------------------------------------------------------------
step 4 "Three tools on the drive, and the diff that is the point"
say ""
say "  ${BOLD}INDEX.HTM${RESET}   the draw          claims the vendor interface"
say "  ${BOLD}LOG.HTM${RESET}     the log, live     claims the CDC pair"
say "  ${BOLD}FLASH.HTM${RESET}   into BOOTSEL      exp117's page, unchanged"
say ""
say "  ${DIM}exp130/draw.html   16469 bytes   draw + log + JSON export${RESET}"
say "  ${DIM}exp133/index.html   7672 bytes   draw${RESET}"
say ""
say "Less than half, and the missing half is not gone — it is LOG.HTM, which"
say "knows nothing about prize draws and works against any firmware here."
say ""
say "${BOLD}A new appliance costs its own job.${RESET} Under the merged design it costs its"
say "own job plus a log pane, and the second copy of that pane is the one that"
say "drifts. ${DIM}check.sh${RESET} fails if one ever creeps back into index.html."
say ""
say "Open ${BOLD}LOG.HTM first${RESET} and connect it, then draw in the other tab. The log"
say "keeps reading in the background — that was measured in exp132. Connecting"
say "it afterwards means missing the draw, and the reason is the sixteen-line"
say "queue rather than the channels."

# ---------------------------------------------------------------------------
step 5 "What changed, and it is not the presentation"
say ""
say "In exp129 the only thing between the chip's TRNG and you was ${DIM}yi26 log${RESET},"
say "whose source is in this repository. Now there is a browser, a page, and a"
say "screen. The number you read is ${BOLD}a claim about what the device said${RESET}, not"
say "the thing the device said."
say ""
say "So the page prints the board's own line underneath the big number. Two"
say "views of one event, on one screen, and anybody standing there can compare"
say "them. That is the whole mechanism — no cryptography, just refusing to be"
say "the only witness."
say ""
say "And the page checks its own provenance. The firmware announces its page"
say "build at boot; the page knows its own; if they differ it says so. A page"
say "off the board and a stale copy saved on the phone weeks ago look"
say "identical in the address bar, and that is a real way to be fooled."

# ---------------------------------------------------------------------------
step 6 "It can still be reflashed, including from a phone"
run_cmd yi26 bootsel
if in_bootsel; then
    ok "Rebooted itself. On a phone, exp117's page does the same thing."
    run_cmd yi26 flash "$UF2"
else
    bad "It did not reboot — that is the failure this step exists to catch."
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp133 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. Four interfaces enumerate cleanly, and three owners work at once —"
say "     kernel storage, kernel serial, and a raw claim on the vendor one."
say "  2. The appliance page carries no log code. That is not tidiness, it is"
say "     what makes the next appliance cost its own job and nothing else."
say "  3. Splitting the channels took the provenance check away from the page"
say "     that needed it, and the command channel gave it back for one byte."
say ""
say "The architecture followed the experiments rather than the other way"
say "round: exp131 found the collision, exp132 measured what a second channel"
say "buys, and this is what the measurement was worth."
