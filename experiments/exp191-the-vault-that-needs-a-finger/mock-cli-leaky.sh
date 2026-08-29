#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The same CLI, with one difference, and the difference is the point.
#
# `gh`, `claude`, `aws` — any of them would make this experiment a client of
# somebody else's service, with somebody else's release schedule and somebody
# else's config format. exp177 pins a third party's binary by SHA-256 and that
# works because the binary is offline; a tool that authenticates against a
# network cannot be pinned at all. **An experiment that cannot be re-run in five
# years is not an experiment.**
#
# What is under test is not the CLI. It is the chain: redirect the config
# directory, decrypt into it, run, wipe. The CLI is the load, and a load you
# wrote yourself removes a variable rather than adding one — which is exp168
# building a security key with no cryptography in it, for the same reason.
#
#   mock-cli.sh login     writes credentials where the env var says
#   mock-cli.sh whoami    reads them back, or fails saying it is not logged in
#
# The three properties a **real** CLI must have for any of this to apply to it
# are in the README, and the third one is the one you have to measure rather
# than believe.

# **It also keeps a copy in $HOME.** Three lines, silent, and exactly what a
# real CLI does when it caches a session, writes a crash report, or keeps a
# "recently used" list. Nothing about the redirection is broken here: the config
# directory is honoured perfectly, and the secret still ends up somewhere the
# wrapper never wipes.
#
# It exists so that **"the redirection worked" and "nothing was left behind" are
# two assertions rather than one**. A verifier that only checks the first passes
# this file, and a wrapper tested only against the honest CLI would ship.

set -u

CONFIG_DIR="${MOCKCLI_CONFIG_DIR:-$HOME/.config/mock-cli}"
AUTH="$CONFIG_DIR/auth.json"

case "${1:-}" in
    login)
        mkdir -p "$CONFIG_DIR"
        printf '{"token": "%s", "user": "alice"}\n' "${2:-t0ken-from-nowhere}" > "$AUTH"
        echo "[mock-cli-leaky] wrote credentials to $AUTH"
        # The leak. Not malice — a cache.
        mkdir -p "$HOME/.cache/mock-cli"
        cp "$AUTH" "$HOME/.cache/mock-cli/last-session.json"
        ;;
    whoami)
        if [[ -f "$AUTH" ]]; then
            echo "[mock-cli-leaky] logged in as $(sed -n 's/.*"user": "\([^"]*\)".*/\1/p' "$AUTH")"
            echo "[mock-cli-leaky] read from $AUTH"
        else
            echo "[mock-cli-leaky] not logged in — no credentials at $AUTH" >&2
            exit 1
        fi
        ;;
    *)
        echo "usage: $0 {login|whoami}" >&2
        exit 64
        ;;
esac
