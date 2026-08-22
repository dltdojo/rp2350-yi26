#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Drive one full round of exp169 and print the transcript.
#
#   ./drive.sh
#
# The eight `mc-` cases are the experiment. Six of them are shapes a
# well-behaved client never sends, and one of those — a byte string whose
# length runs past the message — is the reason this experiment comes before the
# one that signs anything.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
LOGFILE="$(mktemp)"
trap 'rm -f "$LOGFILE"' EXIT

CASES=("init" "ping 58" "ping 1024" "ping 2000" "bad-seq" "busy" "truncated"
       "unknown" "stray-cont" "getinfo" "getinfo-params" "ctap-unknown"
       "mc-good" "mc-lying-length" "mc-noncanonical" "mc-trailing"
       "mc-missing-cdh" "mc-missing-params" "mc-no-es256" "mc-many-algs")

dev() { fido2-token -L 2>/dev/null | head -1 | cut -d: -f1; }

echo ">>> host: flashing, so the board's log starts at its own first line"
yi26 bootsel > /dev/null 2>&1
sleep 2
yi26 pflash target/exp170.uf2 > /dev/null 2>&1
sleep 4

echo ">>> host: fido2-token -L"
fido2-token -L 2>&1 | sed 's/^/    /'

yi26 log --seconds 90 > "$LOGFILE" 2>&1 &
LOGPID=$!
sleep 1

for C in "${CASES[@]}"; do
    echo ">>> host: case $C"
    # shellcheck disable=SC2086
    python3 ctaphid.py $C 2>&1 | sed 's/^/    /'
done

echo ">>> host: fido2-token -I"
fido2-token -I "$(dev)" 2>&1 | sed 's/^/    /' || true

sleep 2
kill "$LOGPID" 2>/dev/null
wait "$LOGPID" 2>/dev/null
echo ">>> board: what it said while all of that happened"
sed 's/^/    /' "$LOGFILE"

