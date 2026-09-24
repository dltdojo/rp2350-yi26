#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp196 run — the whole experiment, recorded to capture.txt.
#
# The model, the replay and the socket half need no board. The board half needs
# any RP2350 board and nobody: it builds exp194's own firmware — which runs its
# transport through crates/ctap-hid — flashes it, and asks it two questions over
# hidraw: the one exp194 asked (busy-recovers) and the one after it
# (init-keeps-other). Without a board it says so and is skipped; it is never
# filled in by hand.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

EXP194=../exp194-the-transport-that-drifted
ELF=$EXP194/target/thumbv8m.main-none-eabihf/release/exp194-the-transport-that-drifted
IMG=$EXP194/target/exp196-exp194.uf2
CLIENT=../../tools/ctaphid/ctaphid.py

{
capture_header "exp196 — the INIT from another channel"

echo ">>> steps 1 and 2: every configuration in model/expected.txt"
echo "    TLC $(java -cp ../../tools/tlc/tla2tools.jar tlc2.TLC -h 2>&1 | grep -o 'Version [0-9.]*' | head -1), one worker, breadth first"
echo
../../tools/tlc/tlc.sh table model
echo

echo ">>> step 3 and 4 on a host: replay/, the crate before exp196 and after"
( cd replay && cargo test -- --test-threads 1 2>&1 ) | grep -E '^test [a-z0-9_]+ ... '
echo

echo ">>> end to end over a socket: tools/vctaphid/selftest.sh"
../../tools/vctaphid/selftest.sh 2>&1 | grep -E '^(PASS|FAIL)|PRE-FLIGHT'
echo

echo ">>> the board half: exp194's firmware, asked over hidraw"
case "$(yi26 state 2>/dev/null)" in
    running|bootsel)
        ( cd "$EXP194" && cargo build --release > /dev/null 2>&1 ) \
            || { echo "could not build exp194"; exit 1; }
        elf2flash convert -b rp2350 "$ELF" "$IMG" > /dev/null 2>&1 \
            || { echo "could not convert exp194"; exit 1; }
        flash_uf2 "$IMG" || { echo "could not flash"; exit 1; }
        up=no
        for _ in $(seq 1 15); do exp_running 194 && { up=yes; break; }; sleep 1; done
        [[ "$up" == yes ]] || { echo "exp194 did not come up"; exit 1; }
        # The FIDO interface is granted a moment after the CDC one; see exp194.
        sleep 2
        for c in busy-recovers init-keeps-other; do
            echo "-- $c --"
            python3 "$CLIENT" "$c" 2>&1 | tail -1
            # busy-recovers leaves a transaction to expire; let it.
            sleep 8
        done
        ;;
    *)
        echo "not captured: no board attached"
        ;;
esac
} 2>&1 | tee capture.txt
