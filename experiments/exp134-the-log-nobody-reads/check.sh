#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp134 quick check — non-interactive verdict.
#
# Builds all three policies, then — if a board is running one of them — leaves
# the port closed for longer than the queue can hold and reads what survived.
# The tick numbers are the measurement, so no person has to look at anything.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed
#
# It takes about a minute. Most of that is deliberate silence.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # a board and nothing else: the evidence is a line number
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp134-the-log-nobody-reads

# Long enough that the queue is comfortably overrun. usb-log holds 16 lines and
# this firmware prints one a second, so 40 seconds is two and a half queues —
# far enough past the boundary that a few seconds of jitter cannot change which
# policy the numbers point at.
IDLE=40
QUEUE=16

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# `cd`, not `--manifest-path`: that flag chooses the crate, not the
# configuration, and this directory's .cargo/config.toml cross-compiles.
if (cd ../../crates/log-policy && cargo test --quiet) > /dev/null 2>&1; then
    pass "the log-policy crate's tests pass (every policy, with no board)"
else
    fail "the log-policy crate's tests pass" "cd crates/log-policy && cargo test"
fi

# All three, every time. An experiment whose subject is the difference between
# three builds has to keep all three compiling, and the two nobody flashes are
# the ones that rot.
for spec in "default:" "keep-recent:--features keep-recent" "silent-while-idle:--features silent-while-idle"; do
    name="${spec%%:*}"; flags="${spec#*:}"
    if cargo build --release --quiet $flags 2>/dev/null && [[ -f "$ELF" ]]; then
        UF2="target/exp134-$name.uf2"
        elf2flash convert -b rp2350 "$ELF" "$UF2" > /dev/null 2>&1
        FAMILY="$(od -An -tx4 -j28 -N4 "$UF2" | tr -d ' ')"
        if [[ "$FAMILY" == "e48bff59" ]]; then
            pass "the $name build compiles and converts ($(stat -c%s "$UF2") bytes)"
        else
            fail "the $name build has family ID e48bff59" "got: $FAMILY"
        fi
    else
        fail "the $name build compiles" "cargo build --release $flags"
        exit 1
    fi
done

# The two policies are alternatives, not additions, and the crate says so at
# compile time rather than picking one silently. A build that succeeded here
# would mean somebody's firmware is running a policy they did not choose.
if cargo build --release --quiet --features "keep-recent silent-while-idle" > /dev/null 2>&1; then
    fail "the two policies refuse to be combined" \
         "it compiled — usb-log's compile_error! is gone or unreachable"
else
    pass "the two policies refuse to be combined (compile_error!, not a silent winner)"
fi

# The firmware source must be identical in all three. If it starts branching on
# the feature, the experiment stops being about the queue and starts being
# about three firmwares that happen to share a directory.
if grep -q 'cfg(feature' src/main.rs; then
    fail "one firmware source, three builds" \
         "src/main.rs branches on a feature — the difference belongs in the crate"
else
    pass "one firmware source, three builds (the difference is a constant, not a branch)"
fi

if ! exp_running 134; then
    echo "SKIP  board is not running exp134 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp134"

# ---------------------------------------------------------------------------
# The measurement.
#
# Open the port briefly to drain whatever is queued and to learn which build is
# flashed, close it, stay away for longer than the queue can hold, then open it
# again and look at the *numbers* on the lines that survived.

FIRST_LOOK="$(yi26 log --seconds 4 2>&1)"
POLICY="$(echo "$FIRST_LOOK" | grep -o 'tick #[0-9]* ([a-z-]*)' | tail -1 | sed 's/.*(\(.*\))/\1/')"
if [[ -n "$POLICY" ]]; then
    pass "the flashed build names its policy on every line ($POLICY)"
else
    fail "the flashed build names its policy" "$(echo "$FIRST_LOOK" | tail -2 | tr '\n' ' ')"
    exit "$FAILED"
fi

say_idle="staying off the port for ${IDLE}s — the queue holds ${QUEUE} lines, so this overruns it"
echo "NOTE  $say_idle"
sleep "$IDLE"

