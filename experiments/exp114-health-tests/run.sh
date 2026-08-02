#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp114 interactive walkthrough — the two continuous health tests from
# SP 800-90B, and a source that refuses to emit when they fail.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp114-health-tests
UF2=target/exp114-health-tests.uf2

# Long enough for the adaptive proportion window to close: 1024 samples at
# 256 per round, plus the two-second wait for USB to settle first.
WATCH_S=12

echo "${BOLD}exp114 — tests that refuse${RESET}"
say ""
say "exp111 printed two percentages and said plainly that this was monitoring,"
say "not certification. It pointed at NIST SP 800-90B and called it a document"
say "rather than a function call."
say ""
say "This is the part of that document that ${BOLD}is${RESET} a function call — and one"
say "behaviour separates it from every test here so far: when a source fails,"
say "it stops being used."

# ---------------------------------------------------------------------------
step 1 "Check the tests before trusting them"
say "The cutoffs are the experiment. They are also arithmetic, so they can be"
say "checked on this machine with no board and no cross-compiler."
run_cmd sh -c "cd ../../crates/entropy-health && cargo test"
ok "The thresholds, an off-by-one, and two known-bad inputs are all pinned."

# ---------------------------------------------------------------------------
step 2 "Build and flash"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$UF2"
run_cmd yi26 flash "$UF2"
ok "Running."

# ---------------------------------------------------------------------------
step 3 "Three sources, judged continuously"
say ""
say "  ${BOLD}trng${RESET}    the hardware source from exp109 — should pass"
say "  ${BOLD}adc${RESET}     the sensor's bottom bit from exp111 — exp111 found it wanders"
say "  ${BOLD}broken${RESET}  nine ones then a zero, forever — ${BOLD}must${RESET} be rejected"
say ""
say "That third one is not a joke. A check you have never seen fire is"
say "indistinguishable from a check that cannot fire."
say ""

OUT="$(exp_read_log "$WATCH_S")"
echo "$OUT" | grep -v 'heartbeat' | sed 's/^/    /'
echo

# ---------------------------------------------------------------------------
step 4 "What the verdicts say"

T="$(echo "$OUT" | grep 'trng  :' | tail -1 || true)"
A="$(echo "$OUT" | grep 'adc   :' | tail -1 || true)"
B="$(echo "$OUT" | grep 'broken:' | tail -1 || true)"

[[ -n "$T" ]] && say "  ${DIM}${T#*] }${RESET}"
[[ -n "$A" ]] && say "  ${DIM}${A#*] }${RESET}"
[[ -n "$B" ]] && say "  ${DIM}${B#*] }${RESET}"
say ""

if echo "$B" | grep -q 'FAILED adaptive proportion'; then
    ok "The known-bad source was rejected — by the second test, not the first."
    say "  Nine ones then a zero never repeats 21 times, so the repetition count"
    say "  cannot see it. That is why there are two tests."
else
    say "${YELLOW}The broken source has not been rejected yet.${RESET}"
    say "  Its window needs 1024 samples. Run ./check.sh in a moment."
fi

if echo "$A" | grep -q 'FAILED repetition'; then
    say ""
    bad "The ADC failed after a handful of bits — twenty-one identical in a row."
    say "  exp111 scored the same source between 32.8% and 84.1% on monobit, and"
    say "  once a clean-looking 47.5%. A percentage averaged over thousands of"
    say "  bits cannot see a run, and a run is what a stuck source produces."
fi

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp114 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. A health test gates its source. Everything before this printed a"
say "     number and carried on; this withholds output. One 'if'."
say "  2. Two tests catch two different failures. Stuck is not the same as"
say "     biased, and a test for one is blind to the other."
say "  3. Cutoffs come from a false-positive budget, not from taste. Making"
say "     one stricter by feel raises the alarm rate, and an alarm that cries"
say "     wolf gets switched off."
say ""
say "What this still does not do: '0101010101...' passes ${BOLD}both${RESET} tests forever."
say "There is a unit test asserting exactly that. Read the README's last two"
say "sections before reusing any of it."
