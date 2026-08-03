#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp134 walkthrough — the same silence, three times, three different logs.
#
# Flashes each policy in turn, stays off the port for longer than the queue can
# hold, and then reads it. Nothing here needs a hand on the board: every build
# carries the 1200-baud watcher, so the flashing is software all the way down.
#
#   ./run.sh
#
# It takes about four minutes, and most of that is the experiment doing
# nothing on purpose.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp134-the-log-nobody-reads

# 16 lines of queue, one line a second. 40 seconds is two and a half queues.
IDLE=40

echo "exp134 — the log nobody reads"
say ""
say "One firmware, one line a second, built three ways. Each build is left"
say "alone for ${IDLE}s with the port closed — longer than its 16-line queue can"
say "hold — and then read. The tick numbers say what survived."
say ""
say "This is the question behind a capture in exp127: a phone connected, and"
say "the log had a 125-second hole ending exactly where the operator arrived."

build() {
    local name="$1" flags="$2"
    cargo build --release --quiet $flags || die "build failed: $name"
    elf2flash convert -b rp2350 "$ELF" "target/exp134-$name.uf2" > /dev/null \
        || die "convert failed: $name"
}

# Flash a policy, stay away, then look.
episode() {
    local name="$1" flags="$2" expect="$3"

    build "$name" "$flags"
    run_cmd yi26 flash "target/exp134-$name.uf2"

    say ""
    say "  Now nobody reads it for ${IDLE}s. The board keeps ticking."
    say "  ${DIM}(the port is closed, so DTR is low, so usb-log will not write)${RESET}"
    sleep "$IDLE"

    say ""
    say "  Opening the port. Watch the ${BOLD}first${RESET} tick number:"
    run_cmd yi26 log --seconds 6
    say ""
    say "  ${BOLD}Expect:${RESET} $expect"
}

# ---------------------------------------------------------------------------
step 1 "drop-newest — what this repository has always done"
say ""
say "The default. A full queue refuses new lines, so the sixteen it kept are"
say "the sixteen ${BOLD}oldest${RESET}. Nobody chose this; it is what Channel::try_send"
say "does, adopted by not asking."
episode "default" "" \
    "an old tick number, then a jump of about ${IDLE}, then the present."
pause "Read the gap."

# ---------------------------------------------------------------------------
step 2 "keep-recent — evict the head instead"
say ""
say "Same RAM, same time per call, one different decision: when the queue is"
say "full, throw away the ${BOLD}oldest${RESET} line to make room for the newest."
say ""
say "Watch the loss marker too. It changes shape, and it has to: a delta is"
say "rendered into one line's text, and this policy throws lines away — so the"
say "count would go with them. It reports a running total instead."
episode "keep-recent" "--features keep-recent" \
    "a tick number about 16 behind the last one. The recent seconds, not the old ones."
pause "Compare that first number with step 1."

# ---------------------------------------------------------------------------
step 3 "silent-while-idle — queue nothing at all"
say ""
say "Neither of the above. While no host has the port open, refuse everything"
say "and count it. Keep nothing, and guarantee the first line a reader sees"
say "describes the present."
say ""
say "One line still gets through, and that is not a bug — usb_log::log cannot"
say "ask whether a reader is there, it has to be told by the writer task, and"
say "nobody can tell it until the writer has looked at least once."
episode "silent-while-idle" "--features silent-while-idle" \
    "one stale tick, then the present. Nothing in between was kept."

# ---------------------------------------------------------------------------
step 4 "What you just saw"
say ""
say "Three logs, one firmware, one queue size. The difference was never the"
say "depth: 16 lines at one a second is 16 seconds, and 64 would be a minute."
say "The gap is however long nobody was looking, which has no upper bound."
say ""
say "  ${BOLD}drop-newest${RESET}         the oldest lines      chasing a crash"
say "  ${BOLD}keep-recent${RESET}         the newest lines      what is it doing now"
say "  ${BOLD}silent-while-idle${RESET}   none, honestly counted  nobody was there yet"
say ""
say "None of them is right in general, which is why it is a policy and not a"
say "constant. What stays unconditional is the count."
say ""
ok "Done. ./check.sh proves the same thing without narration."
say ""
say "The board is currently running the silent-while-idle build. To put the"
say "default back:"
say "  ${DIM}\$ yi26 flash target/exp134-default.uf2${RESET}"
