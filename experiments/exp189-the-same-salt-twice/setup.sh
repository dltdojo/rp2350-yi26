#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp189 setup — fetch the ready-made version of what exp190 builds by hand.
#
# `age` plus `age-plugin-fido2-hmac` is an off-the-shelf tool that encrypts a
# file to a FIDO2 authenticator's hmac-secret. It is the control: exp190 is
# going to hand-roll a vault on top of this board's key, and this repository
# has hand-rolled FAT12, SCSI, Bulk-Only Transport, DHCP and CBOR — every one
# of those after measuring the alternative rather than instead of measuring it.
# exp178 priced OpenSK's engine at 121,184 bytes before anybody argued about
# whether to use it. This is the same move for the encryption half.
#
# It follows exp177's rule for somebody else's software, which is the rule that
# survives the objection `gh` did not: **one released binary, fetched by URL,
# checked against a SHA-256 written down here, kept in a git-ignored directory,
# never vendored, and named by version in the README.** A binary pinned that way
# is a dated observation. A client that talks to a network service is somebody
# else's product with somebody else's release schedule, and no pin fixes that.
#
#   ./setup.sh                      verify what is pinned, fetching if absent
#   ./setup.sh --pin AGE PLUGIN     resolve two versions and print the block to paste
#
# Nothing here is on the road's critical path. If the plugin refuses this board,
# that is this experiment's finding and not its failure — check.sh never gates
# on it.

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------- the pins
# Resolved on 2026-08-29 by `--pin v1.3.1 v0.5.0`, which asks GitHub what each
# release actually contains rather than guessing an asset name. A SHA-256 nobody
# has computed is worse than no SHA-256 — it looks like a check and is a
# decoration — so these are what this host downloaded and hashed, and what any
# other host has to download and hash to be measuring the same thing.
AGE_VERSION="v1.3.1"
AGE_URL="https://github.com/FiloSottile/age/releases/download/v1.3.1/age-v1.3.1-linux-amd64.tar.gz"
AGE_SHA256="bdc69c09cbdd6cf8b1f333d372a1f58247b3a33146406333e30c0f26e8f51377"

PLUGIN_VERSION="v0.5.0"
PLUGIN_URL="https://github.com/olastor/age-plugin-fido2-hmac/releases/download/v0.5.0/age-plugin-fido2-hmac-v0.5.0-linux-amd64.tar.gz"
PLUGIN_SHA256="f837ee7eea5a94c33366b7a78cd143a2a64a1cbae8532b58f16335ca05cccc92"
# --------------------------------------------------------------------------

AGE_REPO="FiloSottile/age"
PLUGIN_REPO="olastor/age-plugin-fido2-hmac"
DEST="bin"

# Asset names are the upstream project's business and change between releases,
# so nothing here guesses one: --pin asks GitHub what the release actually
# contains and picks the linux-amd64 archive out of the answer.
resolve() { # repo tag -> prints "url"
    local repo="$1" tag="$2"
    curl -fsSL "https://api.github.com/repos/$repo/releases/tags/$tag" \
        | grep -o '"browser_download_url": *"[^"]*"' \
        | cut -d'"' -f4 \
        | grep -Ei 'linux.*(amd64|x86_64)' \
        | grep -Ev '\.(sha256|sig|asc|deb|rpm)$' \
        | head -1
}

if [[ "${1-}" == "--pin" ]]; then
    [[ $# -eq 3 ]] || { echo "usage: ./setup.sh --pin <age-tag> <plugin-tag>   e.g. --pin v1.2.1 v0.3.0" >&2; exit 64; }
    command -v curl > /dev/null || { echo "--pin needs curl" >&2; exit 1; }
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    echo "# paste this block into setup.sh, replacing the empty one:"
    echo
    for pair in "AGE:$AGE_REPO:$2" "PLUGIN:$PLUGIN_REPO:$3"; do
        name="${pair%%:*}"; rest="${pair#*:}"; repo="${rest%%:*}"; tag="${rest##*:}"
        url="$(resolve "$repo" "$tag")"
        [[ -n "$url" ]] || { echo "no linux-amd64 asset in $repo $tag — look at the release yourself" >&2; exit 1; }
        curl -fsSL -o "$tmp/$name" "$url"
        printf '%s_VERSION="%s"\n%s_URL="%s"\n%s_SHA256="%s"\n\n' \
            "$name" "$tag" "$name" "$url" "$name" "$(sha256sum "$tmp/$name" | cut -d' ' -f1)"
    done
    echo "# and say in the README which two versions were measured, because that"
    echo "# is what makes this an observation with a date rather than a dependency."
    exit 0
fi

if [[ -z "$AGE_SHA256" || -z "$PLUGIN_SHA256" ]]; then
    cat >&2 <<'MSG'
Nothing is pinned yet, so there is nothing to verify and this script will not
download anything on trust.

    ./setup.sh --pin <age-tag> <plugin-tag>

resolves both releases, prints a block with real URLs and real SHA-256s, and
that block goes into this file. Until then the age control is unbuilt, which is
what check.sh says.
MSG
    exit 1
fi

mkdir -p "$DEST"
fetch() { # name url sha256
    local name="$1" url="$2" want="$3" f="$DEST/$1.archive"
    [[ -f "$f" ]] || { echo "fetching $name ..."; curl -fsSL -o "$f" "$url"; }
    local have; have="$(sha256sum "$f" | cut -d' ' -f1)"
    if [[ "$have" != "$want" ]]; then
        echo "SHA-256 mismatch for $name:" >&2
        echo "  expected $want" >&2
        echo "  got      $have" >&2
        echo "refusing to unpack an artifact that is not the one this experiment measured." >&2
        exit 1
    fi
    echo "$name present and verified ($want)"
}

fetch age    "$AGE_URL"    "$AGE_SHA256"
fetch plugin "$PLUGIN_URL" "$PLUGIN_SHA256"

# Unpacked flat into bin/, because a script that tells a person to unpack
# something is a step that stops overnight. --strip-components drops the
# archives' own top directory; only the executables this experiment names are
# taken out, so a future release growing a tool does not silently add one here.
tar xzf "$DEST/age.archive"    -C "$DEST" --strip-components=1 age/age age/age-keygen
tar xzf "$DEST/plugin.archive" -C "$DEST" --strip-components=1 \
    age-plugin-fido2-hmac/age-plugin-fido2-hmac
chmod +x "$DEST"/age "$DEST"/age-keygen "$DEST"/age-plugin-fido2-hmac

echo
echo "age $AGE_VERSION and age-plugin-fido2-hmac $PLUGIN_VERSION are the versions"
echo "this experiment measured, and they are in $DEST/. Nothing puts them on PATH:"
echo "the control calls them by path, so a different age on this host cannot"
echo "quietly become the one that produced a transcript."
