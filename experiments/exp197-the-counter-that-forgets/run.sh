#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp197 run — the whole experiment, recorded to capture.txt.
#
# The model and the crate need no board. The board half needs any RP2350 board
# and nobody: it builds exp189 — the head of the chain, and one of the four
# firmwares now on crates/client-pin — flashes it, so that no PIN is set, and
# runs pin_rules_probe.py over hidraw. Without a board it says so; it is never
# filled in by hand.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

EXP189=../exp189-the-same-salt-twice
ELF=$EXP189/target/thumbv8m.main-none-eabihf/release/exp189-the-same-salt-twice
IMG=$EXP189/target/exp197-exp189.uf2

{
capture_header "exp197 — the counter that forgets"

echo ">>> steps 1 and 2: every configuration in model/expected.txt"
echo "    TLC $(java -cp ../../tools/tlc/tla2tools.jar tlc2.TLC -h 2>&1 | grep -o 'Version [0-9.]*' | head -1), one worker, breadth first"
echo
../../tools/tlc/tlc.sh table model
echo

echo ">>> step 3 and 4 on a host: crates/client-pin"
( cd ../../crates/client-pin && cargo test -- --test-threads 1 2>&1 ) | grep -E '^test [a-z0-9_:]+ \.\.\. '
echo

echo ">>> the board half: exp189, freshly flashed, asked over hidraw"
case "$(yi26 state 2>/dev/null)" in
    running|bootsel)
        ( cd "$EXP189" && cargo build --release > /dev/null 2>&1 ) \
            || { echo "could not build exp189"; exit 1; }
        elf2flash convert -b rp2350 "$ELF" "$IMG" > /dev/null 2>&1 \
            || { echo "could not convert exp189"; exit 1; }
        flash_uf2 "$IMG" || { echo "could not flash"; exit 1; }
        up=no
        for _ in $(seq 1 15); do exp_running 189 && { up=yes; break; }; sleep 1; done
        [[ "$up" == yes ]] || { echo "exp189 did not come up"; exit 1; }
        sleep 2
        echo "-- pin_rules_probe --"
        python3 pin_rules_probe.py 2>&1 | tail -1
        ;;
    *)
        echo "not captured: no board attached"
        ;;
esac
} 2>&1 | tee capture.txt
