#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp155 quick check — non-interactive verdict.
#
# PRESENCE 1. The claim is "a page from somebody else's origin can change this
# board, and here is the one door where it cannot", and every part of that is
# machine-readable: the board reports the LED's state in `/status`, so the
# instrument is the board and the subject is the browser. Nobody has to watch a
# light.
#
# What that does NOT cover, stated so it is not mistaken for covered: that the
# pin drives a visible LED. exp103 and exp127 established that, and this script
# does not re-establish it.
#
# Needs, for the board half: a host sharing its connection (`nmcli … shared`).
# For the browser half: `google-chrome` and `python3`. Each half says so and
# skips rather than failing when it is not there.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1
presence_check

USB_IFACE="cdc+ncm+msc"
USB_CARRIES="log+frames+scsi+files"
USB_HOST="cdc_acm+cdc_ncm+usb-storage"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp155-who-else-can-knock
UF2=target/exp155.uf2
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
crate_test ../../crates/fat12 "crates/fat12 passes its own tests"

# ---- the drive, which is how anybody without a toolchain finds the page -----
#
# A page that controls the board is no use to somebody who cannot find the
# board. exp154 could do without this; a phone cannot, because the address
# otherwise lives only in the CDC log and reading that needs WebUSB.
if grep -q 'OPEN    HTM' "$SRC" && grep -q 'ADDRESS TXT' "$SRC"; then
    pass "the drive carries a link to tap and the address as plain text"
else
    fail "the drive carries a link and the address" "the whole point is not having to type it"
fi
if grep -qE 'fat12::File \{ name: b"[0-9-]+' "$SRC"; then
    fail "the address is not encoded in a filename" \
         "8.3 holds eight characters and an IPv4 address needs up to fifteen"
else
    pass "the address is in the contents, not squeezed into an 8.3 name"
fi
if [[ "$(grep -c 'let clusters = lay_down(disk' "$SRC")" == "1" ]]; then
    pass "the volume is laid down exactly once — there is no second version"
else
    fail "the volume is laid down once" "a second version is a cache question again"
fi
if grep -q 'filled its buffer exactly' "$SRC"; then
    pass "a page that fills its buffer says so — silence is what hid exp153's truncation"
else
    fail "truncation is detected, not silent" "a phone once showed a button labelled http://10"
fi
# The count the user caught: a mass-storage function is ONE interface with two
# endpoints. exp152 and exp153 said six in three places.
if grep -q 'five interfaces' Cargo.toml || grep -q '\*\*five\*\* interfaces' Cargo.toml; then
    pass "the interface count is stated as five, which is what lsusb says"
else
    fail "five interfaces, not six" "MSC is one interface with two endpoints"
fi

# ---- the one capability the parser grew, and its edges ---------------------
if grep -q 'pub fn headers' "$ROUTESRC"; then
    pass "the parser can find a named header — the whole of what exp154 was missing"
else
    fail "headers() exists" "without it nothing can tell one caller from another"
fi
# The expensive mistake, in the direction that matters: reading "no Origin" out
# of a block that had simply not arrived yet would let a cross-origin write
# through on a slow link — and only sometimes.
if grep -q 'fn a_header_block_that_has_not_finished_is_not_an_empty_header_block' "$ROUTESRC"; then
    pass "an unfinished header block is never read as an empty one"
else
    fail "an unfinished block is not an empty block" \
         "that bug lets a cross-origin write through, and only sometimes"
fi
if grep -q 'Headers::Complete(_) => break Some(Ok(r.line_len))' "$SRC"; then
    pass "the worker waits for the whole header block before deciding anything"
else
    fail "the worker waits for the headers" "a guard cannot read a header that has not arrived"
fi
if grep -q 'fn a_header_value_with_a_control_character_is_not_a_value' "$ROUTESRC"; then
    pass "a header value that could forge a log line is not a value"
else
    fail "control characters are refused in header values" "the Origin ends up in a log line"
fi

# ---- the open door is open, and that is the measurement --------------------
#
# Checked in the direction people do not expect: this must NOT consult a
# header. A later commit that "fixes" it would delete the finding.
if python3 - "$SRC" <<'EOF'
import sys
src = open(sys.argv[1]).read()
start = src.find("(Method::Get | Method::Post, Route::Led(lamp))")
end = src.find("(Method::Post, Route::Control(lamp))", start)
body = src[start:end]
if "h.get(" in body:
    print("the open door consults a header")
    sys.exit(1)
if "set_lamp(" not in body:
    print("the open door does not actually change anything")
    sys.exit(1)
EOF
then
    pass "/led/… changes the board and consults nothing — the thing being measured"
else
    fail "/led/… is the open door" "a guard here deletes the finding this experiment exists for"
fi

