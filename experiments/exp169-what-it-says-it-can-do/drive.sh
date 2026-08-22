#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Drive one full round of exp169 and print the transcript.
#
#   ./drive.sh
#
# Two builds, because the experiment is a comparison. The default build claims
# no CTAP version at all; the other claims FIDO_2_0, which is not true of it.
# What each costs is measured with the host's own tooling rather than argued.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
LOGFILE="$(mktemp)"
trap 'rm -f "$LOGFILE"' EXIT

CASES=("init" "ping 8" "ping 57" "ping 58" "ping 200" "ping 1024" "ping 2000"
       "bad-seq" "busy" "truncated" "unknown" "stray-cont"
       "getinfo" "getinfo-params" "makecred" "ctap-unknown")

dev() { fido2-token -L 2>/dev/null | head -1 | cut -d: -f1; }

echo ">>> host: flashing the honest build (EXP169_CLAIM=none), so the log starts at its own first line"
yi26 bootsel > /dev/null 2>&1
sleep 2
yi26 pflash target/exp169-none.uf2 > /dev/null 2>&1
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

echo ">>> host: fido2-token -I on the build that claims nothing"
fido2-token -I "$(dev)" 2>&1 | sed 's/^/    /' || true

sleep 2
kill "$LOGPID" 2>/dev/null
wait "$LOGPID" 2>/dev/null
echo ">>> board: what it said while all of that happened"
sed 's/^/    /' "$LOGFILE"

echo ">>> host: now the build that claims FIDO_2_0, which is not true of it"
yi26 bootsel > /dev/null 2>&1
sleep 2
yi26 pflash target/exp169-fido2.uf2 > /dev/null 2>&1
sleep 4
echo ">>> host: fido2-token -I on the build that claims a version"
fido2-token -I "$(dev)" 2>&1 | sed 's/^/    /' || true
echo ">>> host: and a tool that believes the claim and acts on it"
fido2-token -I -c "$(dev)" 2>&1 | sed 's/^/    /' || true
