#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp140 quick check — non-interactive verdict, no board at any point.
#
# The whole experiment is arithmetic: a CRC forged to a chosen value, and the
# same attack failing on a hash. crates/image-integrity proves it with
# cargo test; this adds a demonstration against a real artifact from this
# repository, so the claim is made about actual firmware and not a buffer.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=0   # no board is involved at any point — this is pure arithmetic
LIFELINE="no: no firmware of its own"
presence_check
lifeline_check

USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

CRATE=../../crates/image-integrity

if command -v cargo > /dev/null; then
    pass "toolchain present (cargo)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

# The primary evidence: the forge succeeds on a CRC and fails on a hash, both
# asserted, on any machine.
if (cd "$CRATE" && cargo test --quiet) > /dev/null 2>&1; then
    pass "the image-integrity crate's tests pass (forge a CRC, fail to forge a hash)"
else
    fail "the image-integrity crate's tests pass" "cd crates/image-integrity && cargo test"
fi

# The four-bytes claim is load-bearing: a forgery that changed the whole image
# would be a corruption, not a forgery. Assert the test that guards it exists.
grep -q 'changed <= 4' "$CRATE/src/lib.rs" \
    && pass "the forgery is bounded to four bytes (a check would notice more)" \
    || fail "the four-byte bound is tested" "only_the_four_bytes_moved is gone"

# The contrast has to stay a contrast: if the hash attack were ever made to
# 'succeed', the experiment would be teaching the opposite of its point.
grep -q 'assert_ne!(sha256' "$CRATE/src/lib.rs" \
    && pass "the same attack is asserted to FAIL against SHA-256" \
    || fail "the hash attack is asserted to fail" "the_same_attack_does_not_forge_a_hash changed"

# ---------------------------------------------------------------------------
# The demonstration against a real artifact. Any .uf2 this repository has built
# will do; exp138's is the smallest and needs no board to produce.

UF2="$(find ../.. -name '*.uf2' -path '*/target/*' 2>/dev/null | head -1)"
if [[ -z "$UF2" ]]; then
    # Build one, since this costs nothing and needs no hardware.
    (cd ../exp138-what-the-rom-already-knows && cargo build --release --quiet 2>/dev/null \
        && elf2flash convert -b rp2350 \
             target/thumbv8m.main-none-eabihf/release/exp138-what-the-rom-already-knows \
             target/exp138.uf2 > /dev/null 2>&1) || true
    UF2="$(find ../.. -name '*.uf2' -path '*/target/*' 2>/dev/null | head -1)"
fi

if [[ -z "$UF2" ]]; then
    echo "SKIP  no .uf2 artifact found or buildable — the crate tests are the verdict"
    exit "$FAILED"
fi

OUT="$(cd "$CRATE" && cargo run --quiet --example forge -- "$OLDPWD/$UF2" 2>/dev/null)"

echo "$OUT" | grep -q 'the CRC check PASSES' \
    && pass "a real .uf2 was forged to carry another image's CRC ($(basename "$UF2"))" \
    || fail "the forge demo ran on a real artifact" "$(echo "$OUT" | tail -1)"

# The good and evil CRCs must end equal, and the SHA lines must differ — the
# two halves of the point, read out of the demo's own output.
GOOD_CRC="$(echo "$OUT" | awk '/good CRC32/ {print $3}')"
FORGED_CRC="$(echo "$OUT" | awk '/after forging/ {print $3}')"
[[ -n "$GOOD_CRC" && "$GOOD_CRC" == "$FORGED_CRC" ]] \
    && pass "the forged CRC equals the target exactly ($GOOD_CRC)" \
    || fail "the forged CRC equals the target" "good=$GOOD_CRC forged=$FORGED_CRC"

echo "$OUT" | grep -q 'the hashes differ' \
    && pass "and the SHA-256 of the forgery does not match — the check that would have caught it" \
    || fail "the hashes differ" "the demo did not show the hash contrast"

exit "$FAILED"
