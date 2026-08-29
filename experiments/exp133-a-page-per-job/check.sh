#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp131 quick check — non-interactive verdict.
# Builds, then if the board is running this experiment, confirms the volume is
# read-only, carries both pages byte-identically to the experiments that own
# them, and that the board still draws while the volume is mounted.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=2   # one browser tap; check.sh reaches everything except the page itself
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc+msc+vendor"
USB_CARRIES="log+commands+files"
USB_HOST="cdc_acm+usb-storage+libusb+webusb"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp133-a-page-per-job
UF2=target/exp133-a-page-per-job.uf2
MODEL="exp133 drawer"

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# `cd`, not `--manifest-path` — this directory's .cargo/config.toml
# cross-compiles, so the tests would be built for a Cortex-M and never run.
for c in draw fat12; do
    if (cd ../../crates/$c && cargo test --quiet) > /dev/null 2>&1; then
        pass "the $c crate's tests pass"
    else
        fail "the $c crate's tests pass" "cd crates/$c && cargo test"
    fi
done

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
    pass "auto-reboot is compiled in (a phone can reflash this without a button)"
else
    fail "auto-reboot is compiled in" "exp117's page needs the 1200-baud watcher to talk to"
fi

# ---------------------------------------------------------------------------
# The guard this experiment's provenance check depends on.
#
# The page compares its own build string against the one the firmware prints
# at boot, and warns when they differ — that is how somebody finds out they
# are looking at a stale copy saved on their phone rather than the page on the
# board. If the two constants here ever drift apart, that check fires against
# a page that IS the right one, which is worse than not having it: a guard
# that cries wolf gets ignored, and then the real case gets ignored too.
FW_BUILD="$(grep -oP 'const PAGE_BUILD: &str = "\K[^"]+' src/main.rs)"
PAGE_BUILD="$(grep -oP "const PAGE_BUILD = '\K[^']+" index.html)"
if [[ -n "$FW_BUILD" && "$FW_BUILD" == "$PAGE_BUILD" ]]; then
    pass "firmware and page agree on the build string ($FW_BUILD)"
else
    fail "firmware and page agree on the build string" "src/main.rs says '${FW_BUILD:-?}', index.html says '${PAGE_BUILD:-?}' — bump both"
fi

# This experiment writes no page of its own, and that is the whole point: it
# is about composition. Every file on the volume is embedded from the
# experiment that owns it, so no page can exist here in two versions.
# The appliance page is this experiment's own — it is the thing that changed.
# The two tools are not, and a copy of either here would be a second version
# waiting to drift.
COPIES=""
for f in reboot.html cdc-log-viewer.html bootsel.html log.html; do
    [[ -f "$f" ]] && COPIES="$COPIES $f"
done
if [[ -z "$COPIES" ]]; then
    pass "the two tools are embedded, not copied — only the appliance page is local"
else
    fail "the two tools are embedded, not copied" "found:$COPIES"
fi

# The point of the whole experiment, checked in the source: the appliance page
# carries no log code. If a log pane ever creeps back into it, the composability
# this experiment exists to demonstrate has quietly been given up.
if grep -qE "yi26Ndjson|id=\"log\"" index.html; then
    fail "the appliance page carries no log code" "a log pane or exporter is back in index.html — that is exp130's shape, not this one's"
else
    pass "the appliance page carries no log code at all"
fi

# The rule this experiment exists to establish. A firmware that serves a volume
# and can be rebooted by software must carry the page that does it. Without it,
# the phone that flashed this build has no way to flash the next one — and
# nobody finds that out until the moment they need it, which is the worst
# possible time to discover a missing file.
grep -q 'FLASH   HTM' src/main.rs \
    && pass "the volume carries FLASH.HTM — the way back is on the device" \
    || fail "the volume carries FLASH.HTM" "a phone flashing the next build would need a page from somewhere else"

# And the file that must NOT be here. A log viewer lived on this volume for a
# few hours and was removed: two pages both want the same CDC pair, an
# interface has exactly one owner, and the second one to open always failed.
# Its only effect was an error that reads like a fault. exp130's page carries
# the log now, so putting it back would restore the confusion and nothing else.
# LOG.HTM is back, and here it is correct: the appliance is on the vendor
# interface, so this one has CDC to itself. exp131 had to remove it for the
# opposite reason, and the difference between the two volumes is one interface.
grep -q 'LOG     HTM' src/main.rs \
    && pass "the volume carries LOG.HTM — and nothing else claims CDC" \
    || fail "the volume carries LOG.HTM" "the log is a separate tool again in this design"

# The volume is declared read-only, so the source has to actually set the bit
# and actually refuse the write. Deleting either half leaves a firmware that
# tells the host one thing and does another.
grep -q 'out\[2\] = 0x80;' src/main.rs \
    && pass "MODE SENSE sets the write-protect bit" \
    || fail "MODE SENSE sets the write-protect bit" "the host will write to the volume — exp126 got a LOST.DIR that way"
grep -q 'SENSE_DATA_PROTECT, ASC_WRITE_PROTECTED' src/main.rs \
    && pass "WRITE(10) is refused with DATA PROTECT / WRITE PROTECTED" \
    || fail "WRITE(10) is refused" "declaring read-only and accepting writes is a lie the host cannot catch"

