#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp217 — the cases, and the emulators' traces of them, into DIR:
# DIR/cases (cases.py), DIR/js (rp2040js), DIR/py (rp2040-pio-emulator), and
# with --lean also DIR/lean (Run.lean, on lean/Pio/Machine.lean). The
# emulators' traces do not depend on the model, so gap.sh makes them once.
#
#   traces.sh DIR [--lean]

set -eu
dir="$1"
cd "$(dirname "${BASH_SOURCE[0]}")"
python3 cases.py > "$dir/cases"
node rp2040js_run.js < "$dir/cases" > "$dir/js"
../../../tools/pio-emulators/venv/bin/python pioemu_run.py < "$dir/cases" > "$dir/py"
if [[ "${2-}" == --lean ]]; then
    ../../../tools/lean/lean.sh exec Run.lean < "$dir/cases" > "$dir/lean"
fi
