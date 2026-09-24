#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp195 run — the whole experiment, recorded to capture.txt.
#
# The model half needs Java and nothing else. The board half needs any RP2350
# board and nobody: it builds exp190's control arm once, flashes that same
# image twice through the 1200-baud touch, and reads what each boot believes.
# The second flash is the measurement — exp190 onto exp190, the path the model
# says a rebuild takes. Without a board the board half says so and is skipped;
# it is never filled in by hand.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh

EXP190=../exp190-the-board-that-brings-itself-back
ELF=$EXP190/target/thumbv8m.main-none-eabihf/release/exp190-the-board-that-brings-itself-back
IMG=$EXP190/target/exp195-exp190-never.uf2

{
capture_header "exp195 — the bug the model saw first"

echo ">>> the model half: every configuration in model/expected.txt"
echo "    TLC $(java -cp ../../tools/tlc/tla2tools.jar tlc2.TLC -h 2>&1 | grep -o 'Version [0-9.]*' | head -1), one worker, breadth first"
echo
../../tools/tlc/tlc.sh table model
echo
echo ">>> the shortest counterexample under a preemptive scheduler, in full"
../../tools/tlc/tlc.sh trace model usblog-preemptive
echo

echo ">>> the board half: exp190's control arm, flashed twice through the 1200-baud touch"
case "$(yi26 state 2>/dev/null)" in
    running|bootsel)
        ( cd "$EXP190" && EXP190_DIE=never cargo build --release > /dev/null 2>&1 ) \
            || { echo "could not build exp190"; exit 1; }
        elf2flash convert -b rp2350 "$ELF" "$IMG" > /dev/null 2>&1 \
            || { echo "could not convert exp190"; exit 1; }
        for n in 1 2; do
            flash_uf2 "$IMG" || { echo "could not flash (attempt $n)"; exit 1; }
            sleep 6
            echo "-- flash $n --"
            yi26 log --seconds 5 2>/dev/null | grep -m1 'boot '
            echo
        done
        ;;
    *)
        echo "not captured: no board attached"
        ;;
esac
} 2>&1 | tee capture.txt
