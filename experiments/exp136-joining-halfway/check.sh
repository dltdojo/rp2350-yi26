#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp136 quick check — non-interactive verdict.
#
# The comparison itself needs no board: `crates/framing` cuts a stream at every
# offset and counts what each decoder made of the tail. What needs a board is
# the part a sweep cannot show — that a decoder on the far end of a real USB
# endpoint accepts the middle of a message as a whole one.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed
#
# It flashes nothing. Whichever build is on the board is the one measured, and
# the checks that do not apply to it say so rather than failing.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # a board and nothing else: the host types, the log answers
presence_check

USB_IFACE="cdc"
USB_CARRIES="log+commands"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp136-joining-halfway

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# The whole comparison, on any machine, board or not. This is the experiment's
# primary evidence and it is deliberately not on the board: joining a stream at
# every one of five hundred offsets is not something a person can do by hand.
if (cd ../../crates/framing && cargo test --quiet) > /dev/null 2>&1; then
    pass "the framing crate's tests pass (both schemes, every cut, no board)"
else
    fail "the framing crate's tests pass" "cd crates/framing && cargo test"
fi

# Both builds, every time. The one nobody flashes is the one that rots.
for spec in "length-prefix:" "cobs:--features cobs"; do
    name="${spec%%:*}"; flags="${spec#*:}"
    if cargo build --release --quiet $flags 2>/dev/null && [[ -f "$ELF" ]]; then
        UF2="target/exp136-$name.uf2"
        elf2flash convert -b rp2350 "$ELF" "$UF2" > /dev/null 2>&1
        pass "$name compiles and converts to UF2 ($(stat -c%s "$UF2") bytes)"
    else
        fail "$name compiles" "cargo build --release $flags"
    fi
done

# The source names neither scheme. If it ever does, the two builds have started
# differing by a branch somebody has to read instead of by a feature.
if grep -qE '\b(cobs|length_prefix)::' src/main.rs; then
    fail "the firmware names no scheme" "src/main.rs reaches into one of them directly"
else
    pass "the firmware names no scheme — the crate's type alias decides"
fi

if ! exp_running 136; then
    echo "SKIP  board is not running exp136 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp136"

# ---------------------------------------------------------------------------
# The board half.
#
# Which build is on the board decides which assertions mean anything, so ask
# the board rather than assuming.
#
# Read from the idle line, not the boot banner. The banner says it too, and it
# is the first line a sixteen-deep queue throws away — this check said SKIP for
# exactly that reason before the firmware started repeating itself, which is
# exp134 arriving as a practical consequence rather than as a lesson.
SCHEME=""
case "$(yi26 log --seconds 7 2>/dev/null)" in
    *"idle: cobs"*)          SCHEME=cobs ;;
    *"idle: length-prefix"*) SCHEME=length-prefix ;;
esac

if [[ -z "$SCHEME" ]]; then
    echo "SKIP  no idle line in seven seconds, so which build is flashed cannot"
    echo "      be established — is this firmware exp136?"
    exit "$FAILED"
fi
pass "the board says which build it is, in a line that repeats: $SCHEME"

# The frames below are printed by `cargo test print_the_frames_check_sh_sends`
# in crates/framing, so they cannot drift from the encoders that made them.
if [[ "$SCHEME" == "length-prefix" ]]; then
    WHOLE='\xa5\x08\x00\xa5\x05\x00abcde'   # an 8-byte payload that spells a header
    TAIL='\xa5\x05\x00abcde'                # the same frame, joined three bytes in
    PLAIN='\xa5\x05\x00hello'
else
    WHOLE='\x03\xa5\x05\x06abcde\x00'
    TAIL='\x06abcde\x00'
    PLAIN='\x06hello\x00'
fi

# One frame whose fate is not asserted, and it is not a warm-up for the board's
# sake. On the COBS build the *first* frame after boot is thrown away on
# purpose — the decoder does not yet know it is standing on a boundary — so an
# assertion here would be measuring whether this board happens to have been
# sent something earlier. Everything after this point is on a synchronised
# stream, which is where the two schemes can be compared at all.
yi26 send "$PLAIN" --seconds 2 > /dev/null 2>&1