CAP="$(yi26 log --seconds 6 2>&1)"
TICKS="$(echo "$CAP" | grep -o 'tick #[0-9]*' | sed 's/tick #//')"
FIRST="$(echo "$TICKS" | head -1)"
LAST="$(echo "$TICKS" | tail -1)"

if [[ -z "$FIRST" || -z "$LAST" ]]; then
    fail "the board is still ticking after the silence" "$(echo "$CAP" | tail -2 | tr '\n' ' ')"
    exit "$FAILED"
fi
pass "the board kept ticking through the silence (last tick #$LAST)"

# Where the gap is, not where the log starts.
#
# The first line is never evidence about the policy. `run` takes a line out of
# the queue *before* it looks at DTR, so under every policy there is one stale
# line held in the writer's hand from before the silence began, and it comes
# out first when a reader finally appears. Measuring from it says the same
# thing about all three.
#
# What separates them is how many lines sit between that held line and the
# jump: sixteen for a queue that kept the oldest, none for one that kept the
# newest or kept nothing. And after the jump, sixteen more for keep-recent
# against only the live stream for the other two.
read -r BEFORE AFTER GAP <<< "$(echo "$TICKS" | awk '
    NR == 1 { prev = $1; before = 1; next }
    {
        if ($1 - prev > 2 && gap == 0) { gap = $1 - prev; after = 1 }
        else if (gap == 0) before++
        else after++
        prev = $1
    }
    END { print before+0, after+0, gap+0 }')"

if (( GAP > 1 )); then
    pass "the silence left a visible gap in the numbering ($GAP ticks)"
else
    fail "the silence left a visible gap" "no jump found — was the port really closed for ${IDLE}s?"
fi

# Loss is reported either way, and the *shape* of the report is part of the
# policy: a delta cannot survive in a queue that evicts what it has accepted,
# so keep-recent reports a running total instead.
case "$POLICY" in
    keep-recent)
        echo "$CAP" | grep -q 'lines lost so far' \
            && pass "keep-recent reports a running total, which survives eviction" \
            || fail "keep-recent reports a running total" "expected '(N lines lost so far)'"
        ;;
    *)
        echo "$CAP" | grep -q '(+[0-9]* lines lost)' \
            && pass "$POLICY reports the loss as a delta on the first surviving line" \
            || fail "$POLICY reports the loss as a delta" "expected '(+N lines lost)'"
        ;;
esac

# And the whole point: which lines came back.
case "$POLICY" in
    drop-newest)
        # The held line plus a full queue of the lines that came straight
        # after it, and then the jump. Those sixteen are the oldest the board
        # had to offer, which is what refusing new arrivals means.
        if (( BEFORE >= QUEUE )); then
            pass "drop-newest handed back the OLD lines ($BEFORE before the gap, first #$FIRST)"
        else
            fail "drop-newest handed back the old lines" \
                 "only $BEFORE lines before the gap — a full queue should give $((QUEUE + 1))"
        fi
        ;;
    keep-recent)
        # The jump comes immediately: everything between the held line and the
        # last sixteen seconds was evicted to make room.
        if (( BEFORE <= 2 && AFTER > QUEUE )); then
            pass "keep-recent handed back the RECENT lines ($BEFORE before the gap, $AFTER after, last #$LAST)"
        else
            fail "keep-recent handed back the recent lines" \
                 "$BEFORE before the gap and $AFTER after — expected about 1 and $((QUEUE + 5))"
        fi
        ;;
    silent-while-idle)
        # One line leaks per idle episode, by design: the flag starts true, so
        # the first line into a closed port is queued before the writer can
        # discover there is nobody there. Nothing else is kept, so what follows
        # the gap is only the live stream.
        if (( BEFORE <= 2 && AFTER <= QUEUE )); then
            pass "silent-while-idle kept almost nothing ($BEFORE stale, $AFTER live after the gap)"
        else
            fail "silent-while-idle kept almost nothing" \
                 "$BEFORE before the gap and $AFTER after — a queue was filling when it should not have been"
        fi
        ;;
esac

echo "NOTE  the other two builds are compiled here but not run. Flashing each in"
echo "      turn and watching the same silence produce three different logs is"
echo "      ./run.sh's job, and it is the whole experiment."

exit "$FAILED"
