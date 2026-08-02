#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp118 interactive walkthrough — the firmware starts listening, and the
# board's one Receiver turns out to have two jobs.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp118-one-receiver-two-jobs
UF2=target/exp118-one-receiver-two-jobs.uf2

echo "${BOLD}exp118 — one receiver, two jobs${RESET}"
say ""
say "Everything so far has talked ${BOLD}at${RESET} the host. This listens."
say ""
say "Nothing about the device changes to allow it. exp115's descriptor tree"
say "already listed ${DIM}endpoint 0x02 OUT bulk 64 bytes${RESET}, and every firmware here"
say "has had one since exp104. The endpoint was always there. Nobody read it."

# ---------------------------------------------------------------------------
step 1 "Build and flash"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"
ok "Listening."

# ---------------------------------------------------------------------------
step 2 "Say something"
say ""
say "One command, not two. ${DIM}yi26 send${RESET} writes and then listens through the"
say "same open port — closing it in between drops DTR, and the firmware's"
say "reply would land in the gap. ${DIM}yi26 send --explain${RESET} shows the trap in full."
say ""
run_cmd yi26 send hello

# ---------------------------------------------------------------------------
step 3 "Send bytes no keyboard can type"
say ""
say "The dump is hex first and text second, because the bytes are the fact and"
say "the text is an interpretation of it. Escapes reach the rest:"
say ""
run_cmd yi26 send 'A\x00\xff\ttab\r\nZ'
say ""
say "Ten bytes, and only six of them survive being printed as characters."

# ---------------------------------------------------------------------------
step 4 "The thing worth staying for"
say ""
say "A hundred bytes, sent once:"
say ""
run_cmd yi26 send "$(printf 'A%.0s' $(seq 1 100))"
say ""
say "Two entries, ${BOLD}64 and 36${RESET}. One write on the host, two reads on the"
say "device. USB has no messages — the endpoint has a packet size, and the"
say "host's stack cuts everything down to it. There is no length prefix and no"
say "delimiter, because a bulk endpoint carries neither."
say ""
say "Any firmware that wants messages has to define what one is and reassemble"
say "them. This one refuses to pretend, and prints what actually arrived."

# ---------------------------------------------------------------------------
step 5 "The reason this is one task and not two"
say ""
say "The obvious design is exp107's: add a task that reads. It cannot work."
say ""
say "  ${DIM}Sender${RESET}          write_packet, line_coding   → usb_log::run"
say "  ${DIM}Receiver${RESET}        read_packet,  line_coding   → both jobs want this"
say "  ${DIM}ControlChanged${RESET}  control_changed             → no line_coding"
say ""
say "The 1200-baud reboot has to read the baud rate, and ${BOLD}ControlChanged cannot${RESET}."
say "So the reboot watcher holds the Receiver just to ask it a question — free,"
say "until something wants to read from it. ${DIM}read_packet${RESET} needs ${DIM}&mut Receiver${RESET},"
say "and there is exactly one."
say ""
say "Give it to the reader and the board can only be reflashed by hand. Give it"
say "to the watcher and nothing can listen. One task does both, waiting on two"
say "things at once — which is ${BOLD}select${RESET}, arriving as a consequence."
say ""
say "And ${BOLD}select drops the loser unfinished${RESET}. That is safe here for a reason"
say "worth reading in the source, not guessing: embassy-usb latches the control"
say "event in a flag it only clears when somebody observes it, so a cancelled"
say "${DIM}control_changed()${RESET} cannot lose a reboot request."
say ""
say "Proof, rather than the claim:"
run_cmd yi26 bootsel
if in_bootsel; then
    ok "Rebooted itself, from inside the select loop. No button."
    run_cmd yi26 flash "$UF2"
else
    bad "It did not reboot — that is the failure this step exists to catch."
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp118 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. The OUT endpoint was there all along. Listening needed no new"
say "     descriptor, no new interface, and no change the host can see."
say "  2. USB delivers packets, not messages. 100 bytes arrived as 64 + 36."
say "  3. Two jobs wanted the same half of the port, and ownership — not"
say "     taste — decided the shape of the program."
say "  4. Cancelling a future is a thing you have to check, not assume. For"
say "     the control side it costs nothing, and the source says why."
say ""
say "Open: whether cancelling ${DIM}read_packet${RESET} costs a packet. Every entry above"
say "carries a sequence number so that a gap would show. Measuring it is"
say "${BOLD}exp119${RESET}."