if ! exp_running 133; then
    echo "SKIP  board is not running exp133 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp133"

# ---------------------------------------------------------------------------
# The board half.
DEV=""
for d in /sys/block/*/; do
    [[ -r "$d/device/model" ]] || continue
    M="$(cat "$d/device/model" 2>/dev/null)"
    [[ "${M%"${M##*[![:space:]]}"}" == "$MODEL" ]] && DEV="$(basename "$d")"
done

if [[ -n "$DEV" ]]; then
    pass "the host created a block device (/dev/$DEV)"
else
    fail "the host created a block device" "no block device with model '$MODEL'"
    exit "$FAILED"
fi

# The whole point of the write-protect bit: the host is told, and believes it.
RO="$(lsblk -no RO "/dev/$DEV" | head -1 | tr -d ' ')"
[[ "$RO" == "1" ]] \
    && pass "the host marked the device read-only, because MODE SENSE said so" \
    || fail "the host marked the device read-only" "lsblk RO=$RO"

MP="$(lsblk -no MOUNTPOINT "/dev/$DEV" | head -1)"
UNMOUNT=0
if [[ -z "$MP" ]]; then
    udisksctl mount -b "/dev/$DEV" > /dev/null 2>&1
    MP="$(lsblk -no MOUNTPOINT "/dev/$DEV" | head -1)"
    UNMOUNT=1
fi

if [[ -n "$MP" ]]; then
    pass "the volume mounts at $MP"

    # Every page on the volume against the file it was embedded from. One
    # comparison per file, because "the volume has two files" and "the volume
    # has the right two files" are different claims and only the second is
    # worth anything.
    BAD=""
    while IFS=: read -r name src; do
        cmp -s "$MP/$name" "$src" || BAD="$BAD $name"
    done <<EOF
INDEX.HTM:index.html
LOG.HTM:../../tools/pages/log.html
FLASH.HTM:../../tools/pages/bootsel.html
EOF
    if [[ -z "$BAD" ]]; then
        pass "all three pages on the board are byte-identical to their sources"
    else
        fail "all three pages are byte-identical to their sources" "differs:$BAD — reflash"
    fi

    [[ -f "$MP/README.TXT" ]] \
        && pass "README.TXT is there beside it" \
        || fail "README.TXT is there beside it" "not on the volume"

    # A write must fail. It fails at the host, not at the device — which is
    # the interesting part and is why this asserts the outcome rather than
    # looking for a refusal in the firmware log. See the README.
    if touch "$MP/PROBE.TXT" 2>/dev/null; then
        rm -f "$MP/PROBE.TXT"
        fail "a write to the volume fails" "it succeeded — the volume is not read-only"
    else
        pass "a write to the volume fails (the host refuses before the device is asked)"
    fi

    (( UNMOUNT )) && udisksctl unmount -b "/dev/$DEV" > /dev/null 2>&1
else
    fail "the volume mounts" "udisksctl could not mount /dev/$DEV"
fi

# And the part that makes this a draw and not a disk — three owners at once.
# The kernel holds mass storage, the kernel holds the serial port, and libusb
# holds the vendor interface, all while a real command travels over the third.
#
# Inheriting this block from exp131 is what caught the architecture moving:
# it sent the range over CDC and got told where commands had gone, because in
# this build they are not there any more.
yi26 log --seconds 2 > /dev/null 2>&1

LO=2100
HI=2567
REPLY="$(yi26 echo "$LO-$HI" 2>&1)"
LINE="$(echo "$REPLY" | grep -o 'draw #[0-9]*: [0-9]*  in [0-9]*-[0-9]*' | tail -1)"
if [[ -n "$LINE" ]]; then
    pass "the vendor interface drew while the volume was mounted ($LINE)"
else
    fail "the vendor interface drew while the volume was mounted" "$(echo "$REPLY" | tail -1)"
fi

VALUE="$(echo "$LINE" | sed -n 's/.*: \([0-9]*\)  in.*/\1/p')"
if [[ -n "$VALUE" ]] && (( VALUE >= LO && VALUE <= HI )); then
    pass "the drawn number $VALUE is inside $LO-$HI"
else
    fail "the drawn number is inside $LO-$HI" "got: ${VALUE:-nothing}"
fi

# The provenance query, which exists because splitting the channels took the
# boot log away from the page that needed it.
BUILD="$(yi26 echo '?' 2>&1 | grep -o 'page build [a-z0-9]*' | tail -1)"
if [[ "$BUILD" == "page build $FW_BUILD" ]]; then
    pass "the vendor channel answers ? with the build string ($BUILD)"
else
    fail "the vendor channel answers ? with the build string" "got: ${BUILD:-nothing}"
fi

# A range sent to the old channel is answered with directions, not silence.
# Somebody following exp130's instructions on this firmware needs telling.
STRAY="$(yi26 send "$LO-$HI" --seconds 3 2>/dev/null)"
echo "$STRAY" | grep -q 'commands moved to the' \
    && pass "a range sent to the log channel is redirected, not ignored" \
    || fail "a range sent to the log channel is redirected" "no 'commands moved' line"

echo "NOTE  the page itself is a human's job — the WebUSB picker is a native"
echo "      dialog behind a required user gesture. Everything above is what"
echo "      can be checked without one."

exit "$FAILED"