ONE="$(yi26 send "$PLAIN" --seconds 3 2>/dev/null)"
echo "$ONE" | grep -q 'msg #[0-9]*: 5 bytes: hello' \
    && pass "a whole frame arrives as its payload, and nothing else" \
    || fail "a whole frame arrives as its payload" "$(echo "$ONE" | grep -o 'msg #.*' | tail -1)"

EIGHT="$(yi26 send "$WHOLE" --seconds 3 2>/dev/null)"
echo "$EIGHT" | grep -q 'msg #[0-9]*: 8 bytes' \
    && pass "the 8-byte payload that spells a header arrives whole" \
    || fail "the 8-byte payload arrives whole" "$(echo "$EIGHT" | grep -o 'msg #.*' | tail -1)"

# The interior of that frame, sent on its own: the same bytes, entered three in.
#
# Both schemes deliver `abcde` here, and that is not a failure of either. On a
# stream that is already synchronised these bytes *are* a well-formed frame —
# in both encodings. Nothing on the wire distinguishes "a message" from "the
# middle of a message"; only the sender's intent does, and the wire does not
# carry intent. That is why the crate's sweep, which knows what was sent, is
# this experiment's primary evidence and the board is its illustration.
JOINED="$(yi26 send "$TAIL" --seconds 3 2>/dev/null)"
echo "$JOINED" | grep -q 'msg #[0-9]*: 5 bytes: abcde' \
    && pass "the interior of a frame is delivered as a message — the board cannot tell" \
    || fail "the interior of a frame is delivered as a message" \
            "$(echo "$JOINED" | grep -o 'msg #.*' | tail -1)"

# Whatever happened above, the next whole frame has to be right. A decoder that
# recovers is the point; one that stayed confused would fail here.
AFTER="$(yi26 send "$PLAIN" --seconds 3 2>/dev/null)"
echo "$AFTER" | grep -q 'msg #[0-9]*: 5 bytes: hello' \
    && pass "the next whole frame is correct — both schemes recover" \
    || fail "the next whole frame is correct" "$(echo "$AFTER" | grep -o 'msg #.*' | tail -1)"

# ---------------------------------------------------------------------------
# Where the two schemes actually differ, and it is one number.
#
# The firmware's decoder starts in the state a freshly enumerated device is
# genuinely in: somebody else's stream has been running for hours and this
# board has been alive for milliseconds. COBS has a sound way to act on that —
# throw everything away until a byte that cannot occur inside a payload — and
# pays for it by dropping the first message it is ever sent. Length-prefix has
# no such option: no byte means "boundary", so there is nothing to wait for and
# it accepts the first thing that looks like a header.
#
# The discard counter since boot is that difference, and it is cumulative, so
# this holds however long the board has been up.
IDLE="$(yi26 log --seconds 7 2>/dev/null | grep -o 'idle:.*' | tail -1)"
DISCARDED="$(echo "$IDLE" | grep -oE '[0-9]+ bytes discarded' | grep -oE '^[0-9]+')"
: "${DISCARDED:=}"

if [[ -z "$DISCARDED" ]]; then
    echo "SKIP  no idle line seen in six seconds, so the discard count is unknown"
elif [[ "$SCHEME" == "cobs" ]]; then
    [[ "$DISCARDED" -gt 0 ]] \
        && pass "COBS threw away the first frame it ever saw ($DISCARDED bytes) rather than guess" \
        || fail "COBS threw away its first frame" "discarded is 0 — it guessed, and this build should not"
else
    [[ "$DISCARDED" -eq 0 ]] \
        && pass "length-prefix discarded nothing — it never knew it had guessed" \
        || echo "NOTE  $DISCARDED bytes discarded: something malformed reached this board"
fi

exit "$FAILED"
