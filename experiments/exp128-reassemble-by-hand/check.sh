#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp128 quick check — non-interactive verdict.
# Builds, then if the board is running this experiment, sends messages of
# several lengths and confirms each one is reported as ONE message.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # yi26 send is the whole host half; the log carries the result
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log+commands"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp128-reassemble-by-hand
UF2=target/exp128-reassemble-by-hand.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "compiles ($(stat -c%s "$ELF") byte ELF)"
else
    fail "compiles" "run: cargo build --release"
    exit 1
fi

if elf2flash convert -b rp2350 "$ELF" "$UF2" > /dev/null 2>&1 && [[ -f "$UF2" ]]; then
    pass "converts to UF2 ($(stat -c%s "$UF2") bytes)"
else
    fail "converts to UF2" "run: elf2flash convert -b rp2350 $ELF $UF2"
    exit 1
fi
FAMILY="$(od -An -tx4 -j28 -N4 "$UF2" | tr -d ' ')"
[[ "$FAMILY" == "e48bff59" ]] \
    && pass "UF2 family ID is e48bff59 (rp2350-arm-s)" \
    || fail "UF2 family ID is e48bff59 (rp2350-arm-s)" "got: $FAMILY"

if yi26 markers "$UF2" | grep -q 'yi26-cfg:auto-reboot=on'; then
    pass "auto-reboot is compiled in (the board can still be reflashed)"
else
    fail "auto-reboot is compiled in" "built with --no-default-features? this board will need BOOTSEL by hand"
fi

# The citation guard exp118 added after shipping the wrong endpoint address.
TREE=../exp115-webusb-enumerate/README.md
if [[ -f "$TREE" ]]; then
    BAD=""
    while IFS= read -r addr; do
        [[ -z "$addr" ]] && continue
        grep -qF "$addr" "$TREE" || BAD="$BAD [$addr]"
    done < <(grep -rhoE 'endpoint 0x[0-9a-f]{2}' README.md src/main.rs run.sh | sort -u)
    if [[ -z "$BAD" ]]; then
        pass "every endpoint address cited here appears in exp115's captured tree"
    else
        fail "every endpoint address cited here appears in exp115's captured tree" "not in it:$BAD"
    fi
else
    echo "SKIP  exp115's README is missing, so citations cannot be checked against it"
fi

if ! exp_running 128; then
    echo "SKIP  board is not running exp128 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp128"

# ---------------------------------------------------------------------------
# The board half.
#
# The order below is not arbitrary and must not be reshuffled. Every test up
# to the trap leaves the firmware with an empty buffer; the trap deliberately
# leaves 64 bytes in it, and the test after that is what clears them. Moving
# the trap earlier makes every later assertion read a message with 64 extra
# bytes glued to the front, which is the experiment's own subject arriving as
# a broken test.
yi26 log --seconds 2 > /dev/null 2>&1

SHORT="$(yi26 send 'hello12345' --seconds 3 2>/dev/null)"
echo "$SHORT" | grep -q 'msg #[0-9]*: 10 bytes, 1 packet: 10' \
    && pass "10 bytes arrive as one message in one packet" \
    || fail "10 bytes arrive as one message in one packet" "$(echo "$SHORT" | grep -o 'msg #.*' | tail -1)"

# The headline. exp118 reported this same write as two separate events; the
# only thing that changed is who is responsible for noticing where it ended.
HUNDRED="$(yi26 send "$(printf 'A%.0s' $(seq 1 100))" --seconds 3 2>/dev/null)"
echo "$HUNDRED" | grep -q 'msg #[0-9]*: 100 bytes, 2 packets: 64 36' \
    && pass "100 bytes arrive as ONE message, from packets of 64 and 36" \
    || fail "100 bytes arrive as ONE message" "$(echo "$HUNDRED" | grep -o 'msg #.*' | tail -1)"

# And it says so before it knows: a full packet cannot be the end of anything
# on its own, and a firmware that stayed silent here would look identical to
# one that had lost the packet.
echo "$HUNDRED" | grep -q '+64 full packet, 64 held' \
    && pass "a full packet is reported as undecided, not silently held" \
    || fail "a full packet is reported as undecided" "no '+64 full packet' line"

BIG="$(yi26 send "$(printf 'B%.0s' $(seq 1 200))" --seconds 4 2>/dev/null)"
echo "$BIG" | grep -q 'msg #[0-9]*: 200 bytes, 4 packets: 64 64 64 8' \
    && pass "200 bytes arrive as one message from four packets" \
    || fail "200 bytes arrive as one message from four packets" "$(echo "$BIG" | grep -o 'msg #.*' | tail -1)"

# The cap has to be a reported loss, not a quiet one. A firmware that dropped
# an over-long message silently would pass every other check on this page.
CAP="$(yi26 send "$(printf 'C%.0s' $(seq 1 256))" --seconds 4 2>/dev/null)"
if echo "$CAP" | grep -q 'buffer full at 256 bytes' && echo "$CAP" | grep -q 'discarded'; then
    pass "an over-long message is discarded loudly, not quietly"
else
    fail "an over-long message is discarded loudly" "no 'buffer full'/'discarded' pair"
fi

# ---------------------------------------------------------------------------
# The trap, last, because it leaves the firmware mid-message on purpose.

TRAP="$(yi26 send "$(printf 'D%.0s' $(seq 1 64))" --seconds 7 2>/dev/null)"
if echo "$TRAP" | grep -q 'msg #'; then
    fail "a 64-byte message does NOT complete" "something completed it — did the host send a ZLP?"
else
    pass "a 64-byte message does not complete: no short packet ever arrives"
fi

echo "$TRAP" | grep -q 'idle: 64 bytes held, waiting' \
    && pass "the wait is visible in the idle line, not silent" \
    || fail "the wait is visible in the idle line" "nothing matched 'idle: 64 bytes held'"

# The consequence, and the reason this is a trap rather than a hang: the next
# message is not lost, it is *merged*. 64 + 5 reported as one 69-byte message
# is two messages the firmware can no longer tell apart.
MERGED="$(yi26 send 'hello' --seconds 3 2>/dev/null)"
echo "$MERGED" | grep -q 'msg #[0-9]*: 69 bytes, 2 packets: 64 5' \
    && pass "the next message is merged into the stuck one — 64 + 5 became 69" \
    || fail "the next message is merged into the stuck one" "$(echo "$MERGED" | grep -o 'msg #.*' | tail -1)"

echo "NOTE  the 69-byte message above is the bug this experiment hands to exp129"

exit "$FAILED"
