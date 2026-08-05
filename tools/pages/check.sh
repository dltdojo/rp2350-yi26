#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tools/pages quick check — non-interactive verdict.
#
# These four pages are tools, not experiments: they work against every firmware
# in this repository. That claim is what this script defends. It needs no board
# and no browser.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../../experiments/lib.sh

PAGES=(inspect.html log.html bootsel.html console.html)

# ---------------------------------------------------------------------------
# Every page, on its own terms.

for p in "${PAGES[@]}"; do
    [[ -f "$p" ]] \
        || { fail "$p exists" "missing"; continue; }

    if grep -qE 'src="https?:|href="https?:|@import|fetch\(|importScripts' "$p"; then
        fail "$p is self-contained" "it references something outside itself"
    else
        pass "$p is self-contained ($(stat -c%s "$p") bytes, no network, no build step)"
    fi

    # The finding exp133 wrote down: an appliance may be picky, a general tool
    # may not. Chrome identifies a device by vendor, product *and* serial, and
    # every firmware here sets its serial to its own experiment number — so a
    # tool that filtered on one would work against exactly one experiment,
    # which is the opposite of being a tool.
    if grep -q 'serialNumber:' "$p"; then
        fail "$p does not filter by serial number" \
             "a general tool that pins a serial works against one firmware only"
    else
        pass "$p does not filter by serial number (it must match every firmware here)"
    fi
done

# Endpoint numbers are read from the descriptors, never remembered. exp121
# moves them by adding a keyboard, and a tool that remembered would break.
for p in log.html console.html; do
    grep -q "endpoints" "$p" && grep -q "interfaceClass" "$p" \
        && pass "$p discovers its endpoints from the descriptors" \
        || fail "$p discovers its endpoints from the descriptors" "a remembered endpoint breaks at exp121"
done

# 1200 baud is the reboot signal. Exactly one of these pages may send it.
grep -qE 'BAUD *= *1200|1200' bootsel.html \
    && pass "bootsel.html sends the 1200-baud reboot signal (that is its job)" \
    || fail "bootsel.html sends the 1200-baud reboot signal" "the touch is the whole page"

for p in log.html console.html; do
    if grep -qE 'BAUD *= *1200' "$p"; then
        fail "$p does not send the 1200-baud reboot signal" \
             "it would drop the board into its bootloader mid-conversation"
    else
        pass "$p does not send the 1200-baud reboot signal"
    fi
done

# ---------------------------------------------------------------------------
# The escape grammar, against the Rust one.
#
# console.html and `yi26 send` accept the same six escapes on purpose: an
# instruction written for one has to work in the other, or the two halves of
# this repository disagree about what `\x01` means. The fixtures below are the
# ones tools/yi26's own unit tests use, copied deliberately — if the Rust side
# changes, its tests and this list stop agreeing and somebody has to choose.

RUST=../yi26/src/main.rs

if command -v node > /dev/null; then
    JS="$(mktemp)"; FIX="$(mktemp)"
    trap 'rm -f "$JS" "$FIX"' EXIT

    sed -n '/--- unescape begin ---/,/--- unescape end ---/p' console.html > "$JS"
    if [[ ! -s "$JS" ]]; then
        fail "console.html's unescape can be extracted" "the marker comments are gone"
    else
        cat >> "$JS" <<'EOF'
const cases = [
  ["hello",           "68 65 6c 6c 6f"],
  ["",                ""],
  ["a\\nb",           "61 0a 62"],
  ["\\r\\t\\0",       "0d 09 00"],
  ["\\\\",            "5c"],
  ["\\x00\\xff\\x41", "00 ff 41"],
  ["é",          "c3 a9"],
];
const errors = ["\\q", "\\", "\\xZZ", "\\x4"];
let bad = [];
for (const [input, want] of cases) {
  const r = unescape(input);
  const got = r.error ? `ERROR ${r.error}`
    : Array.from(r.bytes).map((b) => b.toString(16).padStart(2, "0")).join(" ");
  if (got !== want) bad.push(`${JSON.stringify(input)}: want [${want}] got [${got}]`);
}
for (const input of errors) {
  const r = unescape(input);
  if (!r.error) bad.push(`${JSON.stringify(input)}: should have been refused`);
}
console.log(bad.length ? bad.join("; ") : "OK");
EOF
        RESULT="$(node "$JS" 2>&1)"
        if [[ "$RESULT" == "OK" ]]; then
            pass "console.html's escapes match yi26's, on yi26's own test fixtures"
        else
            fail "console.html's escapes match yi26's" "$RESULT"
        fi
    fi

    # And the *set* of accepted escapes, from both sources. A form added to one
    # side and not the other is the drift this whole arrangement is meant to
    # prevent, and it would pass the fixtures above unnoticed.
    JS_SET="$(sed -n '/--- unescape begin ---/,/--- unescape end ---/p' console.html \
        | grep -oE "case '(.|\\\\\\\\)':" | sed "s/case '//;s/'://" | sort -u | tr -d '\n')"
    RS_SET="$(sed -n '/fn unescape/,/^}/p' "$RUST" \
        | grep -oE "Some\('(.|\\\\\\\\)'\)" | sed "s/Some('//;s/')//" | sort -u | tr -d '\n')"
    if [[ -n "$JS_SET" && "$JS_SET" == "$RS_SET" ]]; then
        pass "both sides accept exactly the same escapes ($JS_SET)"
    else
        fail "both sides accept the same escapes" "page: [$JS_SET]  yi26: [$RS_SET]"
    fi
else
    echo "NOTE  node is not installed, so the escape parity test did not run."
    echo "      It is the only check here that needs anything beyond bash."
fi

# ---------------------------------------------------------------------------
# The experiments that built these pages keep their own copies, on purpose.
#
# An experiment that turns into a link loses the history somebody came for. So
# the copy stays where it was written and says, on the page itself, that it is
# not the maintained one. A reader who lands on the wrong file finds out from
# the file.

while IFS=: read -r frozen tool; do
    if [[ ! -f "$frozen" ]]; then
        fail "$(basename "$frozen") is still in its experiment" "gone — the history went with it"
    elif grep -q "$tool" "$frozen" && grep -qi "frozen" "$frozen"; then
        pass "$(basename "$frozen") says it is frozen and names $tool"
    else
        fail "$(basename "$frozen") says it is frozen and names $tool" \
             "a reader landing here has no way to know it is not the tool"
    fi
done <<EOF
../../experiments/exp115-webusb-enumerate/usb-inspector.html:tools/pages/inspect.html
../../experiments/exp116-webusb-cdc-log/cdc-log-viewer.html:tools/pages/log.html
../../experiments/exp117-webusb-reboot/reboot.html:tools/pages/bootsel.html
../../experiments/exp120-webusb-two-way/two-way.html:tools/pages/console.html
EOF

exit "$FAILED"
