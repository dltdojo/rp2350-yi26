#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp147 quick check — non-interactive verdict.
#
# PRESENCE 3, and honestly so: the result of this experiment is the rate an LED
# blinks at, and nothing in this repository can see that. Everything below is
# the machinery underneath it — the pair builds, the two halves differ in the
# one word the ROM compares, the page's constants agree with the tool that
# places the images, and the page's own parser finds the right versions in the
# real bytes.
#
# What no check here can reach: a person, a phone, and an LED.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
EXP="$(pwd)"

source ../lib.sh
require_supported_platform

PRESENCE=3   # the LED is the readout; check.sh reaches everything except that
LIFELINE="no: verified before exp190, and the fix goes forward rather than back"
presence_check
lifeline_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp147-two-firmwares-one-phone
PAGE=ab.html
PARTIMG=../../tools/partimg/src/main.rs
REF=../../tools/yi26/src/picoboot.rs

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# ---- the two firmwares -----------------------------------------------------

build_one() { # slot major blink out.uf2
    EXP147_SLOT="$1" EXP147_MAJOR="$2" EXP147_MINOR=0 EXP147_BLINK_MS="$3" \
        cargo build --release --quiet 2>/dev/null \
        && elf2flash convert -b rp2350 "$ELF" "$4" > /dev/null 2>&1
}

if build_one A 1 100 target/fastA.uf2 && build_one B 2 1000 target/slowB.uf2; then
    pass "both halves build ($(stat -c%s target/fastA.uf2) and $(stat -c%s target/slowB.uf2) byte .uf2)"
else
    fail "both halves build" "EXP147_SLOT / EXP147_MAJOR / EXP147_BLINK_MS are the inputs"
fi

if readelf -S "$ELF" 2>/dev/null | grep -qE '\.vector_table +PROGBITS +10000000'; then
    pass "linked at 0x10000000 — an ordinary image, placed by partimg"
else
    fail "linked at 0x10000000" "a moved image is the exp139 dark-board bug"
fi

# The blink rate has to be a build input, not a constant. If it stops being one
# the two halves are indistinguishable and the experiment has no readout.
if grep -q 'EXP147_BLINK_MS' build.rs && grep -q 'BLINK_MS' src/main.rs; then
    pass "the blink rate is a build input — that is the whole readout"
else
    fail "the blink rate is a build input" "without it both halves look the same"
fi

if grep -q 'ITEM_1BS_VERSION' src/main.rs && grep -q 'imagedef-none' Cargo.toml; then
    pass "each half carries its own versioned IMAGE_DEF (exp142's recipe)"
else
    fail "each half carries a versioned IMAGE_DEF" "needs imagedef-none and a VERSION item"
fi

# ---- the page against the tools it has to agree with -----------------------

a_first="$(grep -oP 'const A_FIRST: u32 = \K[0-9]+' "$PARTIMG")"
b_first="$(grep -oP 'const B_FIRST: u32 = \K[0-9]+' "$PARTIMG")"
if grep -q "const A_FIRST_SECTOR = ${a_first};" "$PAGE" \
   && grep -q "const B_FIRST_SECTOR = ${b_first};" "$PAGE"; then
    pass "the page targets the sectors partimg actually uses ($a_first and $b_first)"
else
    fail "the page's sectors match partimg" \
         "partimg says $a_first/$b_first — a page that guesses writes to the wrong place in silence"
fi

for pair in "CMD_FLASH_ERASE 0x3" "CMD_WRITE 0x5" "CMD_READ 0x84" "CMD_REBOOT2 0xa"; do
    set -- $pair
    if grep -q "$1 = $2;" "$PAGE" && grep -q "$1: u8 = $2;" "$REF"; then
        pass "$1 = $2 — the page and yi26 agree"
    else
        fail "$1 = $2 in both" "the page and tools/yi26/src/picoboot.rs disagree"
    fi
done

if grep -q 'REBOOT2_FLASH_UPDATE = 0x4' "$PAGE"; then
    pass "the other-half button uses reboot type FLASH_UPDATE (0x4)"
else
    fail "the other-half button uses FLASH_UPDATE" "that is the difference between the two buttons"
fi

# Measured on a phone, 2026-08-05: a flash update boot of an image with NO TBYB
# flag is a completed update, and the ROM erased the other half's first sector.
# The page called that button "try once" and promised it wrote nothing. It must
# not say that again.
if grep -q 'COMMITS' "$PAGE" && grep -q 'erases the other half' "$PAGE" \
   && ! grep -q 'writes nothing at all' "$PAGE"; then
    pass "the page says the other-half boot commits and erases, because it does"
else
    fail "the page does not promise a free trial" \
         "a flash update boot of a non-TBYB image erased slot B — see the README"
fi

# The bug this check exists because of: the page read 256 bytes and looked for a
# block that starts at +0x114, so it found nothing on a correctly installed
# board — while this file's fixture was a whole sector and passed. A test whose
# input is bigger than the code's input is not testing the code.
# EVERY call site, not one of them. The first fix changed the read in
# readBoth() and left the verify in switchTo() reading 256 bytes, so the write
# succeeded and the verification said it had failed — which is the one thing a
# verification must never do.
short_reads="$(grep -c 'readFlash([^)]*, *[0-9]' "$PAGE" || true)"
if [[ "$short_reads" == "0" ]]; then
    pass "every flash read asks for a whole sector — the block loop starts at +0x114"
