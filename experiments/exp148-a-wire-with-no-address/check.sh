#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp148 quick check — non-interactive verdict.
#
# PRESENCE 3, and for two reasons rather than one. The desktop half needs a
# person to turn on connection sharing, which is a change to their network
# configuration that no script here will make for them. The phone half needs a
# person to look at an LED, and nothing in this repository can see light.
#
# What this file can reach: that the firmware builds, that it declares both
# functions, that it *asks* for an address rather than assuming one, that it can
# tell the two states apart at all, and that the numbers the README quotes are
# still the numbers the compiler produces.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=3   # a person turns sharing on; a person reads the LED on the phone
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc+ncm"
USB_CARRIES="log+frames"
USB_HOST="cdc_acm+cdc_ncm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp148-a-wire-with-no-address
UF2=target/exp148.uf2
SRC=src/main.rs
RUN=run.sh
PARTIMG=../../tools/partimg/src/main.rs

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
    pass "linked at 0x10000000 — an ordinary image, no partition involved"
else
    fail "linked at 0x10000000" "a moved image is the exp139 dark-board bug"
fi

reboot_watcher_check "$SRC"

# ---- what the link cost, against the room the A/B road had ------------------
#
# The README says the link is affordable: a network stack roughly doubles the
# firmware and it still fits one of exp142's 64 KiB slots. That is a claim with
# an expiry date — exp150 adds TCP and an HTTP server to this same base — so it
# is measured here rather than believed.
#
# A .uf2 carries 256 payload bytes per 512-byte block, so the flash an image
# occupies is half its file size. This check was written comparing the file
# against the slot, which is the wrong number by a factor of two, and it said
# the image did not fit when it fits twice over.
a_first="$(grep -oP 'const A_FIRST: u32 = \K[0-9]+' "$PARTIMG")"
a_last="$(grep -oP 'const A_LAST: u32 = \K[0-9]+' "$PARTIMG")"
slot=$(( (a_last - a_first + 1) * 4096 ))
flash=$(( $(stat -c%s "$UF2") / 2 ))
if [[ "$flash" -le "$slot" ]]; then
    pass "the link did not cost the A/B option ($flash bytes of flash, slot is $slot)"
else
    fail "the image still fits an A/B slot" \
         "$flash bytes no longer fits in $slot — the README says a network image does"
fi

# ---- the properties that make this experiment mean what it says ------------

# Asking is the subject. A static address would make the board "have an address"
# on any host at all, including one where nothing is listening, and the
# difference between the two hosts is the entire finding.
if grep -q 'NetConfig::dhcpv4' "$SRC" && ! grep -qE 'ipv4_static|ConfigV4::Static' "$SRC"; then
    pass "the address is asked for, not assumed (DHCP client, no static config)"
else
    fail "the address is asked for" "a static address answers the question by fiat"
fi

# Two bits, read separately. Collapsing them into one is the mistake this
# experiment exists to undo: a board with a link and no address is not the same
# board as one nobody has plugged in.
if grep -q 'is_link_up()' "$SRC" && grep -q 'is_config_up()' "$SRC"; then
    pass "link and address are read as two separate states"
else
    fail "link and address are two states" "one boolean cannot express three outcomes"
fi

# Three LED states, and the ordering that makes them readable across a room.
if grep -q 'BLINK_LINK: Duration = Duration::from_millis(500)' "$SRC" \
   && grep -q 'BLINK_ADDRESS: Duration = Duration::from_millis(100)' "$SRC"; then
    pass "the LED reports three states, faster meaning further along"
else
    fail "the LED reports three states" "the LED is the only instrument on a phone"
fi

# YAGNI, enforced. exp148 opens no socket; the day it does, this line is where
# somebody notices that the experiment's scope moved.
if ! grep -qE '^\s*"tcp",' Cargo.toml && ! grep -q 'TcpSocket' "$SRC"; then
    pass "no TCP anywhere — a link and an address is the whole scope"
