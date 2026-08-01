#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# audit.sh — disclose the security-relevant choices baked into a firmware,
# so you can decide whether they are the choices you want.
#
#   ./audit.sh                    # audit every experiment
#   ./audit.sh exp105-usb-reboot  # audit one
#
# This reads your SOURCE TREE and your BUILT ARTIFACT. It does not talk to the
# board, and it never triggers anything — auditing must not change what it is
# auditing. See "What this can and cannot tell you" at the end of the output.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ./lib.sh
require_supported_platform

TARGET=thumbv8m.main-none-eabihf

CONCERNS=0
UNKNOWNS=0

# ---------------------------------------------------------------------------
# Reporting helpers. Every line states its evidence, because a security tool
# that asks to be trusted has already failed.

item()    { echo; echo "  ${BOLD}$1${RESET}"; }
value()   { echo "    state:    $1"; }
source_() { echo "    evidence: ${DIM}$1${RESET}"; }
risk()    { echo "    risk:     $1"; }
advice()  { echo "    to change: ${DIM}$1${RESET}"; }
concern() { echo "    ${YELLOW}▲ review this${RESET}"; CONCERNS=$((CONCERNS + 1)); }
unknown() { echo "    ${YELLOW}? cannot determine${RESET} — $1"; UNKNOWNS=$((UNKNOWNS + 1)); }

# Resolved feature list for a crate directory, as cargo actually computes it.
resolved_features() {
    (cd "$1" && cargo tree -f "{p} {f}" --depth 0 2>/dev/null | head -1 | sed 's/.*) //')
}

# ---------------------------------------------------------------------------