# ---- the guarded door needs both halves ------------------------------------
if grep -q 'if has_token && ours' "$SRC"; then
    pass "/control/led/… needs the header AND an origin that is this board's"
else
    fail "the guard is both conditions" "either one alone is not the boundary"
fi
if grep -q 'CONTROL_HEADER: &str = "X-Yi26-Control"' "$SRC"; then
    pass "the header's name is the mechanism — a non-simple header forces a preflight"
else
    fail "there is a control header" "without one, a cross-site form POST is not preflighted"
fi
# A preflight must never be the thing that changes the board.
if python3 - "$SRC" <<'EOF'
import sys
src = open(sys.argv[1]).read()
start = src.find("(Method::Options, Route::Control(_))")
end = src.find("(Method::Get, _)", start)
if "set_lamp(" in src[start:end]:
    print("the preflight changes the board")
    sys.exit(1)
EOF
then
    pass "the preflight answers and does nothing — asking is not acting"
else
    fail "OPTIONS changes nothing" "a preflight that acts is a door with the lock on the inside"
fi
# `null` is not the absence of an origin — it is what a sandboxed iframe and a
# file:// page send. Echoing it back grants exactly those callers.
if grep -q 'Cors::Allowed if !origin_seen.is_empty()' "$SRC"; then
    pass "a request with no Origin is answered with no Origin header, not with 'null'"
else
    fail "no ACAO when there was no Origin" "'null' is an origin, and it is the one to grant last"
fi
if grep -q 'Cors::Denied => {}' "$SRC"; then
    pass "a refusal sends no CORS header at all — a browser reads silence as no"
else
    fail "a denial sends nothing" "there is no header that says no; the absence of yes is how it is said"
fi

# ---- the instrument is handed over, and not before --------------------------
if grep -q 'let told = if network_state.1 { lamp_of(LAMP.load(Ordering::Relaxed)) } else { Lamp::Auto };' "$SRC"; then
    pass "the LED is only the caller's once there is an address"
else
    fail "the handover waits for an address" \
         "dark and slow are the only instrument there is until then — docs/debugging-on-a-phone.md"
fi
if grep -q 'indistinguishable from a network state' "$SRC"; then
    pass "...and the cost of handing it over is written down where it happens"
else
    fail "the cost is stated" "handing over an instrument silently is how a reader is misled"
fi

# ---- the reader's own footsteps ---------------------------------------------
#
# A state change is history; the same state again is the caller's own
# repetition. A page polling a control route must not fill a 64-line ring.
if grep -q 'log_transient!("led: {} again"' "$SRC"; then
    pass "asking for the state it is already in is transient, not retained"
else
    fail "a repeat is transient" "two retained lines every few seconds fill the ring in three minutes"
fi
noisy="$(grep -cE '^\s*log!\("http:' "$SRC" || true)"
[[ "$noisy" == "1" ]] \
    && pass "the only retained http: line is the one that should never happen" \
    || fail "the server's own lines are transient" "$noisy retained line(s)"

# ---- the pages ---------------------------------------------------------------
#
# exp151's rule holds for every page a person reads: no script, because these
# exist for browsers that have nothing else. `/probe` is the exception and it is
# not a page for a phone — it is the test instrument, and it says so.
pages="$(sed -n '/^fn render_index/,/^}/p;/^fn render(/,/^}/p' "$SRC")"
echo "$pages" | grep -q '<script' \
    && fail "no script in the pages a person reads" "they exist for browsers that lack everything else" \
    || pass "no script in the index or the log page"
if grep -q 'the only page in this repository with a script in it' "$SRC"; then
    pass "/probe is named as the exception, and as an instrument rather than a page"
else
    fail "/probe says what it is" "a scripted page in this repository has to justify itself"
fi

