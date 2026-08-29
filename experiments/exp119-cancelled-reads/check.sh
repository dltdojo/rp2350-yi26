#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp119 quick check — non-interactive verdict.
# Builds, then if the board is running this experiment, floods it with
# numbered packets under an RTS storm and checks that nothing went missing.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # yi26 flood is the whole host half
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log+commands+control"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp119-cancelled-reads
UF2=target/exp119-cancelled-reads.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "compiles ($(stat -c%s "$ELF") byte ELF)"
else
    fail "compiles" "run: cargo build --release"
    exit 1
fi

if elf2flash convert -b rp2350 "$ELF" "$UF2" > /dev/null 2>&1 && [[ -f "$UF2" ]]; then
    pass "converts to UF2 ($(stat -c%s "$UF2") bytes)"
else
    fail "converts to UF2" "run: elf2flash convert -b rp2350 $ELF $UF2"
    exit 1
fi
FAMILY="$(od -An -tx4 -j28 -N4 "$UF2" | tr -d ' ')"
[[ "$FAMILY" == "e48bff59" ]] \
    && pass "UF2 family ID is e48bff59 (rp2350-arm-s)" \
    || fail "UF2 family ID is e48bff59 (rp2350-arm-s)" "got: $FAMILY"

if yi26 markers "$UF2" | grep -q 'yi26-cfg:auto-reboot=on'; then
    pass "auto-reboot is compiled in (the board can still be reflashed)"
else
    fail "auto-reboot is compiled in" "built with --no-default-features? this board will need BOOTSEL by hand"
fi

if ! exp_running 119; then
    echo "SKIP  board is not running exp119 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp119"

# ---------------------------------------------------------------------------
# The board half.

# Drain the log queue first — crates/usb-log holds sixteen lines and flushes
# them when DTR returns, and lines produced during that flush are dropped for
# want of room. exp118's check.sh learned this the same way.
yi26 log --seconds 2 > /dev/null 2>&1

PACKETS=5000
OUT="$(yi26 flood --packets "$PACKETS" --storm --seconds 4 2>/dev/null)"
LAST="$(echo "$OUT" | grep -o 'cancels [0-9]*' | tail -1 | grep -o '[0-9]*')"
GAPS="$(echo "$OUT" | grep -o 'gaps [0-9]*' | tail -1 | grep -o '[0-9]*')"
RX="$(echo "$OUT" | grep -o 'rx [0-9]*' | tail -1 | grep -o '[0-9]*')"

# The control variable, checked before the result. A run that cancelled
# nothing proves nothing, and reporting PASS for it would be reporting PASS
# for an experiment that did not happen.
if [[ -n "${LAST:-}" ]] && (( LAST > 0 )); then
    pass "reads were actually cancelled ($LAST of them) — the run tested something"
else
    fail "reads were actually cancelled" "cancels=${LAST:-none}; without cancellations the result below is meaningless"
fi

if [[ -n "${RX:-}" ]] && (( RX == PACKETS )); then
    pass "all $PACKETS packets arrived"
else
    fail "all $PACKETS packets arrived" "rx=${RX:-none}"
fi

if [[ -n "${GAPS:-}" ]] && (( GAPS == 0 )); then
    pass "no packet was lost to a cancelled read"
else
    fail "no packet was lost to a cancelled read" "gaps=${GAPS:-none} — this is the finding this experiment would have to retract"
fi

echo "$OUT" | grep -q 'nothing lost' \
    && pass "the firmware states the verdict itself" \
    || fail "the firmware states the verdict itself" "no '-> N reads cancelled, nothing lost' line"

# Reflashing has to still work. This firmware moved the 1200-baud watcher into
# a select loop that spends its time being cancelled, and if that ever stops
# reaching reboot_if_requested the board needs a hand on the BOOTSEL button.
if yi26 bootsel > /dev/null 2>&1 && in_bootsel; then
    pass "still reboots itself from inside the select loop"
    yi26 flash "$UF2" > /dev/null 2>&1 \
        && pass "and comes back" \
        || fail "and comes back" "the board is in BOOTSEL — run: yi26 flash $UF2"
else
    fail "still reboots itself from inside the select loop" "the 1200-baud touch did not land"
fi

exit "$FAILED"
