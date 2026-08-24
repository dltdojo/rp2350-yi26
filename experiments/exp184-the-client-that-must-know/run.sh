#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp184 interactive walkthrough.
#
# Builds the CTAP 2.1 minimal firmware, flashes it, tests against the
# Firefox PIN probe, and explains the differences.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

say "Building exp184 firmware with CTAP 2.1 clientPIN compatibility..."
cargo build --release
elf2flash convert -b rp2350 target/thumbv8m.main-none-eabihf/release/exp184-the-client-that-must-know target/exp184.uf2

say "Flashing exp184 to Pico 2..."
yi26 flash target/exp184.uf2
sleep 2

say "Running live Firefox probe against /dev/hidraw..."
python3 firefox_probe.py

say "Running automated check suite..."
./check.sh