# ---- the board half ---------------------------------------------------------
PRODUCT="$(yi26 port --json 2>/dev/null | sed -n 's/.*"product":"\([^"]*\)".*/\1/p')"
if [[ "$PRODUCT" != *"exp155"* ]]; then
    echo "SKIP  no board running exp155 (enumerated as: ${PRODUCT:-nothing})"
    exit "$FAILED"
fi
echo "NOTE  enumerated as: $PRODUCT"
OUT="$(yi26 log --seconds 6 2>/dev/null || true)"
A="$(echo "$OUT" | grep -oE 'http://[0-9.]+' | tail -1)"
if [[ -z "$A" ]]; then
    echo "NOTE  no address yet. This host has to share its connection: see the README."
    exit "$FAILED"
fi
pass "the board has an address and says so — $A"

led_now() { curl -s --max-time 6 "$A/status" | sed -n 's/.*"led":"\([a-z]*\)".*/\1/p'; }

curl -s --max-time 6 "$A/led/auto" > /dev/null
# 1. the open door, by the simplest possible request
curl -s --max-time 6 "$A/led/fast" > /dev/null
[[ "$(led_now)" == "fast" ]] \
    && pass "GET /led/fast changed the board — no header, no permission, no question" \
    || fail "GET /led/fast changes the board" "got $(led_now)"
# 2. and by POST, which is no more of a boundary
curl -s --max-time 6 -X POST "$A/led/on" > /dev/null
[[ "$(led_now)" == "on" ]] \
    && pass "POST /led/on did the same — the method was never the boundary" \
    || fail "POST /led/on changes the board" "got $(led_now)"
# 3. the guarded door, from something that states no origin at all
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -X POST -H "X-Yi26-Control: 1" "$A/control/led/slow")"
[[ "$code" == "200" && "$(led_now)" == "slow" ]] \
    && pass "the guarded door opens for a request with the header and no stated origin" \
    || fail "the guarded door opens for curl" "HTTP $code, led $(led_now)"
# 4. ...and refuses a foreign one, with the header
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -X POST \
        -H "X-Yi26-Control: 1" -H "Origin: http://elsewhere.example" "$A/control/led/off")"
[[ "$code" == "403" && "$(led_now)" == "slow" ]] \
    && pass "a foreign Origin is refused even with the header — 403, and nothing moved" \
    || fail "a foreign Origin is refused" "HTTP $code, led $(led_now)"
# 5. ...and refuses its own origin without the header
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -X POST -H "Origin: $A" "$A/control/led/off")"
[[ "$code" == "403" && "$(led_now)" == "slow" ]] \
    && pass "the right origin without the header is refused too — both halves are needed" \
    || fail "the header is required" "HTTP $code, led $(led_now)"
# 6. the preflight, refused, and changing nothing
hdrs="$(curl -s -i --max-time 6 -X OPTIONS -H "Origin: http://elsewhere.example" "$A/control/led/on")"
if [[ "$hdrs" == *"403"* && "$hdrs" != *"Access-Control-Allow-Origin"* && "$(led_now)" == "slow" ]]; then
    pass "a preflight from elsewhere gets 403 and no Allow-Origin — and the LED did not move"
else
    fail "the preflight is refused" "led $(led_now); headers: $(echo "$hdrs" | head -1)"
fi
# 7. and is answered for its own
hdrs="$(curl -s -i --max-time 6 -X OPTIONS -H "Origin: $A" "$A/control/led/on")"
if [[ "$hdrs" == *"204"* && "$hdrs" == *"Access-Control-Allow-Origin: $A"* ]]; then
    pass "a preflight from this board's own origin is answered 204 with that one origin echoed"
else
    fail "the preflight is answered for our origin" "$(echo "$hdrs" | head -1)"
fi

# ---- the browser half -------------------------------------------------------
#
# The subject is a browser and the instrument is the board. `/probe` is copied
# byte for byte to a *different* origin and run there; what reached the board is
# then read from `/status`, which is the only witness that cannot be mistaken.
if ! command -v google-chrome > /dev/null || ! command -v python3 > /dev/null; then
    echo "NOTE  no google-chrome here — the browser half is the part that needs one."
    exit "$FAILED"
fi
TMP="$(mktemp -d)"
cleanup() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" 2> /dev/null
        wait "$SERVER_PID" 2> /dev/null
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
curl -s --max-time 6 "$A/probe" > "$TMP/index.html"
if [[ -s "$TMP/index.html" ]] && grep -q "const B='$A'" "$TMP/index.html"; then
    pass "/probe is served, and points at this board by absolute address"
else
    fail "/probe is served" "the browser half has nothing to run"
    exit "$FAILED"
fi
# `--directory` rather than a subshell that `cd`s, so that `$!` is the server
# itself and the trap can actually kill it. The subshell version left a python
# holding port 8155 after the directory beneath it had been deleted, and the
# next run got a 404 from a server that was serving nothing — which reads as
# the experiment failing when it is the harness leaking.
python3 -m http.server 8155 --directory "$TMP" > /dev/null 2>&1 &
SERVER_PID=$!
# Waited for rather than slept at. A fixed `sleep 1` failed once here, and the
# failure looked exactly like the finding not reproducing — which is the worst
# way for a test to be flaky, because it accuses the thing under test.
for _ in $(seq 20); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8155/)" == "200" ]] && break
    sleep 0.25
done
if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8155/)" != "200" ]]; then
    fail "the foreign origin is serving" "nothing to run the browser half against"
    exit "$FAILED"
fi