else
    fail "every flash read asks for a whole sector" \
         "$short_reads call(s) pass a literal length; a short read cannot see the block"
fi

if grep -q 'did not verify' "$PAGE"; then
    pass "the rewritten sector is read back before the board is rebooted"
else
    fail "the rewrite is verified" "a sector that did not take must not become a reboot"
fi

# ---- the page's parser, against bytes the real toolchain produced ----------

EXTRACT="$(mktemp -d)"
trap 'rm -rf "$EXTRACT"' EXIT

sed -n '/^<script>$/,/^<\/script>$/p' "$PAGE" | sed '1d;$d' > "$EXTRACT/page.js"
if [[ -s "$EXTRACT/page.js" ]]; then
    pass "the page's script extracts ($(wc -l < "$EXTRACT/page.js") lines)"
else
    fail "the page's script extracts" "no <script> block found"
    exit "$FAILED"
fi

if ! command -v node > /dev/null; then
    echo "SKIP  node is not installed, so the page's parser cannot be run here"
    exit "$FAILED"
fi

if node --check "$EXTRACT/page.js" 2>"$EXTRACT/syntax"; then
    pass "the page's script parses (node --check)"
else
    fail "the page's script parses" "$(head -3 "$EXTRACT/syntax")"
fi

# Assemble the real pair, then cut out of it exactly the bytes the page would
# read off a board: one sector at each half's start.
if (cd ../../tools/partimg && cargo run --quiet -- ab \
      "$EXP/target/fastA.uf2" "$EXP/target/slowB.uf2" "$EXP/target/exp147-ab.uf2") > /dev/null 2>&1; then
    pass "assembled the pair ($(stat -c%s target/exp147-ab.uf2) bytes)"
else
    fail "assembled the pair" "cd tools/partimg && cargo run -- ab"
fi

python3 - "$EXP/target/exp147-ab.uf2" "$EXTRACT" "$a_first" "$b_first" <<'PY'
import struct, sys
uf2, out, a_first, b_first = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
data = open(uf2, 'rb').read()
flash = {}
for at in range(0, len(data) - 511, 512):
    if struct.unpack_from('<I', data, at)[0] != 0x0A324655:
        continue
    addr, = struct.unpack_from('<I', data, at + 12)
    ln, = struct.unpack_from('<I', data, at + 16)
    for i, b in enumerate(data[at + 32:at + 32 + min(ln, 476)]):
        flash[addr + i] = b
for name, sec in (('a', a_first), ('b', b_first)):
    base = 0x10000000 + sec * 4096
    open(f'{out}/{name}.bin', 'wb').write(
        bytes(flash.get(base + i, 0xFF) for i in range(4096)))
PY

cat > "$EXTRACT/run.mjs" <<'EOF'
import fs from 'node:fs';
const el = () => ({ textContent: '', className: '', disabled: false, classList: { toggle() {} },
                    querySelector: () => ({ textContent: '' }), set onclick(v) {} });
globalThis.document = { getElementById: el };
Object.defineProperty(globalThis, 'navigator', { value: { usb: {} }, configurable: true });
const page = new Function(fs.readFileSync(process.argv[2], 'utf8') +
  '\n;return { findVersion };')();
let bad = 0;
function verdict(label, path, wantMajor) {
  const found = page.findVersion(new Uint8Array(fs.readFileSync(path)));
  if (!found) { console.log(`no|${label}|no VERSION item found`); bad++; return; }
  const major = (found.value >>> 16) & 0xffff;
  if (major === wantMajor) console.log(`ok|${label}|v${major}.${found.value & 0xffff} at +${found.at}`);
  else { console.log(`no|${label}|found v${major}, expected v${wantMajor}`); bad++; }
}
verdict('reads slot A’s version out of the real flash bytes', process.argv[3], 1);
verdict('reads slot B’s version out of the real flash bytes', process.argv[4], 2);
process.exit(bad ? 1 : 0);
EOF

if node "$EXTRACT/run.mjs" "$EXTRACT/page.js" "$EXTRACT/a.bin" "$EXTRACT/b.bin" > "$EXTRACT/got" 2>"$EXTRACT/err"; then
    while IFS='|' read -r v label detail; do pass "$label ($detail)"; done < "$EXTRACT/got"
else
    while IFS='|' read -r v label detail; do
        [[ "$v" == ok ]] && pass "$label ($detail)" || fail "$label" "$detail"
    done < "$EXTRACT/got"
    [[ -s "$EXTRACT/err" ]] && echo "      $(head -2 "$EXTRACT/err")"
fi

echo "NOTE  what is left is the part no script can do: put the pair on a board,"
echo "      look at the LED, press a button on the page, and look again. The"
echo "      readout of this experiment is a rate of blinking."

exit "$FAILED"
