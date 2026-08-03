#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp132 interactive walkthrough — one interface with one owner, or two with
# two, and what the second one buys.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp132-one-owner-or-two
ONE=target/exp132-one-channel.uf2
TWO=target/exp132-two-channels.uf2

echo "${BOLD}exp132 — one owner or two${RESET}"
say ""
say "exp131 put the draw page and the log page on the same volume, and then"
say "could not open both. The second one said:"
say ""
say "  ${DIM}cannot claim the interfaces — an interface has exactly one owner${RESET}"
say ""
say "That is not a fault to fix. It is the rule the whole browser track stands"
say "on. What was wrong was expecting two witnesses to share one interface."

# ---------------------------------------------------------------------------
step 1 "Build both"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$ONE"
run_cmd cargo build --release --features two-channels
run_cmd elf2flash convert -b rp2350 "$ELF" "$TWO"
say ""
say "One source, one feature flag. The command handling, the rejection"
say "sampling and the health gate are shared — the only structural difference"
say "is in ${DIM}main${RESET}, and it is left visible rather than hidden in a helper."

# ---------------------------------------------------------------------------
step 2 "The one-channel build: commands and log share the port"
run_cmd yi26 flash "$ONE"
run_cmd yi26 send '2100-2567'
say ""
say "Exactly exp129. Whoever holds that port sees both the command and the"
say "log — and nobody else sees either, because there is nothing left to hold."

# ---------------------------------------------------------------------------
step 3 "The two-channel build"
run_cmd yi26 flash "$TWO"
say ""
say "A vendor interface now carries the commands. Nothing claims class 0xFF,"
say "so ${DIM}yi26 echo${RESET} takes it directly with libusb — exp122's finding, with a"
say "job attached to it this time."
say ""
say "Send a range to the ${BOLD}serial${RESET} port and watch it be refused by name:"
run_cmd yi26 send '2100-2567'

# ---------------------------------------------------------------------------
step 4 "Two witnesses, at once"
say ""
say "This is the measurement. A reader is started on the CDC interface, and"
say "${BOLD}while it is running${RESET} a command goes to the vendor one:"
say ""
LOGFILE="$(mktemp)"
trap 'rm -f "$LOGFILE"' EXIT
( yi26 log --seconds 6 > "$LOGFILE" 2>&1 & )
sleep 1
run_cmd yi26 echo '2100-2567'
sleep 5
say ""
say "And what the other owner saw, throughout:"
say ""
grep -E "draw #" "$LOGFILE" | sed 's/^/    /' || bad "no draw line in the log"
say ""
say "${BOLD}The same sentence reached two programs at the same time.${RESET} The kernel's"
say "cdc_acm never let go of one interface; libusb held the other. That is what"
say "exp131's two pages could not do, and it is the whole experiment."

# ---------------------------------------------------------------------------
step 5 "What it does not buy"
say ""
say "${BOLD}It does not help a phone.${RESET} Android lets you choose which app opens a"
say "file; it does not give you two windows to arrange. \"Two pages, one each\""
say "is not something a person can do there, so on a phone this solves a"
say "problem the platform will not let you have."
say ""
say "For phones the cheaper fix is the better one: one page that shows every"
say "line it receives instead of filtering for ${DIM}draw #${RESET}. It already receives"
say "them. One claimant, both views, and no descriptor change at all."
say ""
say "${BOLD}And it costs descriptor surface.${RESET} exp121 measured what adding an"
say "interface does to every number in the tree. That is a real price, paid"
say "here for a real gain — but it is not free and should not look free."

# ---------------------------------------------------------------------------
step 6 "It can still be reflashed"
run_cmd yi26 bootsel
if in_bootsel; then
    ok "Rebooted itself. No button."
    run_cmd yi26 flash "$TWO"
else
    bad "It did not reboot — that is the failure this step exists to catch."
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp132 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. One interface has one owner, so two programs cannot both watch a"
say "     device that has only one. exp131 discovered that the hard way."
say "  2. Two interfaces have two owners, and a command on one arrives in the"
say "     log on the other while a different program is reading it."
say "  3. The fix is not always the architectural one. On a phone, where you"
say "     cannot arrange two windows anyway, deleting a filter in one page"
say "     buys the same thing for nothing."
