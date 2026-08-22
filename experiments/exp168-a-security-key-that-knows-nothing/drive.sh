#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Drive one full round of exp168 and print the transcript, both voices.
#
#   ./drive.sh
#
# The two voices are on two interfaces, which is the point of the device being
# composite: CTAPHID answers on the FIDO interface and the board reports on
# itself over CDC. The log is captured in the background because a security key
# that has gone quiet is the one thing a browser will never tell you about.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
LOGFILE="$(mktemp)"
trap 'rm -f "$LOGFILE"' EXIT

CASES=("init" "ping 8" "ping 57" "ping 58" "ping 200" "ping 1024" "ping 2000"
       "bad-seq" "busy" "truncated" "unknown" "stray-cont")

# A clean boot, so the transcript starts where the firmware does. exp168's own
# log queue holds sixteen lines: a board that has been answering test runs for a
# minute has already dropped the ones worth reading.
echo ">>> host: flashing, so the board's log starts at its own first line"
yi26 bootsel > /dev/null 2>&1
sleep 2
yi26 pflash target/exp168.uf2 > /dev/null 2>&1
sleep 4

echo ">>> host: fido2-token -L, which finds authenticators by usage page and nothing else"
fido2-token -L 2>&1 | sed 's/^/    /'

yi26 log --seconds 60 > "$LOGFILE" 2>&1 &
LOGPID=$!
sleep 1

for C in "${CASES[@]}"; do
    echo ">>> host: case $C"
    # shellcheck disable=SC2086
    python3 ctaphid.py $C 2>&1 | sed 's/^/    /'
done

echo ">>> host: fido2-token -I, which needs a CBOR command this device does not have"
fido2-token -I /dev/hidraw4 2>&1 | sed 's/^/    /' || true

sleep 2
kill "$LOGPID" 2>/dev/null
wait "$LOGPID" 2>/dev/null
echo ">>> board: what it said while all of that happened"
sed 's/^/    /' "$LOGFILE"