else
    fail "no TCP" "exp150 is where sockets belong; this one stops earlier"
fi

# Four interfaces is exactly embassy-usb's default ceiling, so the build fits
# with nothing to spare. Raising it is a decision; inheriting it is an accident
# waiting for the fifth function.
if grep -q 'max-interface-count-8' Cargo.toml; then
    pass "the interface ceiling is raised on purpose (four are declared)"
else
    fail "the interface ceiling is raised" "CDC-ACM and CDC-NCM are two interfaces each"
fi

# ---- the two halves of the same MAC ----------------------------------------
#
# udev names the host's interface after the MAC this firmware advertises, and
# run.sh looks for that name and greps the lease file for the board's. Three
# places, one pair of numbers.
host_mac="$(grep -oP 'const HOST_MAC: \[u8; 6\] = \[\K[^]]+' "$SRC" | tr -d ' ' | sed 's/0x//g' | tr -d ',')"
board_mac="$(grep -oP 'const OUR_MAC: \[u8; 6\] = \[\K[^]]+' "$SRC" | tr -d ' ' | sed 's/0x//g' | tr -d ',')"
board_colons="$(echo "$board_mac" | sed 's/../&:/g; s/:$//')"
if grep -q "HOST_MAC=\"$host_mac\"" "$RUN" && grep -q "BOARD_MAC=\"$board_colons\"" "$RUN"; then
    pass "run.sh looks for the interface and the lease this firmware actually uses"
else
    fail "run.sh and the firmware agree on both MACs" \
         "src says host=$host_mac board=$board_colons — run.sh greps for something else"
fi

# The locally-administered bit. Without it this firmware is claiming an address
# range that belongs to whoever bought that OUI.
if [[ "${host_mac:0:2}" == "02" && "${board_mac:0:2}" == "02" ]]; then
    pass "both MACs are locally administered (0x02) — no OUI is being borrowed"
else
    fail "both MACs are locally administered" "first byte must have bit 1 set"
fi

# ---- the board half, if one is here ----------------------------------------

PRODUCT="$(yi26 port --json 2>/dev/null | sed -n 's/.*"product":"\([^"]*\)".*/\1/p')"
if [[ "$PRODUCT" != *"exp148"* ]]; then
    echo "SKIP  no board running exp148 (enumerated as: ${PRODUCT:-nothing}) — ./run.sh flashes it"
    exit "$FAILED"
fi
echo "NOTE  enumerated as: $PRODUCT"

OUT="$(yi26 log --seconds 8 2>/dev/null || true)"

if echo "$OUT" | grep -q 'CDC-ACM for this log, CDC-NCM for the link'; then
    pass "the board is up and both functions are built"
else
    echo "SKIP  the boot lines have aged out — replug the board, or ./run.sh"
fi

# Exactly one of the three, and which one is the measurement. None of them is a
# failure: a dark link on a desk means nobody has bound cdc_ncm, and that is a
# result about the host.
if echo "$OUT" | grep -q 'link UP, address'; then
    pass "reported: link up and an address leased — $(echo "$OUT" | grep -o 'address [0-9./]*' | tail -1)"
elif echo "$OUT" | grep -q 'link UP, no address'; then
    echo "NOTE  reported: link up, no address — nothing here is a DHCP server"
    pass "the board distinguishes a link from a lease, and says which it has"
elif echo "$OUT" | grep -q 'link DOWN'; then
    echo "NOTE  reported: link down — no host driver has claimed the NCM interface"
    pass "the board distinguishes a link from a lease, and says which it has"
else
    fail "the board reports one of the three states" "no state line in eight seconds of log"
fi

echo "NOTE  what is left is the part no script can do: put this board in a phone"
echo "      and read the LED. Dark, slow or fast is the answer, and the answer"
echo "      decides whether exp149 onward can reach a phone at all."

exit "$FAILED"
