#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp226 run — the half that needs no board, recorded to capture.txt.
#
#   ./run.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../lib.sh
source ../../tools/hazard3/shell/shell.sh

{
capture_header "exp226 — the shell that speaks"

echo ">>> the USB device's descriptors, as a host reads them"
python3 ../../tools/hazard3/shell/usbdev_test.py "exp226 the shell that speaks" 226 ../exp115-webusb-enumerate/README.md \
    | grep -E "the device:|the configuration:|interface 0 ACM|exp115 recorded"
echo

echo ">>> the shell, for the chip and for the RTL"
./build.sh
echo

echo ">>> on the RTL, which has no USB: exp225's shell as exp226 builds it"
shell_words build/sim.bin
echo
echo

echo ">>> the checks"
./check.sh
} 2>&1 | capture_tee
