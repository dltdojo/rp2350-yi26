#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp128 interactive walkthrough — a message is what you put back together,
# and the one length that never comes back.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp128-reassemble-by-hand
UF2=target/exp128-reassemble-by-hand.uf2

echo "${BOLD}exp128 — reassemble by hand${RESET}"
say ""
say "exp118 printed what arrived and refused to call it a message: a hundred"
say "bytes came back as ${BOLD}64${RESET} and then ${BOLD}36${RESET}. exp127 dodged the problem by"
say "making its commands one byte long, and said so."
say ""
say "This one pays the bill."

# ---------------------------------------------------------------------------
step 1 "Build and flash"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"
ok "Listening, and this time counting to the end of something."

# ---------------------------------------------------------------------------
step 2 "The line exp118 could not print"
say ""
run_cmd yi26 send "$(printf 'A%.0s' $(seq 1 100))"
say ""
say "${BOLD}One${RESET} message, and the packets it came in are named beside it. Nothing"
say "about the device changed to make that happen — the descriptors are still"
say "exp115's, and ${DIM}endpoint 0x01 OUT bulk 64 bytes${RESET} is the same endpoint."
say ""
say "What changed is that somebody decided where the message ended."

# ---------------------------------------------------------------------------
step 3 "Where the boundary actually was"
say ""
say "USB is not missing this information. A bulk transfer ends at the ${BOLD}first"
say "packet shorter than wMaxPacketSize${RESET} — the host puts it there, the device"
say "sees it, and no guessing is involved."
say ""
say "${DIM}embassy-usb-driver${RESET} even has a method for it, four lines long:"
say ""
say "  ${DIM}// embassy-usb-driver-0.2.2/src/lib.rs:273${RESET}"
say "  ${DIM}async fn read_transfer(&mut self, buf: &mut [u8]) -> ... {${RESET}"
say "  ${DIM}    let i = self.read(&mut buf[n..]).await?;${RESET}"
say "  ${DIM}    if i < self.info().max_packet_size as usize { return Ok(n) }${RESET}"
say "  ${DIM}}${RESET}"
say ""
say "${BOLD}CdcAcmClass's Receiver does not expose it.${RESET} Its whole read surface is"
say "${DIM}read_packet${RESET}. The method is on the EndpointOut trait, so a firmware"
say "holding a raw endpoint — exp122's vendor interface — can call it. A"
say "firmware holding a CDC Receiver cannot."
say ""
say "That is not an oversight. CDC-ACM presents a serial port, RS-232 has no"
say "message boundaries, so the class ${BOLD}discards${RESET} the one the wire underneath"
say "was carrying. The loop in src/main.rs is that boundary, put back by hand."
say ""
say "And ${DIM}Receiver::into_buffered${RESET} is not the way out despite the name — its"
say "own docs say it exists to read ${BOLD}fewer${RESET} bytes than a packet. It turns"
say "packets into a byte stream with no boundaries at all."

# ---------------------------------------------------------------------------
step 4 "Longer, and then too long"
say ""
run_cmd yi26 send "$(printf 'B%.0s' $(seq 1 200))"
say ""
say "Four packets, ${BOLD}64 64 64 8${RESET}, and the firmware says after each full one"
say "that it cannot yet tell whether the message is over. Staying silent there"
say "would look exactly like a lost packet."
say ""
run_cmd yi26 send "$(printf 'C%.0s' $(seq 1 256))"
say ""
say "The cap, and it is announced as a ${BOLD}loss${RESET}. A firmware that quietly drops"
say "an over-long message passes every other test on this page."

# ---------------------------------------------------------------------------
step 5 "The message that never arrives"
say ""
say "Now send exactly ${BOLD}64${RESET} bytes — one whole packet, and nothing after it:"
say ""
run_cmd yi26 send "$(printf 'D%.0s' $(seq 1 64))"
say ""
say "No message. There is no short packet, so by the only rule this firmware"
say "has, the message has not ended."
say ""
say "That is measured, not feared. Against exp118 on this machine, a 64-byte"
say "write produced ${BOLD}one${RESET} 64-byte packet and no zero-length packet after it."
say "The host had no reason to send one: it wrote what it was asked to write."
pause
say ""
say "Watch what that costs. Send five more bytes:"
say ""
run_cmd yi26 send 'hello'
say ""
say "${BOLD}69 bytes, 2 packets: 64 5.${RESET} The second message was not lost — it was"
say "${BOLD}merged${RESET} into the first, and the firmware can no longer tell there were"
say "two. That is worse than a hang, because a hang is visible."

# ---------------------------------------------------------------------------
step 6 "It can still be reflashed"
say ""
run_cmd yi26 bootsel
if in_bootsel; then
    ok "Rebooted itself. No button."
    run_cmd yi26 flash "$UF2"
else
    bad "It did not reboot — that is the failure this step exists to catch."
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp128 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. A message is not something USB hands you. It is something you"
say "     reassemble, and the rule is: a short packet ends it."
say "  2. The boundary was on the wire the whole time. read_transfer exists"
say "     on the trait; the CDC class does not let you reach it, because a"
say "     serial port is not allowed to have messages."
say "  3. A message that is an exact multiple of 64 has no short packet, so"
say "     it never ends — and the next one is silently glued to it."
say ""
say "That last one has a fix with a name, a zero-length packet, and the"
say "crate's own CDC docs describe it. Measuring it is ${BOLD}exp129${RESET}."
