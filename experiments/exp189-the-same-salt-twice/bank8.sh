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

# ---- get the image on, whichever state the board is in ---------------------
if yi26 state 2>/dev/null | grep -q running; then
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
sleep 6

say "boot 1 — straight from a flash, so the window is zeros and there is no key"
yi26 log --seconds 5 2>/dev/null | grep -iE "key source|device secret|bank 8|enrolled at" | sed 's/^/    /' >&2

# ---- the one human action, waited for rather than asked for ----------------
# **The board asks, not this script.** A sentence printed here goes to a
# terminal nobody is sitting at, which is how the first run of this experiment
# asked for a press during the one case that must not be pressed — and then
# asked for a cable pull the same way. An unprovisioned board blinks **twice,
# then pauses**, and that pattern means exactly one thing: unplug me.
say "the board is now blinking two-flashes-then-a-pause. That means: pull the"
say "cable out and put it back. Nothing else, and there is nothing to hold."

# Watched by the board's own clock, not by the port coming and going.
#
# The first version waited for `yi26 state` to say `absent` — and flashing makes
# it say that, so the script congratulated itself on a cable pull that had not
# happened and read boot 1 twice. A reboot is the only thing that sends the
# uptime backwards, so that is what is waited for.
# An idle board is quiet, so a short window can come back with nothing — and a
# missing number defaulted to 0, against which nothing is ever "backwards". The
# firmware prints an `idle:` line periodically; this waits for one rather than
# assuming one arrived.
uptime_ms() {
    yi26 log --seconds "${1:-12}" 2>/dev/null | grep -oE '^\[ *[0-9]+' | tr -dc '0-9\n' | sort -n | tail -1
}
BEFORE=""
for _ in 1 2 3; do
    BEFORE="$(uptime_ms 14)"
    [[ -n "$BEFORE" ]] && break
done
[[ -n "$BEFORE" ]] || { echo "the board said nothing at all — is it still there?" >&2; exit 1; }
say "board uptime is ${BEFORE} ms; waiting for that to go backwards"
# Giving up has to say so.
#
# The first version ran out of its window in silence and then printed a section
# headed "boot 2" describing a board that had never rebooted — a confident,
# plausible lie of exactly the kind `crates/breadcrumb` warns about in its own
# source. There is no such thing as a boot-2 reading without a boot 2.
REBOOTED=0
for _ in $(seq 1 40); do
    NOW="$(uptime_ms 14)"
    if [[ -n "$NOW" && "$NOW" -lt "$BEFORE" ]]; then
        say "it rebooted — uptime went ${BEFORE} -> ${NOW} ms"
        REBOOTED=1
        break
    fi
done
if [[ "$REBOOTED" -eq 0 ]]; then
    echo "the board never rebooted, so there is no second boot to report." >&2
    echo "it is still blinking two-flashes-then-a-pause: pull the cable and run" >&2
    echo "./bank8.sh again. Nothing below this line would have meant anything." >&2
    exit 1
fi
sleep 4

say "boot 2 — the power has been away, so the key should be back"
yi26 log --seconds 6 2>/dev/null | grep -iE "key source|device secret|bank 8|enrolled at" | sed 's/^/    /' >&2

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
