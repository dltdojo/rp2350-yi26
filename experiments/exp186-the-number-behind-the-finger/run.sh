#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "=== exp186: Full CTAP 2.1 PIN State Machine & UV Probe ==="

cargo build --release
elf2flash convert -b rp2350 target/thumbv8m.main-none-eabihf/release/exp186-the-number-behind-the-finger target/exp186.uf2

echo "Flashing target/exp186.uf2 via yi26..."
yi26 flash target/exp186.uf2

sleep 2

echo "Running pin_lifecycle_probe.py..."
python3 pin_lifecycle_probe.py | tee pin-lifecycle-probe.json

echo "Running verification..."
python3 verify.py pin-lifecycle-probe.json

