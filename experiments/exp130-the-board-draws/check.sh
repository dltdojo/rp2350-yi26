#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp130 quick check — non-interactive verdict.
# Builds, then if the board is running this experiment, confirms the volume is
# read-only, the page on it is the one in this directory, and the board still
# draws while the volume is mounted.
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

USB_IFACE="cdc+msc"
USB_CARRIES="log+commands+files"
USB_HOST="cdc_acm+usb-storage+webusb"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp130-the-board-draws
UF2=target/exp130-the-board-draws.uf2
MODEL="exp130 draw"

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
PAGE_BUILD="$(grep -oP "const PAGE_BUILD = '\K[^']+" draw.html)"
if [[ -n "$FW_BUILD" && "$FW_BUILD" == "$PAGE_BUILD" ]]; then
    pass "firmware and page agree on the build string ($FW_BUILD)"
else
    fail "firmware and page agree on the build string" "src/main.rs says '${FW_BUILD:-?}', draw.html says '${PAGE_BUILD:-?}' — bump both"
fi

# The volume is declared read-only, so the source has to actually set the bit
# and actually refuse the write. Deleting either half leaves a firmware that
# tells the host one thing and does another.
grep -q 'out\[2\] = 0x80;' src/main.rs \
    && pass "MODE SENSE sets the write-protect bit" \
    || fail "MODE SENSE sets the write-protect bit" "the host will write to the volume — exp126 got a LOST.DIR that way"
grep -q 'SENSE_DATA_PROTECT, ASC_WRITE_PROTECTED' src/main.rs \
    && pass "WRITE(10) is refused with DATA PROTECT / WRITE PROTECTED" \
    || fail "WRITE(10) is refused" "declaring read-only and accepting writes is a lie the host cannot catch"

# ---------------------------------------------------------------------------
# The JSON export, moved here from exp116's page.
#
# Two implementations of one format drift unless something compares them, and
# neither gets to be the authority: this page's parser and `yi26 log --json`
# are both run over one fixture and diffed against one committed expectation.
# exp116's check.sh does the identical thing to the identical block, which is
# what stops the two pages from disagreeing about what a log looks like.
FIXTURE=../../tools/yi26/tests/log-format/lines.txt
EXPECTED=../../tools/yi26/tests/log-format/expected.ndjson

grep -q "BEGIN yi26-log-json" draw.html && grep -q "END yi26-log-json" draw.html \
    && pass "the page carries the extractable log-format block" \
    || fail "the page carries the extractable log-format block" "the markers check.sh slices between are gone"

if ! command -v node > /dev/null; then
    echo "SKIP  node is not installed, so the page's script cannot be checked here"
elif [[ ! -f "$FIXTURE" || ! -f "$EXPECTED" ]]; then
    fail "the log-format fixture is present" "expected $FIXTURE and $EXPECTED"
else
    EXTRACT="$(mktemp -d)"
    trap 'rm -rf "$EXTRACT"' EXIT

    sed -n '/^<script>/,/^<\/script>/p' draw.html | sed '1d;$d' > "$EXTRACT/page.js"
    if node --check "$EXTRACT/page.js" 2>"$EXTRACT/syntax"; then
        pass "the page's script parses"
    else
        fail "the page's script parses" "$(head -3 "$EXTRACT/syntax" | tr '\n' ' ')"
    fi

    sed -n '/BEGIN yi26-log-json/,/END yi26-log-json/p' draw.html > "$EXTRACT/parser.js"
    {
        cat "$EXTRACT/parser.js"
        echo 'process.stdout.write(yi26Ndjson(require("fs").readFileSync(0, "utf8")));'
    } > "$EXTRACT/run.js"

    if node "$EXTRACT/run.js" < "$FIXTURE" > "$EXTRACT/got.ndjson" 2>"$EXTRACT/err"; then
        diff -q "$EXPECTED" "$EXTRACT/got.ndjson" > /dev/null \
            && pass "the page's parser agrees with yi26 byte for byte" \
            || fail "the page's parser agrees with yi26" "$(diff "$EXPECTED" "$EXTRACT/got.ndjson" | head -4 | tr '\n' ' ')"
    else
        fail "the page's parser runs" "$(head -2 "$EXTRACT/err" | tr '\n' ' ')"
    fi
fi

if ! exp_running 130; then
    echo "SKIP  board is not running exp130 — flash it with ./run.sh (not an error)"
    exit "$FAILED"
fi
pass "board is running exp130"

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

    # The page on the board is the file in this directory, byte for byte.
    # Two copies of a page drift; this says which one is authoritative.
    if cmp -s "$MP/INDEX.HTM" draw.html; then
        pass "INDEX.HTM on the board is byte-identical to draw.html ($(stat -c%s draw.html) bytes)"
    else
        fail "INDEX.HTM on the board is byte-identical to draw.html" "the board is running an older build"
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

# And the part that makes this a draw and not a disk: the CDC interface still
# works while the kernel holds the storage one. Two owners, one device.
yi26 log --seconds 2 > /dev/null 2>&1
LO=2100
HI=2567
OUT="$(yi26 send "$LO-$HI" --seconds 3 2>/dev/null)"
LINE="$(echo "$OUT" | grep -o 'draw #[0-9]*: [0-9]*  in [0-9]*-[0-9]*' | tail -1)"
if [[ -n "$LINE" ]]; then
    pass "the board still draws while the volume is mounted ($LINE)"
else
    fail "the board still draws while the volume is mounted" "no draw line came back"
fi

VALUE="$(echo "$LINE" | sed -n 's/.*: \([0-9]*\)  in.*/\1/p')"
if [[ -n "$VALUE" ]] && (( VALUE >= LO && VALUE <= HI )); then
    pass "the drawn number $VALUE is inside $LO-$HI"
else
    fail "the drawn number is inside $LO-$HI" "got: ${VALUE:-nothing}"
fi

echo "NOTE  the page itself is a human's job — the WebUSB picker is a native"
echo "      dialog behind a required user gesture. Everything above is what"
echo "      can be checked without one."

exit "$FAILED"
