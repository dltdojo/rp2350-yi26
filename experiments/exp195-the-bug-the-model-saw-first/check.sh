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

JAR="tools/tla2tools.jar"
if ! command -v java > /dev/null; then
    echo "SKIP  the model half: no java on this machine (TLC needs Java 11 or later)"
    exit "$FAILED"
fi
if [[ ! -f "$JAR" ]]; then
    fail "tla2tools.jar is fetched" "run ./setup.sh — it needs the network once"
    exit 1
fi
PINNED="$(grep -o 'TLA_SHA256="[0-9a-f]*"' setup.sh | cut -d'"' -f2)"
[[ "$(sha256sum "$JAR" | cut -d' ' -f1)" == "$PINNED" ]] \
    && pass "tla2tools.jar is the one setup.sh pins" \
    || fail "tla2tools.jar matches the pinned sha256" "re-run ./setup.sh"

# --- the models are well-formed TLA+ ---------------------------------------
for m in model/*.tla; do
    ( cd model && java -cp ../"$JAR" tla2sany.SANY "$(basename "$m")" ) 2>&1 \
        | grep -q 'Semantic processing of module' \
        && pass "$(basename "$m") parses" \
        || fail "$(basename "$m") parses" "java -cp $JAR tla2sany.SANY $m"
done

# --- the model cites the code it translates, and the citations still hold --
#
# A model is a second description of the program, which is the thing
# docs/what-belongs-to-an-experiment.md exists to prevent. What keeps it
# honest is that it says which line each fact came from — and that those lines
# are checked, so a crate that changes under the model turns this red instead
# of leaving a model that describes code which no longer exists.
ROOT=../..
while IFS='|' read -r where want; do
    file="${where%:*}"; line="${where##*:}"
    got="$(sed -n "${line}p" "$ROOT/$file" 2>/dev/null)"
    [[ "$got" == *"$want"* ]] \
        && pass "the model's citation $where is still: $want" \
        || fail "the model's citation $where still holds" "line $line of $file is now: ${got:-missing}"
done <<'CITED'
crates/lifeline/src/board.rs:44|breadcrumb::read(cfg.tag)
crates/lifeline/src/board.rs:71|breadcrumb::arm(cfg.boot_us)
crates/lifeline/src/board.rs:82|pub fn alive(cfg: Config)
crates/lifeline/src/board.rs:86|breadcrumb::feed(cfg.run_us)
crates/breadcrumb/src/lib.rs:141|pub const fn is_ours(s0: u32, tag: u8)
crates/breadcrumb/src/lib.rs:335|pub fn interpret(before: Scratch, forced: bool, tag: u8)
crates/usb-reboot/src/lib.rs:169|write_volatile(WATCHDOG_SCRATCH0, 0)
crates/usb-log/src/board.rs:115|admit(POLICY, QUEUE.is_full()
crates/usb-log/src/board.rs:124|Admission::Drop =>
crates/usb-log/src/board.rs:161|claim(POLICY, &DROPPED)
crates/usb-log/src/board.rs:222|QUEUE.try_send(line).is_err()
crates/usb-log/src/board.rs:223|refund(POLICY, &DROPPED, lost)
CITED

# --- step 2: what TLC says, against what this experiment claims ------------
./model.sh > states.out 2>&1 || fail "TLC ran on every configuration" "see ./model.sh"
while read -r module config want; do
    [[ -z "$module" || "$module" == \#* ]] && continue
    got="$(awk -v c="$config" '$2 == c { print $3 }' states.out)"
    [[ "$got" == "$want" ]] \
        && pass "$config: $want" \
        || fail "$config: $want" "TLC says ${got:-nothing}"
done < model/expected.txt

# The two counterexamples the experiment is about, as paths, not just verdicts.
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
