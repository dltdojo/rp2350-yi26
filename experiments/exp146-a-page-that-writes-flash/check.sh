#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp146 quick check — non-interactive verdict.
#
# The page is in tools/pages/, because it is a tool a person uses repeatedly and
# not a page you read once. This checks it two ways without a browser: the
# command sequence has to match `yi26 pflash`'s, command for command, and the
# half of the page that is pure logic — parsing a .uf2 and refusing an unbootable
# one — is run against real fixtures under `node`.
#
# What no check here can reach: the USB half. A WebUSB page needs a person to
# pick the device from a native dialog, so the flash itself is verified by
# somebody holding a phone. See the README.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=2   # one WebUSB permission tap, and a person to watch the board come back
presence_check

USB_IFACE="vendor"
USB_CARRIES="control"
USB_HOST="webusb"
USB_RUNS_ON="bootrom"
usb_check

PAGE=../../tools/pages/pflash.html
REF=../../tools/yi26/src/picoboot.rs

if [[ -f "$PAGE" ]]; then
    pass "the page is in tools/pages/, where the maintained pages live"
else
    fail "tools/pages/pflash.html is here" "the page is missing"
    exit 1
fi

# ---- the sequence, against the reference implementation --------------------
#
# Every command the page sends must be one `yi26 pflash` sends, with the same
# opcode. A page that drifts from the tool is a page that works until the day
# somebody compares them on a board they cannot reach.
declare -A OPS=(
    [EXCLUSIVE_ACCESS]="0x1"
    [FLASH_ERASE]="0x3"
    [WRITE]="0x5"
    [EXIT_XIP]="0x6"
    [REBOOT2]="0xa"
    [READ]="0x84"
)
for name in "${!OPS[@]}"; do
    op="${OPS[$name]}"
    if grep -q "CMD_$name = $op;" "$PAGE" && grep -q "CMD_$name: u8 = $op;" "$REF"; then
        pass "CMD_$name = $op — the page and yi26 agree"
    else
        fail "CMD_$name = $op in both" "the page and tools/yi26/src/picoboot.rs disagree"
    fi
done

# The two values that each cost a hardware debugging round in exp141 and the
# pflash work, so they are guarded rather than remembered.
if grep -q '0x10000000' "$PAGE"; then
    pass "flash addresses are absolute from the XIP base (a zero dAddr STALLs)"
else
    fail "addresses are absolute" "PICOBOOT takes 0x10000000-based addresses, not offsets"
fi
if grep -q 'REBOOT2_NORMAL = 0x0' "$PAGE" && grep -q 'REBOOT2_NO_RETURN = 0x100' "$PAGE"; then
    pass "REBOOT2 uses NORMAL | NO_RETURN (the RP2040-style REBOOT lands in BOOTSEL)"
else
    fail "REBOOT2 flags" "type NORMAL 0x0 and NO_RETURN 0x100 — see tools/yi26/src/picoboot.rs"
fi

# ---- the promises the page makes to somebody with no way back --------------
if grep -q 'did not verify' "$PAGE" && grep -q 'readFlash(base, checkLen)' "$PAGE"; then
    pass "reads the write back and refuses to reboot if it does not match"
else
    fail "the write is verified before the reboot" "a WRITE that did not take must not become a reboot"
fi
if grep -q 'BLOCK_MARKER_START' "$PAGE" && grep -q 'BLOCK_MARKER_END' "$PAGE"; then
    pass "pre-flight: refuses a .uf2 with no boot block at flash offset 0"
else
    fail "pre-flight for a boot block" "a mis-linked image is a dark board PICOBOOT cannot reach"
fi
if grep -q 'FAMILY_RP2350_ARM_S' "$PAGE"; then
    pass "pre-flight: refuses a .uf2 built for another chip"
else
    fail "pre-flight for the family ID" "the bootrom ignores a wrong-family image silently"
fi

# ---- the logic half, run for real ------------------------------------------
EXTRACT="$(mktemp -d)"
trap 'rm -rf "$EXTRACT"' EXIT

sed -n '/^<script>$/,/^<\/script>$/p' "$PAGE" | sed '1d;$d' > "$EXTRACT/page.js"
if [[ -s "$EXTRACT/page.js" ]]; then
    pass "the page's script extracts ($(wc -l < "$EXTRACT/page.js") lines)"
