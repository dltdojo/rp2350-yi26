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
# `${1-}` rather than `$1`: every script here runs under `set -u`, and an
# unbound variable would kill the script at the exact moment a person is
# standing in front of it waiting to be asked something. exp127's and exp128's
# run.sh both did precisely that, and neither was caught, because check.sh
# never calls these and check.sh is what runs unattended.
pause() {
    if ! read -r -p "  --> ${1:+$1 }Press Enter when done. " _ 2>/dev/null < /dev/tty; then
        bad "This step needs a terminal (it is asking you to do something)."
        exit 3
    fi
}
confirm() {
    local answer=""
    if ! read -r -p "  --> ${1:+$1 }[y/n] " answer 2>/dev/null < /dev/tty; then
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

# Does this firmware carry the 1200-baud reboot watcher? Without it, the NEXT
# flash of this board needs a physical BOOTSEL press — the most common
# brick-adjacent property in this repo, and one no UF2 inspection can see, only
# the source. It is a NOTE, not a fail: exp103 and exp104 lack it on purpose,
# to show the cost before exp105 removes it. Anywhere else its absence is a
# surprise worth flagging before you flash, not after.
#
#   reboot_watcher_check [src/main.rs]
reboot_watcher_check() {
    local src="${1:-src/main.rs}"
    if [[ ! -f "$src" ]]; then
        return 0
    fi
    if grep -qE 'reboot_if_requested|usb_reboot::run' "$src"; then
        pass "carries the 1200-baud reboot watcher — the next flash is hands-free"
    else
        echo "NOTE  no 1200-baud reboot watcher in $src: after flashing this, the"
        echo "      NEXT flash needs a physical BOOTSEL press. Intended for exp103/"
        echo "      exp104; a surprise anywhere else."
    fi
}

# ---------- how much of a person an experiment costs -----------------------
#
# Every check.sh declares one number before calling `presence_check`:
#
#   0  no board at all — a machine and nothing else
#   1  a board attached, and nothing but software after that
#   2  a person for one action, then software does the rest — a hand on
#      BOOTSEL, or a tap on a browser's permission dialog
#   3  a person IS the instrument — nothing in this repository can see the
#      result, so somebody has to look
#
# The number describes **verifying the experiment's claim in full**, which is
# usually more than `check.sh` alone reaches. exp127 is the clearest case: all
# seventeen of its checks pass unattended, and none of them can see whether
# the LED emitted light. Each declaration says in a comment what check.sh gets
# to on its own.
#
# What the number deliberately does NOT include is the cost of **flashing
# into** the experiment. That is not a property of the experiment: putting
# exp104 on the board needs a hand on BOOTSEL when the board is running
# exp103, and needs nothing at all when it is running exp105 or later. Only
# something that can see the board right now can answer that, which is
# `yi26 port --json` — see "Which of these can I do right now" in README.md.
#
# The declaration lives beside the code so it cannot drift from it, and this
# helper makes sure the index in README.md agrees. It is silent when they do:
# a guard that prints a line on success would put a new PASS into twenty-seven
# experiments' captured `Expected output`, which is a lot of churn to announce
# that nothing is wrong.
presence_check() {
    local dir index row declared
    # Which experiment is this? Two answers are needed because the scripts do
    # not agree on where they stand: twenty-six of them cd into their own
    # directory first, and exp101's resolves SCRIPT_DIR and stays put. Trusting
    # $PWD alone reported an experiment called "experiments"; trusting the
    # caller's path alone broke the other twenty-six, because by then the cd
    # had already happened and the relative path no longer resolved. So: the
    # working directory when it is an experiment, and the caller's path when it
    # is not.
    # The pattern is expNNN- and not exp*, because "experiments" starts with
    # exp too and matched itself.
    dir="$(basename "$PWD")"
    [[ "$dir" == exp[0-9][0-9][0-9]-* ]] || dir="$(basename "$(dirname "${BASH_SOURCE[1]}")")"
    index="$(dirname "${BASH_SOURCE[0]}")/README.md"
    declared="${PRESENCE-}"

    if [[ -z "$declared" ]]; then
        fail "this check.sh declares PRESENCE" "see lib.sh for the four levels"
        return
    fi
    [[ -f "$index" ]] || return 0

    row="$(grep -m1 -F "[$dir](./$dir/)" "$index")"
    if [[ -z "$row" ]]; then
        fail "$dir has a row in the experiments index" "README.md does not list it"
        return
    fi

    # The cell is written `N · word`; only the number is compared, so the
    # wording can be reworded without breaking twenty-seven scripts.
    if [[ "$row" != *"| $declared · "* ]]; then
        fail "the index agrees this experiment needs presence level $declared" \
             "README.md's row says something else — one of the two is stale"
    fi
}

# ---------- which part of USB an experiment is about -----------------------
#
# By exp122 this repository had a firmware declaring three USB functions at
# once, and by exp126 a board serving files over one interface while logging
# over another. "This experiment uses USB" had stopped saying anything, and a
# reader could not tell whether they were looking at a log, a command, or a
# disk — nor whether the thing consuming it was a kernel driver, a browser, or
# `yi26` holding the interface raw.
#
# So every check.sh declares four things, in tokens rather than prose so that
# the table in README.md can be reworded without breaking twenty-seven
# scripts:
#
#   USB_IFACE     what the board declares
#                 none | bootrom | cdc | cdc+hid | cdc+hid+vendor | cdc+msc
#   USB_CARRIES   what actually travels, and there is usually more than one
#                 none | descriptors | control | log | commands | keystrokes |
#                 scsi | files          (join with +)
#   USB_HOST      who claims the interface on the other end
#                 none | bootrom | cdc_acm | usb-storage | hid | libusb |
#                 webusb               (join with +)
#   USB_RUNS_ON   whose firmware this runs against
#                 own | any | bootrom | none | expNNN | expNNN+
#
# USB_RUNS_ON is a separate field and not a footnote because six experiments
# here have no `src/` at all, and the difference between them matters: exp116
# works against any firmware in this repository, while exp120 works against
# **exp118 and nothing else**, since exp118 is the only one that reads the OUT
# endpoint. A reader who flashes the wrong one sees a page that fails for no
# visible reason.
#
# The first field is checked against the source and not only against the
# table, which is the half of this that cannot rot: adding a HID interface and
# forgetting to say so is caught here.
usb_check() {
    local dir short index row src
    dir="$(basename "$PWD")"
    [[ "$dir" == exp[0-9][0-9][0-9]-* ]] || dir="$(basename "$(dirname "${BASH_SOURCE[1]}")")"
    short="${dir:0:6}"
    index="$(dirname "${BASH_SOURCE[0]}")/README.md"

    local f
    for f in USB_IFACE USB_CARRIES USB_HOST USB_RUNS_ON; do
        if [[ -z "${!f-}" ]]; then
            fail "this check.sh declares $f" "see lib.sh for the vocabulary"
            return
        fi
    done

    # -- against the table ---------------------------------------------------
    if [[ -f "$index" ]]; then
        # Anchored on the backtick, not just on the experiment number. The
        # Portability table earlier in that file has rows starting `| exp101 |`
        # too, and matching those first made all twenty-eight rows report a
        # disagreement with a table they were not being compared against. The
        # USB table is the one whose second cell is a token in backticks.
        local tick=$'\x60'
        row="$(grep -m1 "^| $short | $tick" "$index")"
        if [[ -z "$row" ]]; then
            fail "$short has a row in the USB channel table" "README.md does not list it"
            return
        fi
        for f in USB_IFACE USB_CARRIES USB_HOST USB_RUNS_ON; do
            if [[ "$row" != *"\`${!f}\`"* ]]; then
                fail "the USB channel table agrees $f is ${!f}" \
                     "README.md's row for $short says something else"
                return
            fi
        done
    fi

    # -- against the source, which is the part that cannot drift -------------
    #
    # Skipped where there is nothing to read: the six experiments with no
    # firmware of their own, and exp101 which predates Rust entirely. Those
    # are precisely the ones USB_RUNS_ON exists to describe.
    src="src/main.rs"
    [[ -f "$src" ]] || src="$(dirname "${BASH_SOURCE[1]}")/src/main.rs"
    [[ -f "$src" ]] || return 0

    local bad="" want have
    for f in cdc:CdcAcmClass::new hid:HidWriter::new msc:CLASS_MSC vendor:CLASS_VENDOR; do
        want="${f%%:*}"; have="${f#*:}"
        if grep -qF "$have" "$src"; then
            [[ "$USB_IFACE" == *"$want"* ]] || bad="$bad [source builds $want, USB_IFACE does not say so]"
        else
            [[ "$USB_IFACE" != *"$want"* ]] || bad="$bad [USB_IFACE claims $want, source does not build it]"
        fi
    done
    if [[ -n "$bad" ]]; then
        fail "USB_IFACE matches the interfaces src/main.rs actually builds" "$bad"
    fi
}

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
        local root built
        root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        built="$root/tools/yi26/target/release/yi26"

        # The checkout's build wins, always — even when a copy is installed on
        # PATH. These scripts exist to check *this* checkout, and `cargo
        # install` takes a snapshot: install the tool, pull a change that adds
        # a flag, and every script here quietly runs the old binary and fails
        # on an option the source plainly supports. That happened within hours
        # of this repository first telling people to install it, and the error
        # blamed the scripts rather than the stale copy.
        #
        # Rebuilt whenever anything under src/ is newer than the binary,
        # because "it exists" is a different question from "it is current".
        if command -v cargo > /dev/null 2>&1; then
            if [[ ! -x "$built" ]] \
               || [[ -n "$(find "$root/tools/yi26/src" "$root/tools/yi26/Cargo.toml" \
                            -newer "$built" -print -quit 2>/dev/null)" ]]; then
                echo "  ${DIM}building the host helper: cargo build --release (in tools/yi26)${RESET}" >&2
                echo "  ${DIM}(to type 'yi26' yourself, outside these scripts: cargo install --path tools/yi26)${RESET}" >&2
                # In a subshell, *cd'd into the tool's own directory*, and not
                # `--manifest-path` from wherever the caller stands. Cargo picks
                # up `.cargo/config.toml` from the working directory, and every
                # experiment here has one that pins `target =
                # thumbv8m.main-none-eabihf`. Building the host tool from an
                # experiment directory therefore tried to compile it for a
                # Cortex-M33, failed on the first host-only dependency, and
                # returned nothing — so `yi26 port` produced no serial and the
                # board half of that experiment's check.sh reported "board is
                # not running expNNN". Measured, and blamed on USB enumeration
                # for a day: exp142's check.sh carried a note saying the SKIP
                # was nusb going briefly empty under load. It was this.
                ( cd "$root/tools/yi26" && cargo build --release --quiet ) >&2 || return 1
            fi
            YI26_BIN="$built"
        elif [[ -x "$built" ]]; then
            YI26_BIN="$built"
        else
            # No cargo, nothing built. `type -P`, not `command -v`: this
            # function is itself called yi26, and `command -v` finds functions
            # first — so it would report success, point this function at
            # itself, and recurse silently until bash gave up.
            local installed
            installed="$(type -P yi26 2>/dev/null || true)"
            if [[ -n "$installed" ]]; then
                YI26_BIN="$installed"
            else
                echo "  ${RED}yi26 helper needs cargo — run exp102 first.${RESET}" >&2
                return 127
            fi
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
    local want="$1" got i
    # `yi26 port` can enumerate empty for a moment right after heavy USB/CPU
    # (a `cargo build` immediately before, say), so retry on an *empty* answer.
    # A *different* serial is a real answer — another experiment on the board —
    # so return at once rather than waiting it out.
    for i in 1 2 3; do
        got="$(yi26 port --json 2>/dev/null | sed -n 's/.*"serial_number":"\([^"]*\)".*/\1/p')"
        [[ "$got" == "$want" ]] && return 0
        [[ -n "$got" ]] && return 1
        sleep 0.3
    done
    return 1
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
