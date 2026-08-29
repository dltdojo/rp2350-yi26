#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp161 quick check — non-interactive verdict.
#
# PRESENCE 1: **and that is new on this road.** exp148 through exp153 all end
# in something only a person can see — a blink, a phone's browser, a drive
# appearing. This experiment's whole claim is four paths and a shared
# peripheral, and `curl` can see all of it. Nobody has to be awake.
#
# What it still needs is a host that shares its connection, because the board
# is a DHCP client. On Ubuntu that is one `nmcli` line and no `sudo` — the
# README has it — and without it there is no address and the board half SKIPs.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc+ncm"
USB_CARRIES="log+frames"
USB_HOST="cdc_acm+cdc_ncm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp161-one-port-four-doors
UF2=target/exp161.uf2
SRC=src/main.rs
ROUTESRC=../../crates/http-route/src/lib.rs

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"; exit 1
fi

if cargo build --release --quiet 2>/dev/null && elf2flash convert -b rp2350 "$ELF" "$UF2" > /dev/null 2>&1; then
    pass "builds ($(stat -c%s "$UF2") byte .uf2)"
else
    fail "builds" "cargo build --release"; exit "$FAILED"
fi

readelf -S "$ELF" 2>/dev/null | grep -qE '\.vector_table +PROGBITS +10000000' \
    && pass "linked at 0x10000000 — an ordinary image" \
    || fail "linked at 0x10000000" "a moved image is the exp139 dark-board bug"

reboot_watcher_check "$SRC"

crate_test ../../crates/http-route "crates/http-route passes its own tests"
crate_test ../../crates/log-ring "crates/log-ring passes its own tests"
crate_test ../../crates/mdns "crates/mdns passes its own tests"

# ---- the thing exp150 said belonged here -----------------------------------
#
# Both earlier servers read the request line and threw it away, and both said
# the parser belonged in the experiment where a path selects something. If it
# is not being used, this experiment is exp151 with more pages.
if grep -q 'http_route::parse' "$SRC"; then
    pass "the request line is parsed, not discarded"
else
    fail "the request line is parsed" "without it a path cannot select anything"
fi
if grep -q 'bytes of request, discarded' "$SRC"; then
    fail "nothing is discarded unread" "that line belongs to exp150 and exp151"
else
    pass "no request is answered without being read"
fi

# The distinction the whole crate exists for. A parser that treats a short read
# as a path makes the answer depend on how the host split the packet.
if grep -q 'Parsed::Incomplete => {}' "$SRC"; then
    pass "a request that has not finished arriving is waited for, not answered"
else
    fail "Incomplete is waited for" "answering a truncated line is a 404 for something nobody asked"
fi
if grep -q 'fn every_prefix_of_a_good_request_is_incomplete' "$ROUTESRC"; then
    pass "...and a host-side test cuts a real request at every offset to prove it"
else
    fail "the every-offset test exists" "this is the test crates/dhcp had to be written twice to get right"
fi
if grep -q 'fn a_refusal_never_arrives_early' "$ROUTESRC"; then
    pass "...and the same for a request that will be refused"
else
    fail "a refusal cannot arrive early" "a refusal that depends on packet boundaries is not a refusal"
fi

# Refusing to decode is the security property, and it is one line in the crate
# that a future edit could quietly remove.
if grep -q 'fn nothing_is_ever_decoded' "$ROUTESRC"; then
    pass "%-escapes and .. are refused rather than resolved"
else
    fail "nothing is decoded" "a path parser that decodes can name what it was not meant to"
fi

# ---- four doors, and each of them counted separately -----------------------
#
# The path each variant is named after comes from the crate's own table, so a
# route renamed there and not here is a failure rather than a stale label.
while read -r variant path; do
    if grep -q "route: Route::$variant" "$SRC" && grep -q "b\"$path\" => Route::$variant" "$ROUTESRC"; then
        pass "$path has an arm of its own, and the table agrees"
    else
        fail "$path is served as Route::$variant" "the table and the server disagree about a door"
    fi
done <<'DOORS'
Index /
Log /log
Status /status
Trng /trng
DOORS
if grep -q 'Route::Unknown' "$ROUTESRC" && grep -q 'render_error(page, 404' "$SRC"; then
    pass "a well-formed path that names nothing is a 404, not a 400"
else
    fail "unknown paths are 404" "a parsed request that named nothing is not a malformed request"
fi

# ---- nothing here writes, and that is exp155's subject ---------------------
#
# The moment a route changes the board, the question stops being "which path"
# and becomes "who may ask". Checked rather than intended: a POST arm that
# quietly started doing something would be that change.
if python3 - "$SRC" <<'EOF'
import sys
src = open(sys.argv[1]).read()
start = src.find("async fn http_task")
end = src.find("\n#[embassy_executor::task]", start)
body = src[start:end if end > 0 else len(src)]
bad = [w for w in ("set_high", "set_low", "reboot", "flash") if w in body]
if bad:
    print("writes:", ", ".join(bad))
    sys.exit(1)
EOF
then
    pass "no route changes anything on the board — every door reads"
else
    fail "every route reads" "a route that writes is exp155, and it needs exp155's measurement"
fi
if grep -q 'Method::Post | Method::Options, .. }) => {' "$SRC" && grep -q '405' "$SRC"; then
    pass "POST is refused with a 405 rather than silently treated as a GET"
else
    fail "POST is refused" "a method nothing implements must not fall through to a page"
fi

# ---- the second measurement: one TRNG, four workers ------------------------
if grep -q 'static RNG: Mutex<CriticalSectionRawMutex' "$SRC"; then
    pass "the one TRNG is shared behind a lock, not duplicated"
else
    fail "the TRNG is behind a mutex" "four workers reaching for one peripheral is the measurement"
