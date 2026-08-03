#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp127 interactive walkthrough — the host takes the LED, and the board loses
# the only signal that said it was alive.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp127-host-owns-the-led
UF2=target/exp127-host-owns-the-led.uf2

echo "${BOLD}exp127 — the host owns the LED${RESET}"
say ""
say "exp118 taught the firmware to listen and then printed what arrived. The"
say "board was never changed by anything the host said."
say ""
say "This one changes. ${DIM}0x01${RESET} on, ${DIM}0x00${RESET} off — and that is the entire protocol."

# ---------------------------------------------------------------------------
step 1 "Build and flash"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"
ok "Flashed. Watch the LED: it is blinking, and that blink is the firmware's."

# ---------------------------------------------------------------------------
step 2 "Take it"
say ""
say "One byte. No keyboard types 0x01, so it goes as an escape:"
say ""
run_cmd yi26 send '\x01'
say ""
say "Look at the board. The blink is gone and the LED is simply ${BOLD}on${RESET} —"
say "the firmware handed it over and stopped using it."
pause

# ---------------------------------------------------------------------------
step 3 "The thing you just gave up"
say ""
run_cmd yi26 send '\x00'
say ""
say "The LED is dark. That now means one of three things, and ${BOLD}the board"
say "cannot tell you which${RESET}:"
say ""
say "  - you turned it off"
say "  - the firmware crashed"
say "  - the firmware never started"
say ""
say "Every experiment since exp103 has blinked that LED, and the blink was"
say "doing real work: it was how you knew the board was alive without opening"
say "a terminal. A controllable output and a status indicator cannot be the"
say "same pin, and this is what it costs."
say ""
say "So the log takes over the job. Watch it repeat:"
run_cmd yi26 log --seconds 7

# ---------------------------------------------------------------------------
step 4 "Why 'led on' does not work"
say ""
run_cmd yi26 send 'led on'
say ""
say "Six bytes, refused. Not because the firmware dislikes text — because it"
say "has no way to know where one message ends and the next begins."
say ""
say "exp118 proved a hundred bytes arrive as ${BOLD}64 + 36${RESET}: USB delivers packets,"
say "not messages. A one-byte command dodges that entirely, and it is worth"
say "being exact about why. Not because the problem was solved, but because"
say "${BOLD}one is smaller than 64${RESET} and a command that fits in a packet can never be"
say "split. This protocol is standing underneath ${DIM}wMaxPacketSize${RESET} and nothing"
say "more clever than that."
say ""
say "Where message boundaries actually come from — a dedicated wire, the bus's"
say "electrical states, the protocol layer, or nowhere at all — is the table"
say "in this experiment's README. It is the one question a reader always asks"
say "next: does any of this apply to SPI?"

# ---------------------------------------------------------------------------
step 5 "The register that would have lied"
say ""
run_cmd yi26 send '\x01'
say ""
say "Every command prints ${DIM}(OUT high, pad high)${RESET}, and those are two different"
say "registers being asked two different questions:"
say ""
say "  ${DIM}SIO GPIO_OUT${RESET}   what I last wrote     Flex::is_set_high()"
say "  ${DIM}SIO GPIO_IN${RESET}    what the pad is at    Flex::is_high()"
say ""
say "${BOLD}Output::get_output_level() reads the first one.${RESET} It cannot fail in any"
say "interesting way — it hands back the value that was just stored, so a log"
say "built from it is the command rephrased, not evidence about it."
say ""
say "GPIO_IN is the pad. Reading it on an output pin works because ${DIM}Flex::new${RESET}"
say "turns the input buffer on unconditionally, which is why this firmware is"
say "the first here to use ${BOLD}Flex${RESET} instead of ${BOLD}Output${RESET}."
say ""
say "And it still does not prove the LED ${BOLD}lit${RESET}. An unpopulated LED, a dead"
say "one, or a board that wires its LED elsewhere all read back like success."
say "That last gap closes with an eye and nothing else."

# ---------------------------------------------------------------------------
step 6 "It can still be reflashed"
say ""
say "This firmware's select loop grew a third branch, and the 1200-baud"
say "watcher from exp105 is in one of the other two. Losing it means the next"
say "flash needs a hand on BOOTSEL, so it gets proved rather than assumed:"
run_cmd yi26 bootsel
if in_bootsel; then
    ok "Rebooted itself. No button."
    run_cmd yi26 flash "$UF2"
else
    bad "It did not reboot — that is the failure this step exists to catch."
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp127 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. The host can change the board, not only watch it. One byte on an"
say "     endpoint that has existed since exp104, and no descriptor changed."
say "  2. A status indicator and a controllable output cannot be the same"
say "     resource. Taking the LED cost the heartbeat, and the log had to"
say "     take over the job of saying the firmware is alive."
say "  3. One byte needs no framing because it fits in a packet — not because"
say "     USB carries messages. It does not."
say "  4. GPIO_OUT answers 'what did I write'. GPIO_IN answers 'what is the"
say "     pin at'. Only the second one is evidence, and neither proves light."
say ""
say "Open: what a command longer than one byte would take. That is the"
say "framing question, and it is the next thing on this road."