curl -s --max-time 6 "$A/led/auto" > /dev/null
before="$(curl -s --max-time 6 "$A/status")"
away_before="$(echo "$before" | sed -n 's/.*"turned_away":\([0-9]*\).*/\1/p')"
# Cumulative counters, so what matters is the difference across the run and not
# the value: the curl checks above have already opened the guarded door once.
ctrl_before="$(echo "$before" | sed -n 's/.*"control":\([0-9]*\).*/\1/p')"
timeout 40 google-chrome --headless=new --disable-gpu --no-sandbox --no-first-run \
    --user-data-dir="$TMP/profile" --virtual-time-budget=6000 \
    --dump-dom "http://127.0.0.1:8155/" > "$TMP/dom.html" 2>/dev/null
# The page knocks on its three doors 0, 600 and 1200 ms after it loads, and
# `--dump-dom` returns before the last of those has been answered — the DOM it
# prints says "starting…" and nothing else, while the requests are still in
# flight. So the board is polled rather than the page read: **what the page
# believes happened is not evidence, and what the board received is.**
for _ in $(seq 20); do
    [[ "$(led_now)" == "slow" ]] && break
    sleep 0.25
done
after="$(curl -s --max-time 6 "$A/status")"
away_after="$(echo "$after" | sed -n 's/.*"turned_away":\([0-9]*\).*/\1/p')"
ctrl_after="$(echo "$after" | sed -n 's/.*"control":\([0-9]*\).*/\1/p')"

# The finding, in the order it happens.
[[ "$(led_now)" == "slow" ]] \
    && pass "a page from http://127.0.0.1:8155 changed this board's LED — twice, by <img> and by form POST" \
    || fail "the foreign page reached the open door" "led is $(led_now), expected slow"
[[ "$away_after" -gt "$away_before" ]] \
    && pass "...and its fetch to the guarded door was turned away ($away_before → $away_after)" \
    || fail "the board refused the guarded request" "turned_away did not move"
[[ "$ctrl_after" == "$ctrl_before" ]] \
    && pass "the guarded door was never opened by a page that did not come from here" \
    || fail "the guarded door stayed shut" "control went $ctrl_before → $ctrl_after"

# And the same page, from the board's own origin, gets through.
curl -s --max-time 6 "$A/led/on" > /dev/null
timeout 40 google-chrome --headless=new --disable-gpu --no-sandbox --no-first-run \
    --user-data-dir="$TMP/profile2" --virtual-time-budget=6000 \
    --dump-dom "$A/probe" > "$TMP/dom2.html" 2>/dev/null
if [[ "$(led_now)" == "off" ]]; then
    pass "the identical page served from this board opened the guarded door — only the origin differed"
else
    fail "the same page from our own origin works" "led is $(led_now), expected off"
fi

curl -s --max-time 6 "$A/led/auto" > /dev/null

# ---- the drive, on this host ------------------------------------------------
#
# The check nobody had: **the address on the drive and the address the board
# answers at have to be the same one.** A drive laid down before the pinning
# settled, or after a second lease, would send a phone to a page that is not
# there — and a phone cannot be asked which address it was given.
if lsblk -no LABEL,MODEL 2>/dev/null | grep -q "YI26 BOARD.*exp155"; then
    pass "a 'YI26 BOARD' volume is present, and its SCSI model names exp155"
else
    echo "NOTE  no volume seen by lsblk — it appears only once the board has an address."
fi
MNT="$(lsblk -no LABEL,MOUNTPOINT 2>/dev/null | sed -n 's/^YI26 BOARD *//p' | head -1)"
if [[ -n "$MNT" && -f "$MNT/OPEN.HTM" ]]; then
    on_drive="$(grep -o 'href="http://[0-9.]*/"' "$MNT/OPEN.HTM" | grep -o 'http://[0-9.]*')"
    if [[ "$on_drive" == "$A" ]]; then
        pass "the address on the drive is the address the board answers at — $on_drive"
    else
        fail "the drive and the board agree on the address" "drive says $on_drive, board answers at $A"
    fi
    [[ -f "$MNT/ADDRESS.TXT" && -f "$MNT/README.TXT" ]] \
        && pass "ADDRESS.TXT and README.TXT are on it too — three files, no toolchain needed" \
        || fail "the drive carries all three files" "$(ls "$MNT")"
    # exp153's silent truncation, checked as a size rather than trusted.
    size="$(stat -c%s "$MNT/OPEN.HTM")"
    [[ "$size" -lt 1024 ]] \
        && pass "OPEN.HTM is $size bytes — short of its 1024-byte buffer, so it is whole" \
        || fail "OPEN.HTM is not truncated" "$size bytes against a 1024-byte buffer"
else
    echo "NOTE  the volume is not mounted here; mount it to check the address on it."
fi

echo "NOTE  the LED has been given back to the network reporter."
echo "NOTE  what this script cannot see: that the pin lights an LED. exp103 and"
echo "      exp127 established that, and this experiment does not re-establish it."

exit "$FAILED"
