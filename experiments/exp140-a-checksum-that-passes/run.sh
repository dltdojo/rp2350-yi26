#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp140 interactive walkthrough — forge a checksum on real firmware, and
# watch the same trick fail on a hash.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

CRATE=../../crates/image-integrity

echo "${BOLD}exp140 — a checksum that passes${RESET}"
say ""
say "The advice for over-the-air updates is: write the new firmware, then"
say "verify the CRC. This experiment takes that apart on real firmware, with"
say "no board involved at all."

# ---------------------------------------------------------------------------
step 1 "Two words that get used as one"
say ""
say "  ${BOLD}Reliability${RESET}   did the bytes arrive intact? A CRC is good at this."
say "  ${BOLD}Authenticity${RESET}  are they from who I think? A CRC says ${BOLD}nothing${RESET} about it."
say ""
say "A CRC check on an update treats the second as if it were the first. That"
say "holds until somebody hands you a file built to pass it."

# ---------------------------------------------------------------------------
step 2 "Forge one, on this repository's own output"
say ""
UF2="$(find ../.. -name '*.uf2' -path '*/target/*' 2>/dev/null | head -1)"
if [[ -z "$UF2" ]]; then
    say "No .uf2 lying around — building exp138's, which needs no board:"
    run_cmd bash -c "cd ../exp138-what-the-rom-already-knows && cargo build --release --quiet && elf2flash convert -b rp2350 target/thumbv8m.main-none-eabihf/release/exp138-what-the-rom-already-knows target/exp138.uf2"
    UF2="$(find ../.. -name '*.uf2' -path '*/target/*' 2>/dev/null | head -1)"
fi
say "Forging the CRC of ${DIM}$(basename "$UF2")${RESET} onto a different image:"
say ""
run_cmd bash -c "cd '$CRATE' && cargo run --quiet --example forge -- '$OLDPWD/$UF2'"
say ""
say "The evil image started with a different CRC and ends with ${BOLD}exactly the"
say "target's${RESET} — four bytes changed, same size, same structure. A loader"
say "that trusted the CRC would boot it."

# ---------------------------------------------------------------------------
step 3 "Why four bytes is always enough"
say ""
say "CRC32 is ${BOLD}linear${RESET}. Flipping an input bit flips a fixed set of output"
say "bits, every time. So 'which four bytes make the CRC equal X' is 32"
say "equations in 32 unknowns — a system you ${BOLD}solve${RESET}, not one you search."
say "Four bytes is 32 bits, exactly the CRC's width, so there is always a"
say "solution and it is instant."

# ---------------------------------------------------------------------------
step 4 "The same attack, against a hash"
say ""
say "The demo above ran the identical method against SHA-256, and the hashes"
say "stayed different. That is the whole point:"
say ""
say "  A hash is built so the output bits a flipped input bit changes ${BOLD}depend"
say "  on all the other input bits${RESET} — so there is no fixed matrix to solve."
say ""
say "A hash can still be matched, but only by ${BOLD}trying inputs until one fits${RESET}."
run_cmd bash -c "cd '$CRATE' && cargo test --quiet 2>&1 | tail -3"
say ""
say "The tests forge a CRC, fail to forge a hash the same way, and match a"
say "four-bit hash by search to show the cost. Scale four bits to 256 and the"
say "search stops finishing — that is the security argument, watched rather"
say "than asserted."

# ---------------------------------------------------------------------------
step 5 "What to take away"
say ""
say "  ${BOLD}1.${RESET} A CRC belongs on the wire, catching the damaged transfer."
say "  ${BOLD}2.${RESET} What decides whether to *run* an image is a hash you trust or a"
say "     signature you verify — not a checksum anyone can forge."
say "  ${BOLD}3.${RESET} 'Verify the CRC' is a reliability check in an authenticity"
say "     check's clothes, and you have now seen the forgery it waves through."
say ""
say "${DIM}./check.sh${RESET} asserts all of this, on any machine, with no board."
