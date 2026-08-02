#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp120 interactive walkthrough — the page types, the firmware answers.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PAGE="$(pwd)/two-way.html"
EXP118_UF2=../exp118-one-receiver-two-jobs/target/exp118-one-receiver-two-jobs.uf2

echo "${BOLD}exp120 — the page types, the firmware answers${RESET}"
say ""
say "exp116 read the log. This one talks back. It is the same connect, the same"
say "claim, the same control transfers — and one call that was not there"
say "before: ${DIM}transferOut${RESET}."
say ""
say "That call is what turns a screen into an input device, and it is why this"
say "page matters on a phone. Android has WebUSB and no Web Serial, so this is"
say "the only way a phone can say anything to a board at all."

# ---------------------------------------------------------------------------
step 1 "Put exp118 on the board"
say ""
say "Not optional, and the failure is silent. Every firmware here has an OUT"
say "endpoint — exp115's descriptor tree shows it — but exp118 is the first"
say "that ${BOLD}reads${RESET} it. Any other firmware takes your bytes, never collects"
say "them, and prints nothing, which looks exactly like this page being broken."
say ""
if exp_running 118; then
    ok "exp118 is already running."
else
    if [[ -f "$EXP118_UF2" ]]; then
        run_cmd yi26 flash "$EXP118_UF2"
    else
        say "Build it first:"
        say "  ${DIM}(cd ../exp118-one-receiver-two-jobs && ./check.sh)${RESET}"
        die "exp118's .uf2 is not built yet."
    fi
fi

# ---------------------------------------------------------------------------
step 2 "Give the interfaces to the browser"
run_cmd yi26 detach
say ""
say "On Android this step does not exist — there is no ${DIM}cdc_acm${RESET} to move aside."

# ---------------------------------------------------------------------------
step 3 "Open the page and say something"
say ""
say "  ${DIM}${PAGE}${RESET}"
say ""
say "Press ${BOLD}Connect${RESET}, type ${BOLD}hello${RESET} and press Enter. The firmware prints a hex"
say "dump of exactly what arrived — five bytes, ${DIM}68 65 6c 6c 6f${RESET}."
say ""
say "Then press ${BOLD}Send 100 bytes${RESET}, which is the part worth staying for."
pause "Do both, then come back."

# ---------------------------------------------------------------------------
step 4 "What USB did with your hundred bytes"
say ""
say "One ${DIM}transferOut${RESET} of a hundred bytes arrives as ${BOLD}two${RESET} reads: 64 and 36."
say ""
say "USB has no messages. The endpoint has a packet size — the 64 this"
say "firmware asked for — and the host's stack cuts everything down to it."
say "There is no length prefix and no delimiter, because a bulk endpoint"
say "carries neither. A page with a text box makes it very easy to believe"
say "otherwise, which is exactly why the button is there."
say ""
say "exp118 measured the same split from a terminal. Same wire, same rule,"
say "different host software — which is what makes it a property of USB rather"
say "than of either tool."

# ---------------------------------------------------------------------------
step 5 "Give the port back"
say ""
say "While the browser holds the interfaces there is no ${DIM}/dev/ttyACM0${RESET}. Close"
say "the tab or press Disconnect first, then:"
say ""
run_cmd yi26 attach || true
say ""
say "If that failed, the tab still has them — ${DIM}yi26 doctor${RESET} names the process."

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp120 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. A browser can write to a device, not only read from it — with no"
say "     firmware change, on an endpoint that has existed since exp104."
say "  2. A hundred bytes is not a message. It is two packets, and anything"
say "     that wants messages has to define and reassemble them itself."
say "  3. The log pane shows only what the ${BOLD}device${RESET} said. What you sent is"
say "     reported in the status line instead, because a log that mixes in"
say "     text the host invented is a log you cannot trust."
say ""
say "That closes the browser track's read-and-write half. The rest of it"
say "changes the device: ${BOLD}exp121${RESET} makes it two things at once."
