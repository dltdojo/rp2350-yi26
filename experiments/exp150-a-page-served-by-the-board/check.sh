#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp150 quick check — non-interactive verdict.
#
# PRESENCE 3: the result of this experiment is whether a page appears in a
# browser on a phone, and nothing here can see a browser or a phone.
#
# Most of what follows is not "does it compile". It is the set of mistakes that
# would each cost a round trip to somebody holding the only board — a panic
# before USB is ready, a socket that resets instead of closing, a page that
# needs the internet to render. docs/debugging-on-a-phone.md is the argument
# for why those are worth a guard rather than a code review.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=3   # a browser on a phone is the instrument
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc+ncm"
USB_CARRIES="log+frames"
USB_HOST="cdc_acm+cdc_ncm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp150-a-page-served-by-the-board
SRC=src/main.rs
PLAIN=target/exp150.uf2
GW=target/exp150-gw.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# ---- both builds, because both are shipped ---------------------------------

build() { # features out.uf2
    cargo build --release --quiet ${1:+--features "$1"} 2>/dev/null \
        && elf2flash convert -b rp2350 "$ELF" "$2" > /dev/null 2>&1
}

CLIENT=target/exp150-client.uf2
if build "" "$PLAIN" && build announce-gateway "$GW" && build ask-for-an-address "$CLIENT"; then
    pass "all three builds compile (server, announce-gateway, client)"
else
    fail "all three builds compile" "cargo build --release [--features ...]"
    exit "$FAILED"
fi

# The client role is the one Android's Ethernet tethering requires: the phone is
# the DHCP server and the router, the board is a client on its network. Whatever
# the address turns out to be, the log has to print it — it is the only way
# anybody finds out where to point a browser.
if grep -q 'I am at http://' "$SRC"; then
    pass "the client role prints the address it was given — nothing else can tell you"
else
    fail "the client role prints its address" "an assigned address nobody can read is unreachable"
fi

# The two roles wait for opposite things, and a line naming the wrong one sends
# somebody looking in the wrong place.
if grep -q 'still asking for an address' "$SRC" && grep -q 'waiting for a DISCOVER' "$SRC"; then
    pass "each role says what it is actually waiting for"
else
    fail "each role says what it is waiting for" "the wrong line here costs a whole exchange"
fi

if cmp -s "$PLAIN" "$GW"; then
    fail "the two builds differ" "announce-gateway changed nothing — the experiment has one arm"
else
    pass "the two builds differ — the phone gets both in one round trip"
fi

if readelf -S "$ELF" 2>/dev/null | grep -qE '\.vector_table +PROGBITS +10000000'; then
    pass "linked at 0x10000000 — an ordinary image"
else
    fail "linked at 0x10000000" "a moved image is the exp139 dark-board bug"
fi

reboot_watcher_check "$SRC"

# Still under an A/B slot, and getting closer. exp148 had 25 KiB spare; a TCP
# stack and a server spend most of it. Reported rather than asserted at a
# threshold, because the number itself is the interesting part.
flash=$(( $(stat -c%s "$PLAIN") / 2 ))
if [[ "$flash" -le 65536 ]]; then
    pass "still fits an A/B slot ($flash of 65536, $(( 65536 - flash )) spare)"
else
    fail "fits an A/B slot" "$flash bytes — the network road has outgrown exp142's geometry"
fi

# ---- the mistakes that cost a round trip -----------------------------------

# A `StaticCell` inside a pooled task panics on the second worker's `init()`,
# and a panic here happens before USB is ready — which is the one failure this
# firmware cannot be recovered from without a hand on BOOTSEL. The buffers must
# come from `main`.
if ! sed -n '/async fn http_task/,/^}/p' "$SRC" | grep -q 'StaticCell'; then
    pass "the pooled task allocates nothing of its own — a second init() would panic"
else
    fail "the pooled task allocates nothing of its own" \
         "StaticCell::init() panics the second time, before USB is up"
fi

# smoltcp has no listen backlog: a SYN that finds no listening socket is
# refused, not queued. So the worker count IS the concurrent-connection limit,
# and a browser fetching a page and its favicon already needs two.
workers="$(grep -oP 'pool_size = \K[0-9]+' "$SRC")"
if [[ "${workers:-0}" -ge 4 ]]; then
    pass "$workers HTTP workers — measured: N workers serve exactly N at once"
