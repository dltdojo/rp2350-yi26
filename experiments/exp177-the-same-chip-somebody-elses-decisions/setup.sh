#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp177 setup — fetch the firmware this experiment measures.
#
# pico-fido is **GPL-3.0** and the SDK under it is **AGPL-3.0**; this repository
# is Apache-2.0. Those do not mix, and this experiment never asks them to: not
# one line of their code is read into anything built here. What is measured is a
# **released binary, run on a board** — which is not a licensing event at all,
# any more than running any other program is.
#
# So there is no clone. There is one signed-off release artifact, fetched by
# URL, checked against a SHA-256 written down here, and kept in a git-ignored
# directory. `v8.0` is a tag rather than one of the `nightly-*` releases, whose
# assets move under the same name.
#
#   ./setup.sh          download the pinned release, or verify the one present

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"

VERSION="8.0"
URL="https://github.com/polhenarejos/pico-fido/releases/download/v${VERSION}/pico_fido_pico2-${VERSION}.uf2"
SHA256="924c13b747ad3cd0dfae3c5444617891c11b5e81f91e0b7de02a44361d6e973e"
FILE="firmware/pico_fido_pico2-${VERSION}.uf2"

mkdir -p firmware

if [[ ! -f "$FILE" ]]; then
    echo "fetching pico-fido ${VERSION} for the Pico 2 ..."
    curl -fsSL -o "$FILE" "$URL"
fi

HAVE="$(sha256sum "$FILE" | cut -d' ' -f1)"
if [[ "$HAVE" != "$SHA256" ]]; then
    echo "SHA-256 mismatch:" >&2
    echo "  expected $SHA256" >&2
    echo "  got      $HAVE" >&2
    echo "refusing to hand an unverified image to a board." >&2
    exit 1
fi
echo "pico-fido ${VERSION} present and verified ($SHA256)"
