# SPDX-License-Identifier: Apache-2.0
#
# experiments/lib.sh — helpers shared by every experiment's run.sh and
# check.sh. One copy, sourced everywhere, so the scripts cannot drift apart.
#
# Usage (first lines of every script):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/../lib.sh"
#   require_supported_platform
#
# This file is meant to be sourced, not executed:
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "lib.sh is sourced by an experiment's run.sh/check.sh, not run directly." >&2
    exit 64
fi

BOLD=$'\e[1m'; GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; DIM=$'\e[2m'; RESET=$'\e[0m'

# ---------- interactive helpers (run.sh) -----------------------------------

say()  { echo "  $1"; }
ok()   { echo "  ${GREEN}✔${RESET} $1"; }
bad()  { echo "  ${RED}✘${RESET} $1"; }
step() { echo; echo "${BOLD}== Step $1: $2${RESET}"; }

# Show the command being run, then run it — so the user learns the command,
# not just the script name.
run_cmd() {
    echo "  ${DIM}\$ $*${RESET}"
    "$@" 2>&1 | sed 's/^/    /'
}

pause()   { read -r -p "  --> $1 Press Enter when done. " _ < /dev/tty; }
confirm() {
    local answer
    read -r -p "  --> $1 [y/n] " answer < /dev/tty
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

die() {
    echo; bad "$1"
    say "Fix that and run ./run.sh again — re-running is always safe."
    exit 1
}

# ---------- verdict helpers (check.sh) -------------------------------------

FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1${2:+ — $2}"; FAILED=1; }

# ---------- platform guard --------------------------------------------------

# Everything in this repository is written and tested on Ubuntu Linux. Rather
# than half-working elsewhere and failing confusingly halfway through, every
# script states that up front — and points at the honest alternative: this
# repo is small, open, and self-explaining, which makes it ideal input for an
# AI-assisted port to your own platform.
require_supported_platform() {
    [[ "${RP2350_ANY_PLATFORM:-}" == "1" ]] && return 0

    local os supported=0 name
    os="$(uname -s)"
    if [[ "$os" == "Linux" && -r /etc/os-release ]]; then
        if ( . /etc/os-release; [[ " ${ID:-} ${ID_LIKE:-} " == *ubuntu* || " ${ID:-} ${ID_LIKE:-} " == *debian* ]] ); then
            supported=1
        fi
        name="$( ( . /etc/os-release; echo "${PRETTY_NAME:-$os}" ) )"
    else
        name="$os"
    fi

    if [[ "$supported" -ne 1 ]]; then
        echo "${YELLOW}${BOLD}Unsupported platform.${RESET}"
        echo
        echo "  These scripts are written and tested on Ubuntu Linux."
        echo "  This system reports: ${BOLD}${name}${RESET}"
        echo
        echo "  The supported path on another platform is not to guess — it is to"
        echo "  port. This repository is small, open source, and every command in"
        echo "  it is explained. Hand this experiment's run.sh, check.sh, and"
        echo "  README.md to an AI assistant and ask it to translate the steps to"
        echo "  your platform (macOS, Fedora, Arch, WSL2, ...). Short, documented,"
        echo "  self-verifying scripts are exactly what makes such a port quick"
        echo "  and reliable — demonstrating that workflow is part of this"
        echo "  repository's point."
        echo
        echo "  On a close-enough system (another Linux with apt equivalents and"
        echo "  udisks2)? Acknowledge and proceed with:"
        echo
        echo "      RP2350_ANY_PLATFORM=1 $0"
        echo
        exit 2
    fi

    # Ubuntu inside WSL passes the check above, but USB needs extra plumbing —
    # warn early rather than letting exp101 fail mysteriously at lsusb.
    if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "${YELLOW}Note:${RESET} this looks like WSL. Cross-compiling (exp102) works fine,"
        echo "but experiments that touch the board over USB need usbipd-win to"
        echo "attach the device to WSL first: https://github.com/dorssel/usbipd-win"
        echo
    fi
}
