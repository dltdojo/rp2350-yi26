#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# exp194 — ask six firmwares from one accretion chain the same nine questions,
# and record where they answer differently.
#
#   ./drift.sh          needs a board and nobody
#
# Writes capture.txt. Every case is one where CTAP-HID says what the right
# answer is, so what comes out is a grading rather than a description. No case
# reaches user presence, so nothing here needs a finger.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh

say()  { printf '>>> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

CLIENT=../../tools/ctaphid/ctaphid.py

# Six samples spanning the chain, by `ctaphid_task` length: 110 at exp168, 241,
# 451, 531, the exp184 fork that branched from before 531, and 959 at exp189.
# Not all fourteen: each costs a flash, and six that span the chain answer the
# question fourteen would.
SUBJECTS=(
    exp168-a-security-key-that-knows-nothing
    exp170-a-map-somebody-else-wrote
    exp172-the-same-key-twice
    exp174-a-deadline-nobody-mentioned
    exp184-the-client-that-must-know
    exp189-the-same-salt-twice
)

# Order matters, and finding that out is part of the result. A case that leaves
# a transaction abandoned can put a device into a state the next case then
# measures instead of its own subject — which is exactly what happened the first
# time this ran: exp189's `busy` swallowed the four cases after it. The two that
# leave a channel occupied go last, and each is followed by a settle long enough
# for a device that recovers to have recovered.
CASES=(init "ping 57" "ping 1024" "ping 1025" bad-seq unknown bad-cid stray-cont init-resets truncated busy busy-recovers)

# How long to leave a device alone after a case that abandons a transaction.
# CTAP-HID names 750 ms as the transaction timeout; exp189 takes about four
# seconds, so eight is generous for anything that recovers at all.
SETTLE_AFTER="truncated busy busy-recovers"

flash() { # uf2
    local img="$1"
    yi26 flash "$img" > /dev/null 2>&1 && return 0
    for _ in $(seq 1 30); do
        if [[ -d "/media/$USER/RP2350" ]]; then
            cp "$img" "/media/$USER/RP2350/" && sync && return 0
        fi
        sleep 1
    done
    return 1
}

state() { yi26 state 2>/dev/null; }

wait_for() { # state seconds
    local want="$1" limit="$2" i
    for i in $(seq 1 "$limit"); do
        [[ "$(state)" == "$want" ]] && { echo "$i"; return 0; }
        sleep 1
    done
    echo never
    return 1
}

say "building ${#SUBJECTS[@]} subjects"
for s in "${SUBJECTS[@]}"; do
    ( cd "../$s" && cargo build --release -q > /dev/null 2>&1 ) \
        || { echo "build $s failed" >&2; exit 1; }
    elf="$(ls ../$s/target/thumbv8m.main-none-eabihf/release/${s} 2>/dev/null)"
    elf2flash convert -b rp2350 "$elf" "target-uf2/${s:0:6}.uf2" > /dev/null 2>&1
done
note "$(ls target-uf2/*.uf2 2>/dev/null | wc -l) images"

{
capture_header "exp194 — the transport that drifted"

for s in "${SUBJECTS[@]}"; do
    short="${s:0:6}"
    echo "== $short =="
    flash "target-uf2/$short.uf2" || { echo "could not flash"; continue; }
    if [[ "$(wait_for running 15)" == never ]]; then
        echo "did not come up"
        continue
    fi
    # The FIDO interface takes a moment past the CDC one to be granted to this
    # user by udev; asking too early reads as a device that has no HID at all.
    sleep 2
    for c in "${CASES[@]}"; do
        # shellcheck disable=SC2086
        echo "-- $short | $c --"
        python3 "$CLIENT" $c 2>&1 | tail -1
        if [[ " $SETTLE_AFTER " == *" ${c%% *} "* ]]; then sleep 8; else sleep 1; fi
    done
    echo
done
} 2>&1 | tee capture.txt

say "wrote capture.txt"
python3 verify.py capture.txt