else
    fail "at least four HTTP workers" \
         "with two, four simultaneous requests measured 200 000 000 200"
fi

# The bug a board found, and the reason this is a guard rather than a comment.
# A gracefully closed socket goes to TIME-WAIT and sits there ~10 s; it never
# reaches `Closed`. Waiting for `Closed` therefore always ran to its deadline
# and cost the worker two seconds of not listening — `curl` in a loop measured
# 200 200 000 000 000. `flush()` returns when the data and the FIN are
# acknowledged, which is the thing actually worth waiting for.
if grep -q 'socket.close()' "$SRC" && grep -q 'socket.flush()' "$SRC"; then
    pass "the close waits on flush() — the FIN, not TIME-WAIT"
else
    fail "the close waits on flush()" "waiting for State::Closed never finishes"
fi
# Comments are stripped first: the code must not wait on `State::Closed`, and
# the comment above it must be free to say why. A guard that cannot tell those
# apart fails on its own explanation, which this one did.
if grep -v '^[[:space:]]*//' "$SRC" | grep -q 'State::Closed'; then
    fail "nothing waits for State::Closed" \
         "a gracefully closed socket goes to TIME-WAIT and never reaches Closed"
else
    pass "nothing waits for State::Closed — it is a state this path never reaches"
fi

# ...and the wait is bounded, or a peer that vanishes holds a worker.
if grep -q 'with_timeout(CLOSE_TIMEOUT' "$SRC"; then
    pass "the wait for the close is bounded"
else
    fail "the wait for the close is bounded" "a silent peer would keep a worker forever"
fi

if grep -q 'set_timeout' "$SRC"; then
    pass "sockets have a timeout — browsers open connections and then say nothing"
else
    fail "sockets have a timeout" "a speculative connection would hold a worker forever"
fi

# ---- the page has to render with no network at all -------------------------
#
# It is served by a board on a USB cable to a phone whose browser may have no
# route anywhere else. Anything fetched from elsewhere is a blank rectangle.
page="$(sed -n '/fn render/,/^}/p' "$SRC")"
if ! echo "$page" | grep -qE 'https?://[a-z]' ; then
    pass "the page references nothing outside the board"
else
    fail "the page is self-contained" "an external URL will not load over a USB cable"
fi
if ! echo "$page" | grep -q '<script'; then
    pass "no script in the page — it renders in whatever browser is holding it"
else
    fail "no script in the page" "this page exists to work where WebUSB does not"
fi

# The count is the proof it is not a cache. Without it, a reload that shows the
# same page proves nothing, and "reload it" is the instruction a phone user gets.
if echo "$page" | grep -q 'served' && grep -q 'SERVED.fetch_add' "$SRC"; then
    pass "the page prints a request count — a reload is visibly a second request"
else
    fail "the page prints a request count" "otherwise a cached page and a served page look identical"
fi

# ---- the router option, which is the whole variable ------------------------

if grep -q 'cfg!(feature = "announce-gateway")' "$SRC" && grep -q 'router:' "$SRC"; then
    pass "the router option is what the feature switches, and nothing else is"
else
    fail "the feature switches the router option" "that is the one difference being measured"
fi

# Rebuilt on purpose: `build()` writes over the same ELF, so by now it holds
# whichever variant was compiled last. A guard that reads a shared artifact has
# to say which one it means.
cargo build --release --quiet --features announce-gateway 2>/dev/null
if strings "$ELF" 2>/dev/null | grep -q 'this build lies'; then
    pass "the gateway build says on its own page that it is lying"
else
    fail "the gateway build admits it" "a page that claims a gateway must say so"
fi
cargo build --release --quiet 2>/dev/null   # leave the default build in place

# ---- reach.html, and the one thing it can silently stop doing --------------

REACH=reach.html
if [[ -f "$REACH" ]]; then
    pass "reach.html is here — the page that reads the address so nobody types it"
else
    fail "reach.html is here" "typing an IP into a phone's address bar is the step that goes wrong"
fi