audit_experiment() {
    local dir="$1"
    local name="${dir%/}"

    [[ -f "$dir/Cargo.toml" ]] || return 0

    echo
    echo "${BOLD}=== $name ===${RESET}"

    local feats
    feats="$(resolved_features "$dir")"
    [[ -n "$feats" ]] || feats="(none)"
    echo "  resolved features: ${feats}"

    # -- 1. 1200-baud auto-reboot --------------------------------------------
    #
    # Two independent sources, deliberately. `cargo tree` describes what a
    # default build of this checkout WOULD produce; the marker string inside
    # the .uf2 records what the artifact on disk actually IS. They disagree
    # whenever someone built with different flags — which is exactly the case
    # an audit exists to catch, so the artifact wins and the mismatch is
    # reported.
    local uf2_path
    uf2_path="$(ls "$dir"/target/*.uf2 2>/dev/null | head -1)"

    if grep -q "usb-reboot" "$dir/Cargo.toml" 2>/dev/null; then
        item "Host-triggered reboot into the bootloader (1200-baud touch)"

        local src_state="unknown" art_state="unknown" marker=""
        [[ "$feats" == *auto-reboot* ]] && src_state="on" || src_state="off"
        if [[ -n "$uf2_path" ]]; then
            marker="$(strings "$uf2_path" 2>/dev/null | grep -m1 '^yi26-cfg:auto-reboot=')"
            case "$marker" in
                *=on*)  art_state="on"  ;;
                *=off*) art_state="off" ;;
            esac
        fi

        if [[ "$art_state" == "on" ]]; then
            value "${YELLOW}ENABLED${RESET} in the built firmware — any host program can reboot this board"
            source_ "marker '${marker}' found inside $(basename "$uf2_path")"
            risk "A baud rate is not a secret. Any process that opens the serial"
            echo "              port at 1200 baud — a terminal with old saved settings, a"
            echo "              modem script, a tool probing serial devices — puts this"
            echo "              board into its bootloader, dropping whatever it was doing."
            advice "cargo build --release --no-default-features, then reflash"
            concern
        elif [[ "$art_state" == "off" ]]; then
            value "${GREEN}disabled${RESET} in the built firmware — only BOOTSEL reaches the bootloader"
            source_ "marker '${marker}' found inside $(basename "$uf2_path")"
            risk "None from this mechanism. Reflashing needs physical access."
            advice "cargo build --release (defaults on), then reflash"
        else
            unknown "no build marker in the artifact — not built, or built before markers existed"
            source_ "searched for 'yi26-cfg:auto-reboot=' in ${uf2_path:-(no .uf2)}"
        fi

        # The disagreement case gets its own line, because a quiet mismatch is
        # how someone ends up auditing one thing and flashing another.
        if [[ "$art_state" != "unknown" && "$src_state" != "$art_state" ]]; then
            echo "    ${YELLOW}▲ MISMATCH${RESET}: a default build of this checkout would be"
            echo "              '${src_state}', but the .uf2 on disk is '${art_state}'."
            echo "              Someone built it with non-default flags. Rebuild before"
            echo "              flashing if you want the source tree's behaviour."
            CONCERNS=$((CONCERNS + 1))
        fi
    fi

    # -- 2. USB identity ------------------------------------------------------
    local vid_pid
    vid_pid="$(grep -oE 'UsbConfig::new\(0x[0-9a-fA-F]+, 0x[0-9a-fA-F]+\)' "$dir"/src/*.rs 2>/dev/null | head -1)"
    if [[ -n "$vid_pid" ]]; then
        item "USB identity"
        local ids
        ids="$(echo "$vid_pid" | grep -oE '0x[0-9a-fA-F]+' | tr '\n' ' ')"
        value "VID/PID = ${ids}"
        source_ "$(basename "$dir")/src/main.rs"
        if [[ "$ids" == *0x1209* ]]; then
            risk "1209:0001 is pid.codes' shared TEST id, not yours. Fine for"
            echo "              learning; on anything you hand to other people it collides"
            echo "              with every other test device and can bind the wrong driver."
            advice "request a free PID at https://pid.codes for real devices"
            concern
        fi
    fi

    # -- 3. Debug surface -----------------------------------------------------
    if grep -qE "CdcAcmClass" "$dir"/src/*.rs 2>/dev/null; then
        item "Serial debug interface (USB CDC-ACM)"
        value "${YELLOW}present${RESET} — the firmware exposes a log/console port"
        source_ "CdcAcmClass constructed in $(basename "$dir")/src/main.rs"
        risk "Unauthenticated. Any local process with permission to open the"
        echo "              port reads everything the firmware prints. Do not print"
        echo "              keys, tokens, or personal data over it."
        advice "remove the CDC-ACM class from src/main.rs for a production build"
        concern
    fi

    # -- 3b. Interrupt-disabling BOOTSEL reads --------------------------------
    if grep -q "^bootsel" "$dir/Cargo.toml" 2>/dev/null; then
        item "BOOTSEL button reads (interrupts disabled, flash stalled)"
        value "${YELLOW}present${RESET} — this firmware reads BOOTSEL at runtime"
        source_ "crates/bootsel dependency in $(basename "$dir")/Cargo.toml"
        risk "Each read disables interrupts and floats the flash chip-select"
        echo "              line for ~20 us (measured on a Pico 2). That is a hole in"
        echo "              interrupt latency, it must never overlap a flash write, and"
        echo "              on a multi-core build core 1 must not be running from flash."
        echo "              Fine for a button; wrong inside a tight or timing-critical"
        echo "              loop."
        advice "drop the bootsel dependency, or slow the polling interval"
        concern
    fi

    # -- 4. Panic behaviour ---------------------------------------------------
    item "Behaviour on panic"
    if grep -q "panic_halt" "$dir"/src/*.rs 2>/dev/null; then
        value "halt — the chip stops silently and stays stopped"
        source_ "panic_halt linked in $(basename "$dir")/src/main.rs"
        risk "A crash is indistinguishable from a hang, and nothing recovers"
        echo "              on its own. There is no watchdog in these experiments, so an"
        echo "              unattended board would need a power cycle."
        advice "a panic handler that resets, plus the RP2350 watchdog"
    else
        unknown "no recognised panic handler found"
    fi

    # -- 5. Does the artifact match the source? -------------------------------
    item "Built artifact freshness"
    local uf2
    uf2="$(ls "$dir"/target/*.uf2 2>/dev/null | head -1)"
    if [[ -z "$uf2" ]]; then
        value "not built yet"
        source_ "no .uf2 under $dir/target/"
        risk "Nothing to flash, so nothing to mis-flash — but this audit"
        echo "              could not inspect a binary either."
    else
        local newest_src
        newest_src="$(find "$dir/src" "$dir/Cargo.toml" ../crates -newer "$uf2" 2>/dev/null | head -1)"
        if [[ -n "$newest_src" ]]; then
            value "${YELLOW}STALE${RESET} — sources changed after this .uf2 was built"
            source_ "newer than the artifact: $newest_src"
            risk "The findings above describe the SOURCE. Flashing this stale"
            echo "              .uf2 would put different code on your board than you just"
            echo "              audited — the exact gap an audit is supposed to close."
            advice "cargo build --release && re-run this audit"
            concern
        else
            value "${GREEN}current${RESET} — artifact is newer than all sources"
            source_ "mtime of $(basename "$uf2") vs src/, Cargo.toml, ../crates"
        fi
    fi
}

# ---------------------------------------------------------------------------

echo "${BOLD}Firmware disclosure report${RESET}"
echo "Generated from the source tree and built artifacts in this checkout."

if [[ $# -gt 0 ]]; then
    for d in "$@"; do audit_experiment "${d%/}"; done
else
    for d in exp*/; do audit_experiment "$d"; done
fi

# ---------------------------------------------------------------------------
echo
echo "${BOLD}=== Summary ===${RESET}"
echo "  ${CONCERNS} item(s) flagged for review, ${UNKNOWNS} undetermined."
echo
echo "${BOLD}What this can and cannot tell you${RESET}"
echo "  CAN:    what the code in this checkout says, and what is inside the"
echo "          .uf2 files built from it."
echo "  CANNOT: what is running on a board right now. Nothing here talks to"
echo "          hardware. A board flashed from a different checkout, an older"
echo "          build, or someone else's binary will not match this report."
echo
echo "  Treat this as ${BOLD}disclosure${RESET}, not verification: it reports declared and"
echo "  observable build choices so you can decide about them. It does not"
echo "  prove the firmware behaves as declared, and it is not a security"
echo "  review of the code itself."
echo
echo "  Flagged items are ${BOLD}not bugs${RESET}. Every one of them is a deliberate"
echo "  trade-off that suits learning and may not suit your deployment. That"
echo "  judgement is yours to make, which is the point of printing them."

exit 0
