#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp102 interactive walkthrough — installs the Rust cross-compilation
# toolchain for the RP2350, one piece at a time, explaining what each piece
# is for. Already-installed pieces are detected and skipped, so re-running
# is always safe. No board needed for this experiment; no sudo is used by
# the script (one step may ask YOU to run apt in another terminal).
#
#   ./run.sh
#
# Already set up? ./check.sh gives a one-screen verdict in seconds.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

TARGET=thumbv8m.main-none-eabihf

BOLD=$'\e[1m'; GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; RESET=$'\e[0m'

say()  { echo "  $1"; }
ok()   { echo "  ${GREEN}✔${RESET} $1"; }
bad()  { echo "  ${RED}✘${RESET} $1"; }
step() { echo; echo "${BOLD}== Step $1: $2${RESET}"; }

run_cmd() {
    echo "  ${DIM}\$ $*${RESET}"
    "$@" 2>&1 | sed 's/^/    /'
}

pause()     { read -r -p "  --> $1 Press Enter when done. " _ < /dev/tty; }
confirm()   {
    local answer
    read -r -p "  --> $1 [y/n] " answer < /dev/tty
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

die() {
    echo; bad "$1"
    say "Fix that and run ./run.sh again — completed steps will be skipped."
    exit 1
}

echo "${BOLD}exp102 — can this machine build RP2350 firmware?${RESET}"
say "Four pieces get installed: Rust itself, the Cortex-M33 target, a C"
say "linker, and the ELF→UF2 converter. Then one build proves they work."
say "No board is needed today."

# ---------------------------------------------------------------------------
step 1 "Rust itself (rustup)"

say "rustup is Rust's installer and version manager. It puts everything in"
say "your home directory — no sudo, and uninstalling is one command."
if command -v rustup > /dev/null; then
    ok "rustup already installed — skipping."
else
    say "The official installer is a shell script from rustup.rs:"
    say "  ${DIM}curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y${RESET}"
    confirm "Download and run it now?" || die "Rust is required from here on."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>&1 | tail -5 | sed 's/^/    /'
    # Make cargo/rustc visible to the rest of this script:
    source "$HOME/.cargo/env"
    ok "rustup installed. (New shells get it automatically; this script just sourced it.)"
fi
run_cmd rustc --version
say "That is the ${BOLD}stable${RESET} channel — everything in this repository builds on"
say "stable Rust. No nightly required."

# ---------------------------------------------------------------------------
step 2 "The cross-compilation target"

say "Your rustc runs on x86-64 but can emit code for other CPUs — it just"
say "needs the core library pre-built for the one you want. The RP2350's"
say "Cortex-M33 is called:"
say ""
say "    thumbv8m.main - none - eabihf"
say "    ${DIM}CPU: Thumb ISA,   |      '-- hard-float calling convention${RESET}"
say "    ${DIM}Armv8-M mainline  '-- OS: none. Bare metal. (This 'none' is why${RESET}"
say "    ${DIM}                      there is no println! there — more in exp103.)${RESET}"
if rustup target list --installed | grep -qx "$TARGET"; then
    ok "Target already installed — skipping."
else
    run_cmd rustup target add "$TARGET"
fi
ok "Target $TARGET ready."

# ---------------------------------------------------------------------------
step 3 "A C linker"

say "cargo occasionally needs the system C toolchain — in this repo, to"
say "compile host-side tools like the one in the next step."
if command -v cc > /dev/null; then
    ok "cc already present — skipping."
else
    say "This is the one thing this script cannot install for you (it needs"
    say "sudo, and this script never uses sudo). In ANOTHER terminal, run:"
    say ""
    say "    ${BOLD}sudo apt install build-essential${RESET}"
    say ""
    pause "Run that in another terminal."
    command -v cc > /dev/null || die "cc still missing."
    ok "cc found."
fi

# ---------------------------------------------------------------------------
step 4 "The ELF→UF2 converter (elf2flash)"

say "cargo produces an ELF file; the RP2350 boot drive eats UF2 files"
say "(exp101 showed you the drive). elf2flash converts between the two."
say "It is a normal Rust program, so cargo can install it — no sudo."
if command -v elf2flash > /dev/null; then
    ok "elf2flash already installed — skipping."
else
    say "This compiles from source and takes a few minutes. Coffee moment."
    confirm "Install elf2flash now?" || die "elf2flash is needed from exp103 on."
    run_cmd cargo install elf2flash --locked
fi
ok "elf2flash ready. (It gets used for real in exp103 — nothing to convert yet.)"

# ---------------------------------------------------------------------------
step 5 "The proof: cross-compile something"

say "smoke/ is a tiny no-dependency Rust library. If it compiles for the"
say "Cortex-M33, your toolchain works — that is the whole experiment:"
run_cmd bash -c "cd smoke && cargo build --target $TARGET"
ok "It compiles. Your machine speaks Cortex-M33."
say ""
say "Note what did NOT happen: no .uf2 file, nothing to flash, board not"
say "needed. A library has no entry point — turning code into a bootable"
say "firmware needs a few more pieces, and that is exactly exp103."

# ---------------------------------------------------------------------------
echo
echo "${GREEN}${BOLD}exp102 complete — this machine can build RP2350 firmware.${RESET}"
say ""
say "What you just proved:"
say "  1. Cross-compilation: your x86 machine now emits Arm Cortex-M33 code."
say "  2. The target triple's 'none' means bare metal — no OS, no std."
say "  3. Everything installed without sudo, into your home directory,"
say "     on stable Rust."
say ""
say "Quick re-verify anytime: ./check.sh"
say "Next: exp103 — write, build, and flash a real blink."
