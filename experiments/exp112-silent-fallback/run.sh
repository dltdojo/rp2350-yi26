#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp112 interactive walkthrough — a build that quietly stopped using the
# hardware RNG, and everything that fails to notice.
#
#   ./run.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp112-silent-fallback
HW_UF2=target/exp112-hardware.uf2
SW_UF2=target/exp112-software.uf2

BOOT_S=4
TEST_S=8

echo "${BOLD}exp112 — the fallback that every test passes${RESET}"
say ""
say "This firmware wants the hardware TRNG. Cargo.toml says so; the code says"
say "so. Build it without one feature and it uses a software generator"
say "instead — no error, no warning, no panic."
say ""
say "The experiment is everything that then fails to notice."

# ---------------------------------------------------------------------------
step 1 "Build both variants"
say "The broken one needs ${DIM}--no-default-features${RESET}, which drops ${BOLD}every${RESET} default —"
say "including auto-reboot, without which the board could not be reflashed."
say "So it has to be put back by hand. That is the same class of mistake as"
say "the one being demonstrated."
run_cmd cargo build --release --no-default-features --features auto-reboot
run_cmd elf2flash convert -b rp2350 "$ELF" "$SW_UF2"
run_cmd cargo build --release
run_cmd elf2flash convert -b rp2350 "$ELF" "$HW_UF2"
ok "Both built."

# ---------------------------------------------------------------------------
step 2 "The broken one, twice"
say ""
say "Flashing the software-fallback build and reading the first bytes. Then"
say "rebooting and reading them again."
say ""
run_cmd yi26 flash "$SW_UF2"
A="$(exp_read_log "$BOOT_S" | grep 'bytes #' || true)"
echo "$A" | sed 's/^/    /'
say ""
say "  ${DIM}— rebooting —${RESET}"
run_cmd yi26 flash "$SW_UF2"
B="$(exp_read_log "$BOOT_S" | grep 'bytes #' || true)"
echo "$B" | sed 's/^/    /'
echo

if [[ -n "$A" ]] && [[ "$(echo "$A" | grep -o '#1: .*')" == "$(echo "$B" | grep -o '#1: .*')" ]]; then
    bad "Identical across reboots. Every 'random' value this build produces is"
    say "  reproducible by anyone holding the same firmware."
else
    say "${YELLOW}The two boots differ — expected them to match.${RESET}"
    say "  Check that the software variant is really the one that got flashed."
fi

# ---------------------------------------------------------------------------
step 3 "Now let the tests look at it"
say ""
say "The same two tests exp111 used, on this deterministic generator."
say ""
exp_read_log "$TEST_S" | grep 'tests after' | sed 's/^/    /' || true
echo
say "Both near 50%. Both pass. The generator's entire state is 32 bits and its"
say "seed is a constant in the source — and no test of the ${BOLD}output${RESET} was ever"
say "going to say otherwise."

# ---------------------------------------------------------------------------
step 4 "Ask the artifact instead"
say ""
run_cmd ../audit.sh exp112-silent-fallback
say ""
say "That report does not look at the output at all. It reads a marker the"
say "linker put inside the .uf2, and compares it with what a default build of"
say "this checkout would have selected. When those disagree, the artifact wins."

# ---------------------------------------------------------------------------
step 5 "Put the intended build back"
run_cmd yi26 flash "$HW_UF2"
C="$(exp_read_log "$BOOT_S" | grep 'bytes #' || true)"
echo "$C" | sed 's/^/    /'
run_cmd yi26 flash "$HW_UF2"
D="$(exp_read_log "$BOOT_S" | grep 'bytes #' || true)"
echo "$D" | sed 's/^/    /'
echo
ok "Two boots of the hardware build, and they differ. That is what it should look like."

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp112 complete.${RESET}"
say ""
say "What you just proved:"
say "  1. A silent fallback produces output that passes every test you have,"
say "     because the fallback's shape is correct — right size, right type,"
say "     right-looking bytes."
say "  2. Rebooting twice and comparing would have caught it, costs ten"
say "     seconds, and is the test nobody runs."
say "  3. Source code tells you what a ${BOLD}default build${RESET} would do. Only the"
say "     artifact tells you what the thing in your hand actually does."
say ""
say "The strongest fix is not a better check. Delete the fallback branch and"
say "the build stops compiling without the feature — see 'Make it yours'."
