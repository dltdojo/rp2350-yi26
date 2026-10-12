#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp233 quick check — everything that needs no board.
#
#   1. the page's checking (trial.html, between `BEGIN trial-check` and `END
#      trial-check`), under node, fed in 64-byte packets: its own search is
#      exp232's cure.py's, its SHA-256 of the protocol cure.py's, its model and
#      world cure.py's to every number on 3003 random words, its prediction
#      exp234's — the divisions answer_world proves and the rate they give,
#      12.715%; the same 40 patients from exp234's board agree too; 40 patients as
#      exp232's board sends them all agree, and the same lines without words
#      (exp232's first build) agree as far as they can be checked; joining
#      late, a changed count, a changed word, a cured patient sent as missed, a
#      wrong PLAN, a wrong SEARCH, a TRIAL count off, a control that met the
#      endpoint, a lost line and a wrong minstret — or one board's minstret
#      under the other's name — are each told apart. Wrong versions of the
#      page are caught;
#   2. the whole page in headless Chromium, against a stand-in for exp232's
#      USB device and exp234's: it claims the interfaces, raises DTR, fills the
#      trial, rate and search panels, draws the two lives of every treated patient the model
#      and the world part on, gives a verdict, and Copy works; with no WebUSB,
#      Demo plays and says it checks nothing. findCdc is log.html's, byte for
#      byte;
#   3. every log a board gave back — exp232's board/*.txt, exp234's, and this
#      experiment's, which a phone running this page copied — is checked by the
#      page's own block, and in the browser.
#
# What none of it reaches: a board sending them, and a phone drawing them for
# a person.
#
# Needs python3 and node; Playwright's Chromium for step 2. Under a minute.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
source ../../tools/pages/pagecheck.sh
require_supported_platform

PRESENCE=2
LIFELINE="no: no firmware of its own"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="webusb"
USB_RUNS_ON="exp232+"
usb_check

mkdir -p build
python3 fixtures.py build/fixtures > /dev/null
shopt -s nullglob
logs=(../exp232-the-cure-the-proof-predicts/board/*.txt ../exp234-the-rate-the-proof-predicts/board/*.txt board/*.txt)

if ! command -v node > /dev/null; then
    echo "SKIP  the page: node is not installed"
    exit "$FAILED"
fi
page_parses trial.html build
# One language on the page: round 1 on a phone found p1's English and Chinese
# side by side hard to read. WHY.zh-TW.md is where the Chinese lives.
if python3 -c "import re, sys; sys.exit(1 if re.search(r'[\u3000-\u9fff\uff00-\uffef]', open('trial.html', encoding='utf-8').read()) else 0)"; then
    pass "the page is in English only"
else
    fail "the page is in English only" "it has CJK text in it"
fi
page_findcdc trial.html
node page_test.mjs trial.html build/fixtures "${logs[@]}" || FAILED=1

page_mutant "the world has no resistance in it" 's/(born \&\& bit(mut, i))/(born \&\& 0)/' \
    trial.html node page_test.mjs @ build/fixtures
page_mutant "a dose kills resistant cells too" 's/if (mine !== null \&\& !bit(resistant, i) \&\& /if (mine !== null \&\& /' \
    trial.html node page_test.mjs @ build/fixtures
page_mutant "the tumour invades the cell below" 's/if (bit(t, i) || bit(t, i - 1)) t2/if (bit(t, i) || bit(t, i + 1)) t2/' \
    trial.html node page_test.mjs @ build/fixtures
page_mutant "the search keeps the most doses" 's/count(c) < count(answer)/count(c) > count(answer)/' \
    trial.html node page_test.mjs @ build/fixtures
page_mutant "SHA-256 pads with 0x81" 's/padded\[len\] = 0x80;/padded[len] = 0x81;/' \
    trial.html node page_test.mjs @ build/fixtures
page_mutant "M7's rate counts every tumour cell, not the ones just divided into" 's/n += count(next.t \& ~next.t1);/n += count(next.t);/' \
    trial.html node page_test.mjs @ build/fixtures
page_mutant "every board's minstret is taken for exp232's" 's/exp234: 4046 }/exp234: 3084 }/' \
    trial.html node page_test.mjs @ build/fixtures
page_mutant "a TRIAL line is never held to the patient before it" 's/if (d(k) !== want\[k\]) why.push/if (false) why.push/' \
    trial.html node page_test.mjs @ build/fixtures

if page_playwright; then
    node page_browser.mjs trial.html build/fixtures/good.txt "40 of 40 patients agree" 2 || FAILED=1
    node page_browser.mjs trial.html build/fixtures/t24.txt "1 wrong" 2 || FAILED=1
    node page_browser.mjs trial.html build/fixtures/exp234.txt "40 of 40 patients agree" 2 234 || FAILED=1
    for log in "${logs[@]}"; do
        n="$(grep -c '^PATIENT .* word=.* arm=treated .* model=cured world=\(missed\|relapsed\)' "$log")"
        all="$(grep -c '^PATIENT' "$log")"
        serial="$(grep -o -m1 '^exp23[24] ' "$log" | cut -c4-6)"
        node page_browser.mjs trial.html "$log" "$all of $all patients agree" "$n" "${serial:-232}" || FAILED=1
    done
    page_mutant "the page draws the patients the model and the world agree on" \
        's/e.replay.modelOutcome !== e.replay.worldOutcome/e.replay.modelOutcome === e.replay.worldOutcome/' trial.html \
        node page_browser.mjs @ build/fixtures/good.txt "40 of 40 patients agree" 2
else
    echo "SKIP  the page in a browser: Playwright is not installed"
fi

exit "$FAILED"
