#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp149 quick check — non-interactive verdict.
#
# PRESENCE 3: the readout is an LED, and what a given host does with an offer is
# that host's business. Ubuntu takes it and this script can watch that happen; a
# phone takes it and shows nothing at all, which only a person can see.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=3   # the LED is the readout on the host that matters most
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc+ncm"
USB_CARRIES="log+frames"
USB_HOST="cdc_acm+cdc_ncm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp149-the-board-hands-out-the-address
UF2=target/exp149.uf2
SRC=src/main.rs

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

if cargo build --release --quiet 2>/dev/null && elf2flash convert -b rp2350 "$ELF" "$UF2" > /dev/null 2>&1; then
    pass "builds ($(stat -c%s "$UF2") byte .uf2)"
else
    fail "builds" "cargo build --release"
    exit "$FAILED"
fi

if readelf -S "$ELF" 2>/dev/null | grep -qE '\.vector_table +PROGBITS +10000000'; then
    pass "linked at 0x10000000 — an ordinary image"
else
    fail "linked at 0x10000000" "a moved image is the exp139 dark-board bug"
fi

reboot_watcher_check "$SRC"

# ---- the protocol, where it can actually be tested --------------------------

crate_test ../../crates/dhcp "crates/dhcp passes its own tests"

# ---- the decisions this experiment is made of ------------------------------

# exp148's board asked for an address, and refusing a static one was the point.
# Here the board is the thing being asked, and a server without a fixed address
# is not a server. The reversal is the experiment, so it is checked.
if grep -q 'NetConfig::ipv4_static' "$SRC" && ! grep -q 'NetConfig::dhcpv4' "$SRC"; then
    pass "the board has a static address — it is the server now, not a client"
else
    fail "the board has a static address" "a DHCP server cannot itself be asking"
fi

# The client does not own the offered address yet and will not answer an ARP for
# it. Broadcasting is what makes that a non-problem.
if grep -q '255, 255, 255, 255' "$SRC"; then
    pass "replies go to the broadcast address — the client has no address to ARP for"
else
    fail "replies are broadcast" "unicast needs an ARP entry for an address nobody owns yet"
fi

# A `dhcpv4` feature here would be the client, which is exactly what this
# experiment stopped being.
if grep -qE '^\s*"udp",' Cargo.toml && ! grep -qE '^\s*"dhcpv4",' Cargo.toml; then
    pass "embassy-net brings udp and not dhcpv4 — that feature is the client"
else
    fail "udp, not dhcpv4" "dhcpv4 is embassy-net's client and this board is the server"
fi

if ! grep -qE '^\s*"tcp",' Cargo.toml && ! grep -q 'TcpSocket' "$SRC"; then
    pass "no TCP — an address is not a service, and exp150 is where that changes"
else
    fail "no TCP" "sockets belong in exp150"
fi

# The TRNG constant this experiment paid to rediscover. exp109 measured that
# embassy-rp's default makes a 64-bit fill take up to 31 seconds on this board,
# and a boot that spends thirty seconds here looks exactly like a dead one.
if grep -q 'TRNG_SAMPLE_COUNT: u32 = 1000' "$SRC" && grep -q 'sample_count = TRNG_SAMPLE_COUNT' "$SRC"; then
    pass "the TRNG sample count is exp109's 1000, not embassy-rp's 25"
else
    fail "the TRNG sample count is exp109's" \
         "at the default this board took 0.38 s, then 31.4 s, then 14.5 s — see exp109"
fi

# And the rule that detour paid for: an `.await` leaves usb_task free to
# enumerate, so however long the wait, the board can still be reflashed.
if grep -q 'trng.fill_bytes(&mut seed).await' "$SRC" && ! grep -q 'blocking_fill_bytes' "$SRC"; then
    pass "the seed is read with .await — nothing blocks the executor before USB is up"
else
    fail "nothing blocks the executor before USB is up" \
         "a busy-wait here took this board off the USB bus with no software way back"
fi

if grep -q 'BLINK_LEASED' "$SRC" && grep -q 'LEASED' "$SRC"; then
    pass "the LED reports the client's progress, which is what is being measured"
else
    fail "the LED reports the client's progress" "a static address makes is_config_up() useless here"
fi

# ---- the board half, if one is here ----------------------------------------

PRODUCT="$(yi26 port --json 2>/dev/null | sed -n 's/.*"product":"\([^"]*\)".*/\1/p')"
if [[ "$PRODUCT" != *"exp149"* ]]; then
    echo "SKIP  no board running exp149 (enumerated as: ${PRODUCT:-nothing})"
    exit "$FAILED"
fi
echo "NOTE  enumerated as: $PRODUCT"

OUT="$(yi26 log --seconds 8 2>/dev/null || true)"
if echo "$OUT" | grep -q 'is leased out'; then
    pass "the board has handed the address out"
    host_ip="$(ip -brief addr show 2>/dev/null | grep -o '192\.168\.7\.2/24' | head -1)"
    if [[ -n "$host_ip" ]]; then
        pass "and this host took it — $host_ip"
    else
        echo "NOTE  this host does not have 192.168.7.2; another one may."
    fi
elif echo "$OUT" | grep -q 'waiting for a DISCOVER'; then
    echo "NOTE  link up, nobody has asked yet — the LED is blinking slowly"
else
    echo "SKIP  the state lines have aged out — replug the board, or ./run.sh"
fi

echo "NOTE  what is left is the part no script can do: put this board in a phone"
echo "      and read the LED. Fast means the phone took the address."

exit "$FAILED"
