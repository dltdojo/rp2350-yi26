#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp202 quick check — non-interactive, and no board anywhere in it.
#
#   1. riscv-tests' RV32I and RV32M tests, and this experiment's five probes,
#      build as flat images for the region;
#   2. the Lean model and the Hazard3 RTL each pass every test, end every
#      binary the same way, and leave the whole 64 KiB region byte for byte
#      the same;
#   3. every wrong model in semantics/mutants.txt is refused by (2) — ten by
#      the suite, four only by a probe.
#
# Needs Lean (tools/lean/setup.sh) and the Hazard3 testbench
# (tools/hazard3/setup.sh: git, verilator, clang++), each fetched once, and
# clang, lld and llvm-objcopy for the RISC-V images. Without either of the
# first two it says SKIP and succeeds. (3) rebuilds the model fourteen times
# and runs everything against each: about five minutes.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# No board, no person, nothing to look at: a machine and nothing else. The
# RTL is the chip's core, simulated — on this machine.
PRESENCE=0
LIFELINE="no: no firmware of its own"
presence_check
lifeline_check

USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

if [[ "$(../../tools/lean/lean.sh version 2>&1)" != Lean* ]]; then
    echo "SKIP  the comparison: needs tools/lean/setup.sh"
elif ! ../../tools/hazard3/sim.sh ready; then
    echo "SKIP  the comparison: needs tools/hazard3/setup.sh"
else
    if ./build.sh > /dev/null; then
        pass "riscv-tests and the probes build: $(ls build/*.bin | wc -l) images"
    else
        fail "riscv-tests and the probes build" "./build.sh"
    fi
    ./compare.sh | grep -E '^(PASS|FAIL)' || FAILED=1
    [[ ${PIPESTATUS[0]} -eq 0 ]] || FAILED=1
    semantics/mutants.sh || FAILED=1
fi

exit "$FAILED"