else
    fail "the page's script extracts" "no <script> block found"
fi

if ! command -v node > /dev/null; then
    echo "SKIP  node is not installed, so the page's logic cannot be run here"
    echo "      — the static checks above still hold; install node to run it"
    exit "$FAILED"
fi

if node --check "$EXTRACT/page.js" 2>"$EXTRACT/syntax"; then
    pass "the page's script parses (node --check)"
else
    fail "the page's script parses" "$(head -3 "$EXTRACT/syntax")"
fi

# Three fixtures, and the page must sort them: a real firmware, an image
# addressed inside a partition (nothing at offset 0), and a file that is not a
# UF2 at all. The first two are built here; the third is this script.
FIX="$EXTRACT/fixtures"
mkdir -p "$FIX"
GOOD=../exp138-what-the-rom-already-knows/target/exp138.uf2
if [[ ! -f "$GOOD" ]]; then
    ( cd ../exp138-what-the-rom-already-knows \
      && cargo build --release --quiet \
      && elf2flash convert -b rp2350 \
           target/thumbv8m.main-none-eabihf/release/exp138-what-the-rom-already-knows \
           target/exp138.uf2 ) > /dev/null 2>&1
fi

if [[ -f "$GOOD" ]]; then
    # Shift every block's address up one sector: a perfectly valid image that
    # would leave flash offset 0 empty. exp139's dark board, in a file.
    python3 - "$GOOD" "$FIX/shifted.uf2" <<'PY'
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, 'rb').read())
for at in range(0, len(data) - 511, 512):
    if struct.unpack_from('<I', data, at)[0] == 0x0A324655:
        addr, = struct.unpack_from('<I', data, at + 12)
        struct.pack_into('<I', data, at + 12, addr + 0x1000)
open(dst, 'wb').write(data)
PY
    cat > "$EXTRACT/run.mjs" <<'EOF'
import fs from 'node:fs';
const el = () => ({ textContent: '', className: '', disabled: false, set onclick(v) {}, set onchange(v) {}, files: [] });
globalThis.document = { getElementById: el };
Object.defineProperty(globalThis, 'navigator', { value: { usb: {} }, configurable: true });
const src = fs.readFileSync(process.argv[2], 'utf8');
const page = new Function(src + '\n;return { uf2ToImage, preflight };')();
let bad = 0;
function verdict(label, path, wantOk) {
  let got, detail = '';
  try {
    const parsed = page.uf2ToImage(new Uint8Array(fs.readFileSync(path)));
    page.preflight(parsed);
    got = true;
    detail = `${parsed.image.length} bytes at 0x${parsed.base.toString(16)}`;
  } catch (e) {
    got = false;
    detail = e.message.replace(/\s+/g, ' ').slice(0, 70);
  }
  if (got === wantOk) console.log(`ok|${label}|${detail}`);
  else { console.log(`no|${label}|${detail}`); bad++; }
}
verdict('accepts a real firmware .uf2', process.argv[3], true);
verdict('refuses an image with nothing at flash offset 0', process.argv[4], false);
verdict('refuses a file that is not a UF2', process.argv[5], false);
process.exit(bad ? 1 : 0);
EOF
    if node "$EXTRACT/run.mjs" "$EXTRACT/page.js" "$GOOD" "$FIX/shifted.uf2" "$0" > "$EXTRACT/got" 2>"$EXTRACT/err"; then
        while IFS='|' read -r verdict label detail; do
            pass "$label ($detail)"
        done < "$EXTRACT/got"
    else
        while IFS='|' read -r verdict label detail; do
            [[ "$verdict" == ok ]] && pass "$label ($detail)" || fail "$label" "$detail"
        done < "$EXTRACT/got"
        [[ -s "$EXTRACT/err" ]] && echo "      $(head -2 "$EXTRACT/err")"
    fi
else
    echo "SKIP  no exp138 .uf2 to test the parser against — run exp138 first"
fi

echo "NOTE  the USB half cannot be checked here. A WebUSB page needs a person to"
echo "      pick the device from a native dialog, so the flash itself is verified"
echo "      by somebody holding a phone — which is the point of the page."

exit "$FAILED"
