#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp148 interactive walkthrough — bring up a CDC-NCM link, ask for an address,
# and watch the two halves of "networking works" arrive separately.
#
# The desktop half runs here. The phone half cannot: it is one person, one
# board, and one LED, and step 5 is where this script hands over.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
EXP="$(pwd)"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp148-a-wire-with-no-address
UF2=target/exp148.uf2

# The host's end of the link takes the MAC this firmware advertises, and udev
# names the interface after it. Keep these two in step with src/main.rs —
# check.sh fails if they drift.
HOST_MAC="022600000148"
IFACE="enx${HOST_MAC}"
BOARD_MAC="02:26:00:00:02:48"
CONN="yi26-exp148"

iface_now() {
    [[ -d "/sys/class/net/$IFACE" ]] && { echo "$IFACE"; return 0; }
    local d name
    for d in /sys/class/net/*; do
        name="$(basename "$d")"
        [[ "$name" == lo ]] && continue
        if readlink -f "$d/device" 2>/dev/null | grep -q usb \
           && [[ "$(cat "$d/type" 2>/dev/null)" == 1 ]]; then
            echo "$name"; return 0
        fi
    done
    return 1
}

lease_now() {
    local f ip
    for f in /var/lib/NetworkManager/dnsmasq-*.leases /var/lib/misc/dnsmasq.leases; do
        [[ -f "$f" ]] || continue
        ip="$(grep -i "$BOARD_MAC" "$f" 2>/dev/null | awk '{print $3}' | head -1)"
        [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    done
    ip="$(ip neigh show 2>/dev/null | grep -i "$BOARD_MAC" | awk '{print $1}' | head -1)"
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    return 1
}

echo "${BOLD}exp148 — a wire with no address${RESET}"
say ""
say "The first experiment on the network road, and it stops one step short of a"
say "network on purpose. A link and an address are two separate achievements,"
say "and this is where you find out that the second one is not yours to make."

# ---------------------------------------------------------------------------
step 1 "What is being built"
say ""
say "One firmware, four USB interfaces:"
say ""
say "  ${BOLD}CDC-ACM${RESET}   the log, and the 1200-baud reboot watcher — as always"
say "  ${BOLD}CDC-NCM${RESET}   a virtual Ethernet adapter, with ${DIM}embassy-net${RESET} on top of it"
say ""
say "It asks for an address by DHCP and reports how far it got, twice over: in"
say "the log for you, and on the LED for somebody holding a phone."
say ""
say "  ${BOLD}dark${RESET}   no host driver has claimed the NCM data interface"
say "  ${BOLD}slow${RESET}   link up, no address — asking, nobody answering"
say "  ${BOLD}fast${RESET}   address leased"

# ---------------------------------------------------------------------------
step 2 "Build it, and price the link"
say ""
run_cmd bash -c "cd '$EXP' && cargo build --release --quiet && elf2flash convert -b rp2350 '$ELF' '$UF2' >/dev/null 2>&1 && echo built"
say ""
say "  this firmware: ${BOLD}$(( $(stat -c%s "$UF2") / 2 )) bytes${RESET} of flash ${DIM}(a .uf2 block carries 256 of its 512)${RESET}"
say "  an A/B slot:   ${BOLD}65536 bytes${RESET} ${DIM}(16 sectors, from tools/partimg)${RESET}"
say ""
say "A whole TCP/IP stack roughly doubles a firmware of this size, and it still"
say "fits one of exp142's slots with room over. Worth knowing before assuming a"
say "network firmware puts the A/B road out of reach — it does not, at least yet."

# ---------------------------------------------------------------------------
step 3 "Flash it — over the partition table, and that is all it takes"
say ""
say "A board that came from exp147 has a ${BOLD}table in sector 0${RESET}, and this is an"
say "ordinary image that wants sector 0 for itself. No ${BOLD}yi26 nuke${RESET} is needed"
say "anyway: PICOBOOT erases every sector it is about to write, and sector 0 is"
say "the first of them. The table is gone by the time the image lands on it."
say ""
say "Which is worth pausing on. ${DIM}exp144${RESET} found that the ROM's own ${BOLD}drive${RESET} refuses a"
say "dropped .uf2 while a table exists. PICOBOOT is not the drive and does not"
say "consult the table at all — it writes where it is told."
confirm "Flash exp148 over whatever is there?" || { say ""; say "Nothing was flashed."; exit 0; }
run_cmd yi26 bootsel
run_cmd yi26 pflash "$UF2"
sleep 5
say ""
run_cmd yi26 log --seconds 6

# ---------------------------------------------------------------------------
step 4 "The host binds a driver — half of the answer, for free"
say ""
if iface="$(iface_now)"; then
    ok "the kernel bound ${BOLD}cdc_ncm${RESET} and made ${BOLD}$iface${RESET}"
    say ""
    run_cmd ip -brief link show "$iface"
    say ""
    say "That interface existing is the whole of the first achievement. The board"
    say "knows too — ${DIM}wait_connection()${RESET} returned, so the LED left dark and is"
    say "now blinking slowly. Nothing has an address yet."
else
    bad "no USB Ethernet interface appeared"
    say ""
    say "Expected ${BOLD}$IFACE${RESET}. Check ${DIM}lsmod | grep cdc_ncm${RESET} and ${DIM}dmesg | tail${RESET}."
    say "If the LED is dark, the board agrees with you: nothing claimed it."
    exit 1
fi

# ---------------------------------------------------------------------------
step 5 "The other half is not the board's to give"
say ""
say "The board is asking for an address and nobody is answering, because nothing"
say "on this machine is a DHCP server yet. Turning one on is a change to ${BOLD}your${RESET}"
say "network configuration, so it is shown rather than done:"
say ""
say "  ${DIM}nmcli connection add type ethernet ifname $iface con-name $CONN ipv4.method shared${RESET}"
say "  ${DIM}nmcli connection up $CONN${RESET}"
say ""
say "That makes NetworkManager run dnsmasq, put this host on 10.42.0.1, and hand"
say "the board an address on that subnet. To undo it afterwards:"
say ""
say "  ${DIM}nmcli connection delete $CONN${RESET}"
say ""
if confirm "Run those two commands now?"; then
    run_cmd nmcli connection add type ethernet ifname "$iface" con-name "$CONN" ipv4.method shared
    run_cmd nmcli connection up "$CONN"
    say ""
    say "  waiting for the lease — it takes a few seconds, not instants"
    for _ in $(seq 1 30); do
        sleep 1
        lease_now > /dev/null && break
    done
    if ip="$(lease_now)"; then
        ok "the board leased ${BOLD}$ip${RESET}"
    else
        bad "no lease found yet — the log below is the board's side of the story"
    fi
    say ""
    run_cmd yi26 log --seconds 8
    say ""
    say "The LED is blinking fast now. Both halves happened, in that order, and"
    say "the board could tell them apart the whole time."
    say ""
    say "  ${DIM}remember: nmcli connection delete $CONN${RESET}"
else
    say ""
    say "Left as it is. The LED is blinking slowly, which is the honest state of"
    say "a board that asked and was not answered — and it is exactly the state"
    say "the next step expects to find on a phone."
fi

# ---------------------------------------------------------------------------
step 6 "Now unplug it and put it in a phone"
say ""
say "Nothing in this script can do this part, and nothing in this repository can"
say "see the result. The firmware is already flashed; the phone needs no app, no"
say "browser and no permission dialog. Plug it in and read the LED:"
say ""
say "  ${BOLD}dark${RESET}   Android did not bind a driver — the network road stops here"
say "  ${BOLD}slow${RESET}   Android bound it, and neither end will hand out an address"
say "  ${BOLD}fast${RESET}   something on the phone is a DHCP server — unexpected, and good"
say ""
say "Slow is the predicted answer: Android runs a DHCP ${BOLD}client${RESET} on a USB Ethernet"
say "gadget, and so does this board. Two clients, no server, nobody moves."
say ""
say "Whichever it is, look at the phone's status bar as well and check whether"
say "Wi-Fi survived — a phone that treats this as its default network is the"
say "risk that decides whether exp151 can exist at all."