if command -v node > /dev/null; then
    EXTRACT="$(mktemp -d)"
    trap 'rm -rf "$EXTRACT"' EXIT
    sed -n '/^<script>$/,/^<\/script>$/p' "$REACH" | sed '1d;$d' > "$EXTRACT/reach.js"
    if node --check "$EXTRACT/reach.js" 2>"$EXTRACT/err"; then
        pass "reach.html's script parses (node --check)"
    else
        fail "reach.html's script parses" "$(head -2 "$EXTRACT/err")"
    fi

    # The drift that would break this page in silence. Its regex has to match
    # the line the firmware actually prints — and must NOT match the gateway
    # line, which also carries an IP address and comes right after it.
    #
    # Both strings are pulled from the two files rather than written here, so
    # this fails when either side moves and not when this script is stale.
    fw_line="$(grep -oP '"\{\} ms  I am at http://[^"]*' "$SRC" | head -1)"
    cat > "$EXTRACT/drift.mjs" <<EOF
import fs from 'node:fs';
const js = fs.readFileSync(process.argv[2], 'utf8');
const m = js.match(/const ADDRESS_LINE = (\/.*\/);/);
if (!m) { console.error('no ADDRESS_LINE in the page'); process.exit(1); }
const re = eval(m[1]);
const addr = '[   10551 ms] 10551 ms  I am at http://10.42.0.212/ — 0 request(s) served';
const gw   = '[   10551 ms]         gateway 10.42.0.1 — there is a way out of here';
const hit = addr.match(re);
if (!hit || hit[1] !== 'http://10.42.0.212') { console.error('the page cannot read the address line'); process.exit(1); }
if (gw.match(re)) { console.error('the page mistakes the gateway line for the address'); process.exit(1); }
EOF
    if node "$EXTRACT/drift.mjs" "$EXTRACT/reach.js" 2>"$EXTRACT/drift-err"; then
        pass "reach.html reads the address line the firmware prints, and not the gateway line"
    else
        fail "reach.html reads the firmware's address line" "$(head -1 "$EXTRACT/drift-err")"
    fi
    [[ -n "$fw_line" ]] \
        && pass "the firmware still prints that line ($(echo "$fw_line" | cut -c2-30)…)" \
        || fail "the firmware prints an address line" "reach.html has nothing to read"
else
    echo "SKIP  node is not installed, so reach.html's parser cannot be run here"
fi

# Three ways in, because they fail independently and a phone must not need a
# second attempt to find that out.
for pair in "fetch(:fetch" "iframe:an iframe" "location.href:a plain navigation"; do
    needle="${pair%%:*}"; label="${pair#*:}"
    grep -qF "$needle" "$REACH" \
        && pass "reach.html can try it with $label" \
        || fail "reach.html can try it with $label" "one blocked mechanism would cost a round trip"
done

# And the header without which `fetch` can never report anything but failure.
if grep -q 'Access-Control-Allow-Origin' "$SRC"; then
    pass "the board lets a foreign page read its response — that is what fetch() needs"
else
    fail "the board sends Access-Control-Allow-Origin" "without it fetch() cannot say what happened"
fi

# ---- the protocol, tested where it can be tested ---------------------------

crate_test ../../crates/dhcp "crates/dhcp passes its own tests (both router answers included)"

# ---- the board half, if one is here ----------------------------------------

PRODUCT="$(yi26 port --json 2>/dev/null | sed -n 's/.*"product":"\([^"]*\)".*/\1/p')"
if [[ "$PRODUCT" != *"exp150"* ]]; then
    echo "SKIP  no board running exp150 (enumerated as: ${PRODUCT:-nothing})"
    echo "NOTE  and the result of this experiment is not here anyway: it is whether"
    echo "      a page appears in a browser on a phone. Both .uf2 files are built."
    exit "$FAILED"
fi
echo "NOTE  enumerated as: $PRODUCT"

OUT="$(yi26 log --seconds 8 2>/dev/null || true)"
if echo "$OUT" | grep -q 'serving http://'; then
    pass "the board says it is serving"
else
    echo "SKIP  the boot lines have aged out — replug the board"
fi
if echo "$OUT" | grep -q 'http: served request'; then
    pass "a request has been answered — $(echo "$OUT" | grep -o 'served request #[0-9]*' | tail -1)"
else
    echo "NOTE  no request served yet. On this host: curl http://192.168.7.1/"
fi

exit "$FAILED"
