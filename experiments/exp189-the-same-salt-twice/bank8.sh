#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp189 — the second arm, on silicon. Needs a board and **one cable pull**.
#
# The key this arm uses is in no image: it is reconstructed from SRAM bank 8 by
# [crates/fuzzy-commitment], out of a record in flash that is one half of an XOR.
# exp182 measured what that costs and this script is built around it rather than
# around a person's timing:
#
#   * a board straight from a flash **cannot** reconstruct, because the flashing
#     path zeroes the window the key comes from. The first boot below is
#     supposed to say so.
#   * the key comes back on the boot after the power has been away once.
#
# So the one human action is *pull the cable out and put it back*, and this
# waits for it rather than asking for it at a moment nobody is standing there.
#
#   ./bank8.sh
#
# Everything else it reports needs no board at all and has already run in
# check.sh: exp175's forgery mints an assertion from the constant image and finds
# nothing in this one.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

say() { printf '>>> %s\n' "$*" >&2; }

IMG=target/exp189-bank8.uf2
[[ -f "$IMG" ]] || { echo "build it first: EXP189_KEY=bank8 cargo build --release" >&2; exit 1; }

# `--wait` skips the flash and picks up at the cable pull.
#
# It exists because of what the previous version told a person to do when it ran
# out of patience: *"pull the cable and run ./bank8.sh again"*. Running it again
# **reflashes**, and flashing is the one thing that zeroes the window the key
# comes from — so following that instruction destroyed the state the person had
# just spent a cable pull creating, and the next run would ask for another one.
# An instrument whose recovery advice undoes the user's work is worse than one
# that gives no advice.
WAIT_ONLY=0
[[ "${1:-}" == "--wait" ]] && WAIT_ONLY=1

# ---- get the image on, whichever state the board is in ---------------------
if [[ "$WAIT_ONLY" -eq 1 ]]; then
    say "--wait: not flashing. Picking up at the cable pull."
elif yi26 state 2>/dev/null | grep -q running; then
    say "flashing over the running firmware (1200-baud, hands-free)"
    yi26 flash "$IMG" > /dev/null 2>&1 || { echo "flash failed" >&2; exit 1; }
else
    say "waiting for the RP2350 drive — hold BOOTSEL while plugging in, then let go."
    say "the ROM samples that button at power-on only, so there is nothing to keep held."
    D=""
    for _ in $(seq 1 300); do
        [[ -d "/media/$USER/RP2350" ]] && { D="/media/$USER/RP2350"; break; }
        sleep 1
    done
    [[ -n "$D" ]] || { echo "no drive appeared" >&2; exit 1; }
    cp "$IMG" "$D"/ && sync
fi

if [[ "$WAIT_ONLY" -eq 0 ]]; then
    sleep 6
    say "boot 1 — straight from a flash, so the window is zeros and there is no key"
    yi26 log --seconds 5 2>/dev/null | grep -iE "key source|device secret|bank 8|enrolled at" | sed 's/^/    /' >&2
fi

# ---- the one human action, waited for rather than asked for ----------------
# **The board asks, not this script.** A sentence printed here goes to a
# terminal nobody is sitting at, which is how the first run of this experiment
# asked for a press during the one case that must not be pressed — and then
# asked for a cable pull the same way. An unprovisioned board blinks **twice,
# then pauses**, and that pattern means exactly one thing: unplug me.
# What the board looks like has to match what is said about it. Under `--wait`
# the board may already be keyed and idle — describing it as blinking would be
# telling somebody to look for a signal that is not there.
if [[ "$WAIT_ONLY" -eq 1 ]]; then
    # Under `--wait` the board's state is whatever the last run left, and this
    # script did not put it there — so it cannot promise a pattern on the LED.
    # Naming one that is not there is the same mistake as asking for a press
    # during the case that must not be pressed: it sends somebody looking for a
    # signal, and what they find is a light meaning something else.
    STILL="nothing is lost while it waits"
    STILL_LONG="nothing is lost"
    say "pull the cable out and put it back. Nothing else, and nothing to hold."
else
    STILL="the board is still blinking"
    STILL_LONG="it is still blinking two-flashes-then-a-pause"
    say "the board is now blinking two-flashes-then-a-pause. That means: pull the"
    say "cable out and put it back. Nothing else, and there is nothing to hold."
fi

