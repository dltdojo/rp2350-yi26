#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tools/pio-emulators setup — two PIO emulators written by others, pinned,
# for holding lean/Pio/Machine.lean against something it is not (exp217).
#
#   rp2040js 1.4.0               Wokwi's RP2040 emulator, TypeScript; its PIO
#                                 is a class that can be stepped on its own.
#                                 npm ci from package-lock.json: the tarball
#                                 is refused unless its sha512 matches.
#   rp2040-pio-emulator 0.88.0   a Python PIO emulator, a generator of
#                                 states, one per clock. pip, --require-hashes,
#                                 the wheel's sha256 below; its declared
#                                 dependency (pytest) is for its own tests
#                                 and is not installed.
#
# Both model the RP2040's PIO, so the RP2350's additions are outside what
# either can say. Fetched into this directory, never committed.
#
#   ./setup.sh     fetch both, or say what is already there
#   ./setup.sh ready && echo yes

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"

PIOEMU="rp2040-pio-emulator==0.88.0"
PIOEMU_SHA256="47c73c1727fa86e4a47cf130af7e6a246b8185db7a761095871de0e0eb5b5cc0"

ready() { [[ -x venv/bin/python && -f node_modules/rp2040js/package.json ]] &&
    venv/bin/python -c 'import pioemu' 2> /dev/null; }

if [[ "${1-}" == ready ]]; then ready; exit; fi
if ready; then echo "already have rp2040js 1.4.0 and rp2040-pio-emulator 0.88.0"; exit 0; fi

python3 -m venv venv
printf '%s --hash=sha256:%s\n' "$PIOEMU" "$PIOEMU_SHA256" > requirements.lock
venv/bin/pip install -q --no-deps --require-hashes -r requirements.lock
rm -f requirements.lock
npm ci --silent --no-audit --no-fund
echo "fetched rp2040js $(node -p "require('./node_modules/rp2040js/package.json').version") and $PIOEMU"
