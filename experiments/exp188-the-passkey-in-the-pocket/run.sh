#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "=== exp188: Discoverable Credentials & Credential Management ==="

cargo build --release
elf2flash convert -b rp2350 target/thumbv8m.main-none-eabihf/release/exp188-the-passkey-in-the-pocket target/exp188.uf2

echo "Flashing target/exp188.uf2 via yi26..."
yi26 flash target/exp188.uf2

sleep 2

echo "Running passkey_credmgmt_probe.py..."
python3 passkey_credmgmt_probe.py | tee passkey-credmgmt-probe.json

echo "Running verification..."
python3 verify.py passkey-credmgmt-probe.json

