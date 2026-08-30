#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# exp193 — walk towards the configuration-descriptor wall until the board hits
# it, and measure every step from the host.
#
#   ./drop.sh          needs a board and nobody
#
# Writes capture.txt. The board is never touched by hand, and that is half the
# claim: the step that does not fit panics before USB exists, and `lifeline`
# has to bring the board back from that by itself.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

# For `capture_header`, so the recording says which tree produced it.
source ../lib.sh

say()  { printf '>>> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

ELF=target/thumbv8m.main-none-eabihf/release/exp193-how-many-doors-fit

# The ceiling in build.rs. The walk stops here whatever happens, so a budget
# that turns out to be bigger than expected fails as a finding rather than as an
# infinite loop.
CEILING=12

# --- flashing, done so it cannot race the mount -----------------------------
#
# Inherited whole from exp190's drop.sh, including the reason: `yi26 flash` does
# the 1200-baud touch and then copies, and on this host the copy sometimes
# arrives before udisks has mounted the drive.
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

build() { # lane n -> uf2
    local lane="$1" n="$2" flags=""
    [[ "$lane" == wide ]] && flags="--features wide"
    # shellcheck disable=SC2086
    EXP193_HID="$n" cargo build --release $flags > /dev/null 2>&1 \
        || { echo "build $lane HID=$n failed" >&2; exit 1; }
    elf2flash convert -b rp2350 "$ELF" "target/exp193-$lane-hid$n.uf2" > /dev/null 2>&1
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

# --- the instrument ---------------------------------------------------------
#
# **The host is the witness, not the board.** A firmware that dropped an
# interface would report the number it meant to build, so the number that counts
# is the one Linux read off the wire during enumeration. `descriptors` in sysfs
# is the raw bytes: the 18-byte device descriptor, then the configuration
# descriptor whose `wTotalLength` is its bytes 2..4 and whose `bNumInterfaces`
# is byte 4.
measure() {
    python3 - <<'PY'
import glob, pathlib, sys
for d in glob.glob("/sys/bus/usb/devices/*/"):
    p = pathlib.Path(d)
    try:
        if (p / "idVendor").read_text().strip() != "1209":
            continue
        if (p / "idProduct").read_text().strip() != "0001":
            continue
        if (p / "serial").read_text().strip() != "193":
            continue
        b = (p / "descriptors").read_bytes()
    except OSError:
        continue
    cfg = b[18:]
    print(f"wTotalLength={cfg[2] | cfg[3] << 8} bNumInterfaces={cfg[4]}")
    sys.exit(0)
print("wTotalLength=none bNumInterfaces=none")
PY
}

# The two lanes walk the same steps, so they are built in one pass and the
# board only ever sees one image at a time.
say "building both lanes, every step up to $CEILING"
for lane in narrow wide; do
    for n in $(seq 0 "$CEILING"); do build "$lane" "$n"; done
done
note "$(ls target/exp193-*-hid*.uf2 | wc -l) images"

{
capture_header "exp193 — how many doors fit"

# `narrow` is embassy-usb as every experiment in this repository has ever built
# it. `wide` raises MAX_INTERFACE_COUNT and MAX_HANDLER_COUNT to 8, which is the
# largest the crate offers. Walking both is the whole point: one wall is a Cargo
# feature and the other is a byte count, they are at different places, and a run
# that only walked one lane could not tell you which one it had found.
for lane in narrow wide; do
    echo "== lane $lane =="
    WALL=""
    for n in $(seq 0 "$CEILING"); do
        echo "-- $lane hid $n --"
        flash "target/exp193-$lane-hid$n.uf2" || { echo "could not flash"; exit 1; }

        if [[ "$(wait_for running 12)" == never ]]; then
            # It did not come up. Either it hit a wall, or something else broke
            # — and the difference is where it went. A board that panicked
            # before USB is one `lifeline` counts, and after three of those it
            # hands itself over with nobody in the room.
            echo "did not enumerate"
            echo "bootsel after: $(wait_for bootsel 20) s"
            echo "drive present: $([[ -d "/media/$USER/RP2350" ]] && echo yes || echo no)"
            WALL="$n"
            break
        fi

        echo "host says: $(measure)"
        yi26 log --seconds 5 2>/dev/null | grep -E "EXP193_HID" | head -1
    done

    echo
    echo "-- $lane wall --"
    if [[ -n "$WALL" ]]; then
        echo "first shape that did not fit: hid $WALL"
    else
        echo "first shape that did not fit: none up to $CEILING"
    fi
    echo
done

# --- and it is reflashable, with nobody in the room -------------------------
#
# The point of measuring the wall from a board that walked into it is that the
# next image can still be put on it. If this needed a person, everything above
# would be a description of how to brick a board.
echo
echo "-- restored --"
flash "target/exp193-narrow-hid0.uf2" || { echo "could not flash"; exit 1; }
sleep 6
yi26 log --seconds 5 2>/dev/null | grep -E "EXP193_HID" | head -1
echo "final state: $(state)"
echo "final host says: $(measure)"
} 2>&1 | tee capture.txt

say "wrote capture.txt"
python3 verify.py capture.txt
