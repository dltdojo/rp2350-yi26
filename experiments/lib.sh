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

# Both of these read from /dev/tty rather than stdin so they still work when a
# script's output is being piped somewhere. If there is no terminal at all —
# run from cron, from another script, from a CI job — they say so and give up
# rather than dying on an unbound variable.
pause() {
    if ! read -r -p "  --> $1 Press Enter when done. " _ 2>/dev/null < /dev/tty; then
        bad "This step needs a terminal (it is asking you to do something)."
        exit 3
    fi
}
confirm() {
    local answer=""
    if ! read -r -p "  --> $1 [y/n] " answer 2>/dev/null < /dev/tty; then
        say "(no terminal to ask — treating as 'no')"
        return 1
    fi
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

# ---------- RP2350 board helpers -------------------------------------------
#
# Everything below delegates to `tools/yi26`, the repository's host-side
# helper. It used to be shell built out of lsusb, lsblk, udisksctl, stty and
# /dev/serial/by-id — five things that exist only on Linux, and the only part
# of this repository that was ever platform-bound.
#
# There is one implementation, not one per platform and not a shell version
# racing a Rust version. Anyone who wants to know what the tool does by hand
# can ask it: every subcommand takes `--explain` and prints the equivalent
# commands, including a reason where no equivalent exists.
#
# The exception is exp101, which deliberately keeps raw shell. It runs before
# exp102 installs Rust, so it cannot depend on a tool that has to be compiled —
# and showing `lsusb` and `udisksctl` directly is that experiment's whole
# curriculum.

# Runs the helper, building it once if this checkout has not built it yet.
YI26_BIN=""
yi26() {
    if [[ -z "$YI26_BIN" ]]; then
        # `type -P`, not `command -v`: this function is itself called yi26, and
        # `command -v` finds functions first — so it would report success,
        # point this function at itself, and recurse silently until bash gave
        # up and returned nothing. `type -P` searches PATH for an executable
        # and nothing else.
        local installed
        installed="$(type -P yi26 2>/dev/null || true)"
        if [[ -n "$installed" ]]; then
            YI26_BIN="$installed"
        else
            local root built
            root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
            built="$root/tools/yi26/target/release/yi26"
            if [[ ! -x "$built" ]]; then
                command -v cargo > /dev/null 2>&1 || {
                    echo "  ${RED}yi26 helper needs cargo — run exp102 first.${RESET}" >&2
                    return 127
                }
                echo "  ${DIM}building the host helper once: cargo build --release --manifest-path tools/yi26/Cargo.toml${RESET}" >&2
                cargo build --release --quiet --manifest-path "$root/tools/yi26/Cargo.toml" >&2 || return 1
            fi
            YI26_BIN="$built"
        fi
    fi
    "$YI26_BIN" "$@"
}

# True when a board is sitting in the ROM bootloader.
in_bootsel() { [[ "$(yi26 state 2>/dev/null)" == "bootsel" ]]; }

# Prints the serial port of a board running one of this repository's firmwares.
exp_serial_port() { yi26 port 2>/dev/null; }

# True when the board is running THIS experiment's firmware.
#
#   exp_running 108   # is exp108 flashed?
#
# `yi26 state` answers a different and weaker question — "is *something*
# running" — and every check.sh here used to ask that one. The result was a
# check that ran its board-dependent half against whatever firmware happened
# to be flashed, then failed because the log did not say what it expected. A
# check that reports FAIL when the honest answer is "you have a different
# experiment on the board" is worse than no check: it sends someone debugging
# a firmware that is working perfectly, somewhere else.
#
# Every firmware here sets `config.serial_number` to its own experiment
# number, which is what makes them distinguishable. Reading it out of
# `yi26 port --json` rather than matching on the product string keeps this
# stable if the human-readable names ever get reworded.
exp_running() {
    local want="$1" got
    got="$(yi26 port --json 2>/dev/null | sed -n 's/.*"serial_number":"\([^"]*\)".*/\1/p')"
    [[ "$got" == "$want" ]]
}

# Reads a firmware's serial output for N seconds and prints what arrived.
#
#   exp_read_log 15
#
# Takes no port argument: the helper finds the board itself, and opens the
# device directly rather than going through a terminal line discipline that
# would turn the firmware's CR+LF into a blank line after every entry.
exp_read_log() { yi26 log --seconds "$1" 2>/dev/null; }

# Prints the mount point of the RP2350 boot drive if one is already mounted.
rp2350_mountpoint() { yi26 drive 2>/dev/null; }

# Mounts the RP2350 boot drive and prints its mount point, waiting for it to
# appear. The drive does not exist the instant the board enumerates: the kernel
# has to see the mass storage device, read its partition table, and let udev
# settle.
rp2350_mount() { yi26 drive; }

# Gets the board into BOOTSEL mode, automatically if the running firmware
# supports the 1200-baud touch, otherwise by asking the user. Callers get the
# same end state either way.
ensure_bootsel() {
    if in_bootsel; then
        ok "Board is already in BOOTSEL mode."
        return 0
    fi

    say "Asking the board to reboot itself, instead of asking you to press"
    say "anything. Add --explain to see what that does by hand:"
    echo "  ${DIM}\$ yi26 bootsel${RESET}"
    if yi26 bootsel > /dev/null 2>&1; then
        ok "It rebooted itself. No button involved."
        return 0
    fi
    say "No reboot — this firmware predates the 1200-baud watcher, or was"
    say "built with --no-default-features."

    say "Manual it is: unplug → hold ${BOLD}BOOTSEL${RESET} → plug in → release."
    pause "Do that now."
    local i
    for ((i = 0; i < 10; i++)); do
        in_bootsel && { ok "Board enumerated."; return 0; }
        sleep 1
    done
    return 1
}

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
