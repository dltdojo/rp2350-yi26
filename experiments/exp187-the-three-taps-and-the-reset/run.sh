#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "=== exp187: On-Device Gesture UV & Authenticator Reset ==="

cargo build --release
elf2flash convert -b rp2350 target/thumbv8m.main-none-eabihf/release/exp187-the-three-taps-and-the-reset target/exp187.uf2

echo "Flashing target/exp187.uf2 via yi26..."
yi26 flash target/exp187.uf2

sleep 2

echo "Running gesture_reset_probe.py..."
python3 gesture_reset_probe.py | tee gesture-reset-probe.json

echo "Running verification..."
python3 verify.py gesture-reset-probe.json

