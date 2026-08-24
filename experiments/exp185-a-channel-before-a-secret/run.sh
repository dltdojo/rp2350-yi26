#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp185 runner — builds, flashes, and runs live PIN Protocol 1 test probe.

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"

cargo build --release
elf2flash convert -b rp2350 target/thumbv8m.main-none-eabihf/release/exp185-a-channel-before-a-secret target/exp185.uf2
../../tools/yi26/target/release/yi26 flash target/exp185.uf2

echo "Waiting for USB device enumeration..."
sleep 2

python3 pin_channel_probe.py

