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

exit "$FAILED"