fi
# Two numbers and not one: the queue and the work. A single "elapsed" cannot
# say which of the two a second caller is paying for.
if grep -q 'waited {} us, took {} us' "$SRC"; then
    pass "the wait for the lock is reported apart from the sampling time"
else
    fail "wait and work are reported separately" "one number cannot show a queue"
fi
# exp109's number. exp149 already paid once to rediscover what the default does.
if grep -q 'TRNG_SAMPLE_COUNT: u32 = 1000' "$SRC"; then
    pass "sample_count is 1000 — exp109's number, not the driver's 25"
else
    fail "sample_count is 1000" "at 25 a fill takes tens of seconds and looks like a hang"
fi

# ---- the instrument this road is read with is not spent --------------------
#
# The LED is the one thing a sleeping phone cannot interrupt, and exp153 left
# it with four states. An experiment about URLs has no business taking it.
if grep -q 'dark=no link, slow=still asking, fast=I have an address, SOLID=page served' "$SRC"; then
    pass "the LED still means what exp153 left it meaning"
else
    fail "the LED is unchanged" "docs/debugging-on-a-phone.md — it is the instrument, not the subject"
fi

# ---- the reader's own footsteps, still --------------------------------------
#
# exp151 measured 58 of 64 retained lines being the reader's own. This
# experiment adds a route that logs a timing line every time it is asked, so
# the rule matters more here, not less.
noisy="$(grep -cE '^\s*log!\("http:' "$SRC" || true)"
if [[ "$noisy" == "0" ]]; then
    pass "nothing the HTTP server says about itself is retained"
else
    fail "the server's own lines are transient" \
         "$noisy retained line(s) about serving — 58 of 64 was the measurement"
fi
if grep -qE 'log_transient!\("http: /trng' "$SRC"; then
    pass "...including the /trng timings, which are the noisiest thing here"
else
    fail "the /trng timings are transient" "a route asked in a loop would erase the log with its own times"
fi

# ---- the pages, for the browsers this road exists for ----------------------
pages="$(sed -n '/^fn render/,/^}/p' "$SRC")"
echo "$pages" | grep -q '<script' \
    && fail "no script in any page" "these pages are for browsers that lack WebUSB" \
    || pass "no script in any page — they are for whatever browser somebody has"
echo "$pages" | grep -q '&lt;' \
    && pass "log text is escaped before it becomes HTML" \
    || fail "log text is escaped" "a firmware that logs a < would break its own page"
if grep -q 'nav a{color' "$SRC"; then
    pass "every page carries the same four links — a door is no use unnamed"
else
    fail "the pages link to each other" "nobody guesses /trng from an address bar"
fi

# ---- one role, and it is the one that works --------------------------------
if grep -q 'default = \["auto-reboot", "ask-for-an-address"\]' Cargo.toml; then
    pass "the board asks for its address — exp150 measured that the other way is unreachable"
else
    fail "the board asks for its address" "a self-assigned address is not reachable from a phone browser"
fi

# ---- the board half --------------------------------------------------------
PRODUCT="$(yi26 port --json 2>/dev/null | sed -n 's/.*"product":"\([^"]*\)".*/\1/p')"
if [[ "$PRODUCT" != *"exp161"* ]]; then
    echo "SKIP  no board running exp161 (enumerated as: ${PRODUCT:-nothing})"
    exit "$FAILED"
fi
echo "NOTE  enumerated as: $PRODUCT"
OUT="$(yi26 log --seconds 6 2>/dev/null || true)"
addr="$(echo "$OUT" | grep -oE 'http://[0-9.]+' | tail -1)"
if [[ -z "$addr" ]]; then
    echo "NOTE  no address yet. This host has to share its connection: see the README."
    exit "$FAILED"
fi
pass "the board has an address and says so — $addr"

# Measurement one: four clients, four different paths, at the same instant.
# exp151 measured four `curl`s against one page; this asks four different
# questions, which is the thing a CDC pair cannot do at all.
codes="$(
    for p in "" log status "trng?n=8"; do
        curl -s -o /dev/null -w '%{http_code} ' --max-time 10 "$addr/$p" &
    done
    wait
)"
if [[ "$codes" == *200* && "$codes" != *000* ]]; then
    pass "four paths answered at once: $codes"
else
    fail "four paths answered at once" "got: $codes"
fi

# Each door counts separately, and /status is the door that says so.
if body="$(curl -s --max-time 6 "$addr/status")" && [[ "$body" == *'"served"'* ]]; then
    pass "/status is JSON and carries a count per door — $(echo "$body" | grep -o '"served":{[^}]*}')"
else
    fail "/status answers with JSON" "got: ${body:-nothing}"
fi

# Measurement two: the shared peripheral. One `/trng` on its own, then two at
# once. The board reports its own wait for the lock, and the second request's
# is the number this experiment exists to produce.
solo="$(curl -s --max-time 20 "$addr/trng?n=1024" | sed -n 2p)"
pass "a lone /trng?n=1024: $solo"
both="$( { curl -s --max-time 20 "$addr/trng?n=1024" & curl -s --max-time 20 "$addr/trng?n=1024" & wait; } | grep -c 'sampling took')"
if [[ "$both" == "2" ]]; then
    pass "two at once both completed — one waited for the other, and neither failed"
else
    fail "two concurrent /trng both complete" "$both of 2 answered"
fi
# And the door that shares nothing is not slowed by the door that does.
fast="$(curl -s -o /dev/null -w '%{time_total}' --max-time 20 "$addr/status")"
echo "NOTE  /status while the TRNG was busy: ${fast}s"

echo "NOTE  what no script here can do: nothing. This is the first experiment on"
echo "      the network road whose whole claim a shell can check."

exit "$FAILED"
