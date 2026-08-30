#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# Run tools/ctaphid's whole suite against tools/vctaphid — no board, nobody.
#
#   ./selftest.sh        exit 0 = every case answered what the spec requires
#
# This is a PRE-FLIGHT CHECK, not a verification. It says that a change to
# crates/ctap-hid or to tools/ctaphid/ctaphid.py did not break the twelve
# answers. It touches no USB stack and no silicon, so nothing it prints may be
# pasted into an experiment's `Expected output`, and no `Needs` level moves
# because it passes. See README.md.
#
# The last check is the important one: the suite is pointed at a device built
# to answer one question wrong, and has to catch it. exp160 shipped a check
# that could not fail and nobody noticed for a long time.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../../experiments/lib.sh

CLIENT=../ctaphid/ctaphid.py
DEV=./target/release/vctaphid
WORK="$(mktemp -d)"
DEV_PID=""

cleanup() {
    # By recorded PID, never by pattern: `pkill -f` on anything matching
    # "vctaphid" also matches the shell running this script.
    [[ -n "$DEV_PID" ]] && kill "$DEV_PID" 2> /dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# Start a device and wait for it to say it is listening. Polling for the socket
# file would race the bind; the line is printed after it.
#
# It sets SOCK rather than echoing it. Echoing would mean a caller writing
# `SOCK="$(start_device ...)"`, and the FAIL line below would then be captured
# into that variable instead of printed — a failure whose only symptom is a
# later, wronger error.
SOCK=""
start_device() { # socket-name [extra args...]
    SOCK="$WORK/$1"; shift
    "$DEV" --socket "$SOCK" "$@" > "$WORK/dev.log" 2>&1 &
    DEV_PID=$!
    local i
    for i in $(seq 1 100); do
        grep -q "^ready " "$WORK/dev.log" 2> /dev/null && return 0
        kill -0 "$DEV_PID" 2> /dev/null || break
        sleep 0.05
    done
    fail "the device started" "$(cat "$WORK/dev.log")"
    return 1
}

stop_device() {
    [[ -n "$DEV_PID" ]] && kill "$DEV_PID" 2> /dev/null
    wait "$DEV_PID" 2> /dev/null
    DEV_PID=""
}

# One case, one verdict string.
verdict() { # socket case [args...]
    local sock="$1"; shift
    python3 "$CLIENT" --socket "$sock" "$@" 2> "$WORK/err.log" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])' \
        2> /dev/null || echo "client failed: $(tail -1 "$WORK/err.log")"
}

command -v python3 > /dev/null || { fail "python3 present" "needed to drive the suite"; exit 1; }
command -v cargo > /dev/null || { fail "cargo present" "needed to build the device"; exit 1; }

cargo build --release --quiet 2> "$WORK/build.log" \
    && pass "the device builds" \
    || { fail "the device builds" "$(tail -3 "$WORK/build.log")"; exit 1; }

# --- every case, against a device that answers correctly --------------------

start_device correct.sock || exit 1

for case in $(python3 "$CLIENT" --list | awk '{print $1}'); do
    v="$(verdict "$SOCK" "$case")"
    [[ "$v" == "spec" ]] && pass "$case" || fail "$case" "$v"
done

# The two lengths the transport's contract turns on, which `--list` does not
# reach: the largest message that must be echoed, and the first that must be
# refused rather than truncated.
for n in 1024 1025; do
    v="$(verdict "$SOCK" ping "$n")"
    [[ "$v" == "spec" ]] && pass "ping $n" || fail "ping $n" "$v"
done

stop_device

# --- and one that answers a question wrong, which must be caught ------------

start_device wrong.sock --wrong bad-cid-par || exit 1

v="$(verdict "$SOCK" bad-cid)"
if [[ "$v" == "spec" ]]; then
    fail "the suite catches a wrong answer" \
         "a device answering ERR_INVALID_PAR was graded 'spec' — the suite is describing, not grading"
elif [[ "$v" == *ERR_INVALID_PAR* ]]; then
    pass "the suite catches a wrong answer, and names it: $v"
else
    fail "the suite catches a wrong answer" "caught it, but reported '$v' rather than the error it got"
fi

stop_device

echo
[[ $FAILED -eq 0 ]] \
    && echo "PRE-FLIGHT ONLY: this says nothing about any board." \
    || echo "something above failed."
exit $FAILED
