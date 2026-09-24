#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp195 quick check — the model half needs no board; the board half is run.sh.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# The claim includes a fix to a crate every flashing firmware links, and that is
# verified by flashing exp190 twice and reading what it says. A board attached;
# nobody at it.
PRESENCE=1
LIFELINE="no: no firmware of its own — its board half reflashes exp190, which has one"
presence_check
lifeline_check

# No firmware of its own. The board half runs exp190 and reads its log.
USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="exp190"
usb_check

TLC=../../tools/tlc/tlc.sh
if ! command -v java > /dev/null; then
    echo "SKIP  the model half: no java on this machine (TLC needs Java 11 or later)"
    exit "$FAILED"
fi
if [[ ! -f ../../tools/tlc/tla2tools.jar ]]; then
    fail "tla2tools.jar is fetched" "run ../../tools/tlc/setup.sh — it needs the network once"
    exit 1
fi
( cd ../../tools/tlc && ./setup.sh > /dev/null 2>&1 ) \
    && pass "tla2tools.jar is the one tools/tlc/setup.sh pins" \
    || fail "tla2tools.jar matches the pinned sha256" "re-run tools/tlc/setup.sh"

# Every result below is a PASS/FAIL line from tools/tlc/tlc.sh, which exits
# non-zero if any of its lines failed.
# --- the models are well-formed, and still cite the code they translate ---
#
# A model is a second description of the program, which is the thing
# docs/what-belongs-to-an-experiment.md exists to prevent. What keeps it
# honest is that it says which line each fact came from — model/cited.txt —
# and that those lines are re-read on every run.
"$TLC" parse model || FAILED=1
"$TLC" cited model || FAILED=1

# --- step 2: what TLC says, against what this experiment claims ------------
"$TLC" check model || FAILED=1

# The two counterexamples the experiment is about, as paths, not just verdicts.
"$TLC" table model > states.out 2>&1
grep -q 'bc-before-NeverAnotherExperimentsNote .*exp190a -> exp157' states.out \
    && pass "before ecf659e, exp157 believes exp190's note — the bug a board found on 2026-08-30" \
    || fail "the historical bug is the counterexample" "$(grep bc-before-Never states.out)"
grep -q 'bc-tagged-AFreshFlashBelievesNothing .*exp190a -> exp190a' states.out \
    && pass "after it, a second flash of the same experiment still believes the first" \
    || fail "the residual is the counterexample" "$(grep bc-tagged-AFresh states.out)"

# --- step 3, on a host: the premises of the fix, in the real crate ---------
crate_test ../../crates/breadcrumb "breadcrumb's tests pass, R1's replay among them"
grep -q 'fn a_rebuild_reflashed_while_running_starts_fresh_only_if_the_reflash_withdrew_the_token' \
    ../../crates/breadcrumb/src/tests.rs \
    && pass "the replay of the counterexample is a test in the crate, not in this experiment" \
    || fail "R1 is replayed in crates/breadcrumb" "the bridge between model and code is missing"

# --- step 3 and 4, on a board: what run.sh recorded ------------------------
if grep -q '^-- flash 2 --' capture.txt 2>/dev/null; then
    second="$(sed -n '/^-- flash 2 --/,/^$/p' capture.txt | grep -m1 'boot ')"
    [[ "$second" == *"boot 1, last ended: Fresh"* ]] \
        && pass "on the board, the second flash of exp190 starts fresh: ${second#*] }" \
        || fail "the second flash of exp190 starts fresh" "it said: ${second:-nothing}"
else
    echo "SKIP  the board half: not captured yet (./run.sh with a board attached)"
fi

exit "$FAILED"
