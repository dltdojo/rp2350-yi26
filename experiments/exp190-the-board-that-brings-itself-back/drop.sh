#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp190 — drop four weights on the net, and watch what the board does.
#
#   ./drop.sh          needs a board and nobody
#
# Writes capture.txt. Nothing here touches the board by hand, and that is the
# claim: every recovery below is the firmware's own.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

say()  { printf '>>> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

ELF=target/thumbv8m.main-none-eabihf/release/exp190-the-board-that-brings-itself-back

# --- flashing, done so it cannot race the mount -----------------------------
#
# `yi26 flash` does the 1200-baud touch and then copies. On this host the copy
# sometimes arrives before udisks has mounted the drive, and yi26 reports it as
# "no USB at all" — which cost this experiment three false starts and reads
# exactly like the failure it is meant to measure. So: try yi26, and if the
# board is sitting in BOOTSEL afterwards, finish the job with `cp`.
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

build() { # arm -> uf2
    EXP190_DIE="$1" cargo build --release > /dev/null 2>&1 || { echo "build $1 failed" >&2; exit 1; }
    elf2flash convert -b rp2350 "$ELF" "target/exp190-$1.uf2" > /dev/null 2>&1
}

state() { yi26 state 2>/dev/null; }

# How long the board took to reach a state, or "never".
wait_for() { # state seconds
    local want="$1" limit="$2" i
    for i in $(seq 1 "$limit"); do
        [[ "$(state)" == "$want" ]] && { echo "$i"; return 0; }
        sleep 1
    done
    echo never
    return 1
}

say "building all four arms"
for arm in never late early hang; do build "$arm"; done
note "$(ls -la target/exp190-*.uf2 | wc -l) images"

{
echo "=== exp190 — the board that brings itself back ==="
echo

# ---------------------------------------------------------------- the control
say "arm 1/4: never — the control. It gets up and stays up."
flash target/exp190-never.uf2 || { echo "could not flash"; exit 1; }
sleep 6
echo "-- never --"
yi26 log --seconds 5 2>/dev/null | grep -E "boot |EXP190_DIE" | head -2
echo "state after 10 s: $(sleep 4; state)"
echo

# ------------------------------------------------- a death that must not escape
say "arm 2/4: late — dies AFTER saying it is reachable."
say "         it must come back, and it must NOT be handed to the bootloader."
flash target/exp190-late.uf2 || { echo "could not flash"; exit 1; }
sleep 8
echo "-- late --"
yi26 log --seconds 10 2>/dev/null | grep -E "boot |dying on purpose" | head -6
# **A second session, on purpose.** `yi26 log` cannot survive the board
# re-enumerating: the CDC endpoint goes away with the reboot and takes the
# session with it. So the boot that comes back is read by connecting again,
# which is also how a person would find out.
sleep 8
echo "-- late, after it came back --"
yi26 log --seconds 6 2>/dev/null | grep -E "boot " | head -2
echo "state after 30 s: $(sleep 4; state)"
echo

# ------------------------------------------------------- the weight that matters
say "arm 3/4: early — dies BEFORE it is reachable, by a fault."
say "         nobody touches the board from here."
flash target/exp190-early.uf2 || { echo "could not flash"; exit 1; }
echo "-- early --"
T="$(wait_for bootsel 40 || true)"
echo "reached bootsel after: ${T} s"
echo "drive present: $([[ -d /media/$USER/RP2350 ]] && echo yes || echo no)"
echo

# ------------------------------------- the one no fault handler can catch
say "arm 4/4: hang — stops without dying, interrupts off."
flash target/exp190-hang.uf2 || { echo "could not flash"; exit 1; }
echo "-- hang --"
T="$(wait_for bootsel 40 || true)"
echo "reached bootsel after: ${T} s"
echo "drive present: $([[ -d /media/$USER/RP2350 ]] && echo yes || echo no)"
echo

say "putting the control back"
flash target/exp190-never.uf2 || true
sleep 6
echo "-- restored --"
yi26 log --seconds 5 2>/dev/null | grep -E "boot " | head -1
echo "final state: $(state)"
} 2>&1 | tee capture.txt

echo
say "wrote capture.txt"
python3 verify.py capture.txt
