#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp102 quick check — non-interactive verdict, no prompts, no installs.
# Answers one question: can this machine cross-compile RP2350 firmware?
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed
#
# Setting up for the first time? Run ./run.sh instead — it installs what
# is missing and explains each piece.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=0   # no board is involved at any point
presence_check

USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

TARGET=thumbv8m.main-none-eabihf

# 1. rustup + rustc
if command -v rustup > /dev/null; then
    pass "rustup installed"
else
    fail "rustup installed" "./run.sh installs it (or see https://rustup.rs)"
fi
if command -v rustc > /dev/null; then
    pass "rustc available ($(rustc --version))"
else
    fail "rustc available" "open a new shell after installing rustup, or: source ~/.cargo/env"
fi

# 2. Cross-compilation target
if rustup target list --installed 2>/dev/null | grep -qx "$TARGET"; then
    pass "target $TARGET installed"
else
    fail "target $TARGET installed" "rustup target add $TARGET"
fi

# 3. C linker (cargo needs it to build host tools like elf2flash)
if command -v cc > /dev/null; then
    pass "C linker (cc) present"
else
    fail "C linker (cc) present" "sudo apt install build-essential"
fi

# 4. ELF→UF2 converter (used from exp103 on)
if command -v elf2flash > /dev/null; then
    pass "elf2flash installed"
else
    fail "elf2flash installed" "cargo install elf2flash"
fi

# 5. The proof: cross-compile the smoke crate
if (cd smoke && cargo build --target "$TARGET" --quiet 2>/dev/null); then
    pass "smoke crate cross-compiles for $TARGET"
else
    fail "smoke crate cross-compiles for $TARGET" "run: cd smoke && cargo build --target $TARGET"
fi

exit "$FAILED"
