#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp136 interactive walkthrough — a boundary in the bytes, and what each of
# two ways to build one does to a reader who arrived late.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp136-joining-halfway
LP=target/exp136-length-prefix.uf2
CB=target/exp136-cobs.uf2

echo "${BOLD}exp136 — a boundary you can join halfway${RESET}"
say ""
say "exp128 took the message boundary from USB itself: a message ends at the"
say "first packet shorter than 64 bytes. exp135 paid what that costs — one"
say "unterminated message silently swallows the next, and only a program"
say "holding the interface can send the packet that ends it."
say ""
say "So the boundary moves up, out of the transport and into the bytes."

# ---------------------------------------------------------------------------
step 1 "The comparison, before any board is involved"
say ""
say "Two ways to put a boundary into a byte stream:"
say ""
say "  ${BOLD}length-prefix${RESET}  a magic byte, then how many bytes follow"
say "  ${BOLD}COBS${RESET}           reserve one byte value the payload can never contain"
say ""
say "Both are exact on a stream read from its first byte, so that is not the"
say "question. The question is the one that actually happens: ${BOLD}the reader"
say "arrives late.${RESET} A page opened a minute in, a tool that attaches"
say "mid-message, a cable pushed back in."
say ""
run_cmd bash -c "cd ../../crates/framing && cargo test -- --nocapture 2>&1 | grep -A3 'cuts  clean'"
say ""
say "Every offset of an encoded stream, cut, with the tail handed to a decoder"
say "that has just arrived. ${BOLD}Length-prefix loses fewer messages${RESET} — and"
say "delivers three that were never sent. COBS delivers none it was not given,"
say "and drops one per boundary it cannot recognise."
say ""
say "That is the trade. Not overhead, not speed: ${BOLD}loss against fabrication.${RESET}"

# ---------------------------------------------------------------------------
step 2 "Build both, flash the first"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$LP"
run_cmd cargo build --release --features cobs
run_cmd elf2flash convert -b rp2350 "$ELF" "$CB"
say ""
say "One source, two builds. The scheme is a type alias in the crate, so"
say "${DIM}src/main.rs${RESET} names neither of them."
say ""
run_cmd yi26 flash "$LP"
ok "The length-prefix build is running."

# ---------------------------------------------------------------------------
step 3 "A frame, and the frame's own middle"
say ""
say "This payload is eight bytes long and it ${BOLD}spells a header${RESET}: a5, then a"
say "length of five, then five bytes. Sent whole, it is one message:"
say ""
run_cmd yi26 send '\xa5\x08\x00\xa5\x05\x00abcde'
say ""
say "Now the same frame, entered three bytes in — which is exactly what a"
say "decoder sees when it joins a stream already in progress:"
say ""
run_cmd yi26 send '\xa5\x05\x00abcde'
say ""
say "${BOLD}msg: 5 bytes: abcde${RESET} — a message nobody ever sent, assembled out of"
say "the middle of one that was. And look at the discard counter: ${BOLD}zero${RESET}."
say "The firmware has no idea anything happened."

# ---------------------------------------------------------------------------
step 4 "The same bytes, the other build"
say ""
say "Both schemes deliver ${DIM}abcde${RESET} for that second send, and that is not COBS"
say "failing. On a stream that is already synchronised those bytes ${BOLD}are${RESET} a"
say "well-formed frame in both encodings. Nothing on the wire distinguishes a"
say "message from the middle of a message; only the sender's intent does, and"
say "the wire does not carry intent."
say ""
say "The difference shows at the one moment a decoder genuinely does not know"
say "where it is: the first bytes after it comes up."
say ""
run_cmd yi26 flash "$CB"
run_cmd yi26 send '\x06hello\x00'
say ""
say "Nothing arrived, and the firmware says how much it threw away. COBS has"
say "a sound way to handle not knowing — discard until a byte that cannot"
say "occur inside a payload — and it pays for that with the first message it"
say "is ever sent. Length-prefix has no such option: no byte means boundary,"
say "so there is nothing to wait for, and it accepts the first thing that"
say "looks like a header."
say ""
run_cmd yi26 send '\x06hello\x00'
ok "Synchronised now, and exact from here on."

# ---------------------------------------------------------------------------
step 5 "What to take away"
say ""
say "  ${BOLD}1.${RESET} A boundary in the transport is not a boundary in the protocol."
say "     exp128 and exp135 established what the transport's costs; this is"
say "     what it costs to stop relying on it."
say "  ${BOLD}2.${RESET} Resynchronisation is not a feature you add. It is a property of"
say "     the encoding — by construction or by luck, and luck is measurable."
say "  ${BOLD}3.${RESET} The failure that matters is not the loud one. A dropped message"
say "     announces itself; an invented one is indistinguishable from a real"
say "     one, and the receiver acts on it."
say ""
say "Neither scheme here has a checksum, and a frame layer without one cannot"
say "tell a corrupted payload from a real one. Read the crate's own note on"
say "what it declines to claim before taking either into a protocol."
say ""
say "Leaving the board on the ${BOLD}COBS${RESET} build. ${DIM}./check.sh${RESET} works against either."
