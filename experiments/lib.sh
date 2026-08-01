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

# ---------- RP2350 board helpers -------------------------------------------

# True when a Pico 2 is enumerated in BOOTSEL mode.
in_bootsel() { lsusb -d 2e8a:000f > /dev/null 2>&1; }

# Prints the /dev/ttyACM* node of a board running one of this repository's
# firmwares (USB 1209:0001), if present. Resolved through /dev/serial/by-id so
# it picks the right port even when other USB serial devices are plugged in.
exp_serial_port() {
    local link
    for link in /dev/serial/by-id/*; do
        [[ -e "$link" ]] || continue
        case "$link" in
            *rp2350-yi26*|*exp104*) readlink -f "$link"; return 0 ;;
        esac
    done
    return 1
}

# Prints the mount point of the RP2350 boot drive, if mounted (empty if not).
rp2350_mountpoint() {
    lsblk -rno LABEL,MOUNTPOINT 2>/dev/null \
        | awk '$1 == "RP2350" && $2 != "" {print $2; exit}' | sed 's/\\x20/ /g'
}

# Sends the 1200-baud touch to a serial port, asking a firmware built with
# crates/usb-reboot to put itself into the ROM bootloader. Returns 0 if the
# board reached BOOTSEL mode within ~10 s.
#
# Nothing is transmitted — the baud rate itself is the signal. Fails
# harmlessly on firmware that does not implement it (exp103, exp104), which
# is why callers should fall back to asking for the button.
usb_touch_1200() {
    local port="$1"
    [[ -e "$port" ]] || return 1
    # Set a different rate first. If the port already happens to be at 1200,
    # asking for 1200 changes nothing, so the host sends no SET_LINE_CODING
    # and the firmware never hears the request — measured on hardware, not
    # theoretical. Bouncing via 115200 makes the touch unconditional.
    stty -F "$port" 115200 > /dev/null 2>&1 || return 1
    sleep 1
    stty -F "$port" 1200 > /dev/null 2>&1 || return 1
    local i
    for ((i = 0; i < 10; i++)); do
        in_bootsel && return 0
        sleep 1
    done
    return 1
}

# Gets the board into BOOTSEL mode, automatically if the running firmware
# supports the 1200-baud touch, otherwise by asking the user. Callers get the
# same end state either way.
ensure_bootsel() {
    if in_bootsel; then
        ok "Board is already in BOOTSEL mode."
        return 0
    fi

    local port
    port="$(exp_serial_port || true)"
    if [[ -n "$port" ]]; then
        say "A board with our serial port is attached. Trying the 1200-baud"
        say "touch instead of asking you to press anything:"
        echo "  ${DIM}\$ stty -F $port 1200${RESET}"
        if usb_touch_1200 "$port"; then
            ok "It rebooted itself. No button involved."
            return 0
        fi
        say "No reboot — this firmware predates the 1200-baud watcher."
    fi

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
