#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp135 walkthrough — the census, one case at a time.
#
# No firmware to build. exp128 is the instrument, and it has to be flashed
# before this will say anything.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

echo "exp135 — a packet with no bytes"
say ""
say "exp128 found that a 64-byte message never ends: no short packet follows"
say "it, so the receiver waits, and the next message gets glued on. It named"
say "the fix and could not send it."
say ""
say "The fix is a transfer with no bytes in it. You cannot echo one."

if ! exp_running 128 && [[ "$(yi26 state 2>/dev/null)" != "detached" ]]; then
    die "flash exp128 first: cd ../exp128-reassemble-by-hand && ./run.sh"
fi

step 1 "Take the interface from the kernel"
say ""
say "A tty cannot describe the packet we are about to send, so the tty has to"
say "go. This is the same thing exp116's page needs, for the same reason: an"
say "interface has exactly one owner."
run_cmd yi26 detach
trap 'echo; say "giving the interfaces back:"; yi26 attach' EXIT

flush() { yi26 send --raw 'z' --seconds 1 > /dev/null 2>&1; }
bytes() { printf 'X%.0s' $(seq 1 "$1"); }

step 2 "63 bytes — the case that already works"
say ""
flush
run_cmd yi26 send --raw "$(bytes 63)" --seconds 2
say ""
say "Complete on arrival. The last packet is 63 bytes, which is shorter than"
say "64, which is the only rule this receiver has."
pause "Read the msg line."

step 3 "64 bytes — the case that does not"
say ""
flush
run_cmd yi26 send --raw "$(bytes 64)" --seconds 2
say ""
say "${BOLD}64 held.${RESET} No completion, and the firmware says so rather than"
say "guessing. Nothing followed the packet that could mean 'over'."
pause "Nothing arrived. That is the result."

step 4 "The same 64 bytes, ended"
say ""
flush
run_cmd yi26 send --end "$(bytes 64)" --seconds 2
say ""
say "${BOLD}ended by a zero-length packet.${RESET} That line has been in exp128's"
say "source since the day it was written, and until this experiment nothing"
say "had ever produced it."
pause "Compare with step 3."

step 5 "Nothing at all"
say ""
say "The sharpest case. Two host libraries on this machine disagree about"
say "whether a zero-length request reaches the device at all."
say ""
flush
run_cmd yi26 send --raw --seconds 3
say ""
say "It arrives. So the disagreement is about the ${BOLD}library${RESET}, not the bus —"
say "and 'USB does X' was never the same claim as 'the library I used does X'."

step 6 "What this does not conclude"
say ""
say "Not 'use zero-length packets for framing'. Earlier work evaluated exactly"
say "that for a real protocol and rejected it, keeping an explicit frame layer,"
say "because three implementations had to stay in agreement and a"
say "transport-dependent boundary would have forked them."
say ""
say "The terminator fixes this firmware's buffer. It is not a framing layer,"
say "and that difference is the road exp128 pointed at."
say ""
ok "Done. ./check.sh proves the same four cases without narration."