# Watched by the port, because the banner will not wait.
#
# Two earlier versions watched the board's own clock instead, and the second one
# read it correctly — and still could not capture boot 2. The reason is a clash
# of timescales: the firmware's only periodic line is `idle:`, every 30 s, so a
# reboot cannot be *confirmed* until 33 s into the new boot, and the banner this
# script exists to read is printed at **3,040 ms**. By the time the heartbeat
# said "it rebooted" the sentence was thirty seconds gone. The first run of this
# script printed a `boot 2` heading with nothing under it, which is what that
# looks like from outside.
#
# The port node disappearing is the same event, reported in under a second, and
# here it is unambiguous: nothing else in this script touches the cable, and
# `--wait` does not flash. (The earliest version watched `yi26 state` for
# `absent` and was fooled precisely because flashing also produces it.)
PORT="$(yi26 port 2>/dev/null)"
[[ -n "$PORT" && -e "$PORT" ]] || { echo "no serial port — is the board there?" >&2; exit 1; }
acm_present() { compgen -G '/dev/ttyACM*' > /dev/null; }

WAIT_SECS="${EXP189_WAIT_SECS:-1800}"      # half an hour of somebody's time
say "watching $PORT — it disappears the moment the cable comes out"
DEADLINE=$(( SECONDS + WAIT_SECS ))
GONE=0
LAST=0
while (( SECONDS < DEADLINE )); do
    acm_present || { GONE=1; break; }
    sleep 0.2
    if (( SECONDS - LAST >= 120 )); then
        LAST=$SECONDS
        say "still waiting for the cable ($((SECONDS / 60)) min); $STILL"
    fi
done
if [[ "$GONE" -eq 0 ]]; then
    echo "the cable never came out, so there is no second boot to report." >&2
    echo "$STILL_LONG: pull the cable out and put it back, then run" >&2
    echo "  ./bank8.sh --wait   — which does NOT reflash, because reflashing is" >&2
    echo "what zeroes the key you are trying to bring back." >&2
    exit 1
fi
say "the cable is out. Put it back."

BACK=0
DEADLINE=$(( SECONDS + 600 ))
while (( SECONDS < DEADLINE )); do
    acm_present && { BACK=1; break; }
    sleep 0.1
done
[[ "$BACK" -eq 1 ]] || { echo "the cable never went back in." >&2; exit 1; }

say "boot 2 — the power has been away, so the key should be back"
# Straight into the log, with no sleep between: the line is due in three seconds
# and the port has just this moment appeared. A short retry covers the case
# where the node exists but the driver has not finished with it.
mkdir -p work
RAW=work/boot2.log
: > "$RAW"
for _ in 1 2 3; do
    yi26 log --seconds 12 >> "$RAW" 2>/dev/null
    grep -qi 'key source' "$RAW" && break
done
grep -iE "key source|device secret|bank 8|enrolled at" "$RAW" > work/arm.txt
sed 's/^/    /' work/arm.txt >&2

# Written down, not just printed.
#
# The banner is printed **once, at boot**, and `yi26 log` shows a live window —
# so ten minutes later there is no line on the board saying which arm produced
# its bytes. ./roundtrip.sh refuses to write a transcript without one, and its
# only way of getting one was to reflash, which zeroes the key. That left the
# `bank8` arm with no path to the seven presses at all: the one route that
# recorded the banner was the one that destroyed what it was recording.
#
# So boot 2's banner is saved together with the board uptime it was read at.
# ./roundtrip.sh keep will accept it only while the board's clock is still
# **ahead** of that number — a reboot sends it backwards, and a banner from
# before a reboot describes a boot that is over.
AT="$(grep -oE '^\[ *[0-9]+' "$RAW" | tr -dc '0-9\n' | sort -n | tail -1)"
if grep -qi 'key source' work/arm.txt && [[ -n "$AT" ]]; then
    printf 'captured_at_board_ms %s\n' "$AT" >> work/arm.txt
    say "boot 2's banner is in work/arm.txt, stamped at ${AT} ms of this boot"
else
    rm -f work/arm.txt
    echo "boot 2's banner did not come back — work/arm.txt not written, and" >&2
    echo "./roundtrip.sh keep will refuse rather than write a transcript that" >&2
    echo "cannot say which arm it is." >&2
    exit 1
fi

say "and the half that never needed a board:"
for f in target/exp189.uf2 "$IMG"; do
    if python3 ../exp175-the-secret-is-the-file/forge.py "$f" example.test > /dev/null 2>&1; then
        printf '    %-24s exp175 forged an assertion from this image\n' "$(basename "$f")" >&2
    else
        printf '    %-24s exp175 found nothing\n' "$(basename "$f")" >&2
    fi
done

say "if the key came back, ./roundtrip.sh and ./nopress.sh now run against a"
say "secret that is in no file — same seven presses, same four unattended."
