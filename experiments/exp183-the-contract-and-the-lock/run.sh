#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp183 interactive walkthrough.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

echo "${BOLD}exp183 — the contract and the lock${RESET}"
say "This experiment demonstrates two complementary concepts:"
say "1. Refactoring monolithic FIDO2 firmware into lightweight, zero-heap Rust Traits."
say "2. Observing RP2350 Secure Boot & Secure Lock without burning fuses."
echo

step 1 "Inspect the standalone trait contract (src/contract.rs)"
run_cmd head -n 35 src/contract.rs

step 2 "Inspect the 4 pluggable backends (src/backends/)"
run_cmd ls -la src/backends/

step 3 "Run RP2350 OTP & Secure Lock Hardware Audit (Dry-Run)"
run_cmd python3 otp_audit.py

step 4 "Seal firmware image and emulate RP2350 Bootrom verification"
run_cmd python3 image_seal.py --output target/exp183-sealed.bin
run_cmd python3 bootrom_verify.py target/exp183-sealed.bin

step 5 "Run automated verification suite"
run_cmd ./check.sh
